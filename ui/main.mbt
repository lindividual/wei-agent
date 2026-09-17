///|
/// The web UI: an agent, its sessions, and an HTTP server, in one process and one binary.
///
/// The server is the only writer of the document. The browser applies patches and posts prompts; it
/// holds no model of the conversation, so there is nothing for it and the server to disagree about.
///
/// This file is the process: the command line, the port, the task group a turn is spawned into, and
/// its lifetime. What each request *means* is `requests.mbt`; the state it is answered from is
/// `session.mbt`; the pieces it is answered with are in the other files beside this one.
///
/// ## Sessions run in parallel, one is displayed
///
/// Every open session owns its turn slot. Two sessions can therefore be working at the same time,
/// and switching which one is displayed interrupts nothing — the reader looks at one conversation
/// while another keeps going, which is the point of having several.
///
/// Within one session turns are serialized, and that is not a nicety: two turns sharing a session
/// interleave their writes into one file and fork its history. The first version of this UI did
/// exactly that, and the log it produced had entries with a parent that no longer existed.
///
/// Patches are tagged with the session they belong to, so a browser showing one conversation never
/// receives another one's output.

///|
async fn main {
  let argv = @env.args()
  let args = parse_args(argv)
  let home = home_dir()
  // Read before the key is resolved, because the saved key is one of the three places one can
  // come from. A settings file that cannot be read is the empty settings, so this cannot fail.
  // The mode this run starts in. `--mode` wins over the saved setting, like the limits: a flag is
  // something a person typed for this run, and the saved value is what applies when nobody did.
  // The output files a run that is over left behind. Pruned by age rather than cleared: the
  // directory is shared with any other server running on this machine.
  @platform.clear_job_outputs(@env.now().reinterpret_as_int64())
  let mut settings = @platform.load_settings(home)
  match args.mode {
    Some(mode) =>
      settings = settings.with_tool_mode(@core.parse_tool_mode(mode))
    None => ()
  }
  let env_key = environment_key()
  let choice = @core.choose_api_key(env_key, settings.saved_api_key)
  let root = if args.store == "" { "\{home}/.wei/sessions" } else { args.store }
  let cwd = @platform.current_dir()
  // Header-only sessions accumulate from every start that never got used. Ten minutes is long
  // enough that a session another instance is writing right now is safe.
  let pruned = @platform.prune_empty_sessions(
    @core.session_dir_for(root, cwd),
    10L * 60L * 1000L,
  )
  if pruned > 0 {
    log("pruned   \{pruned} empty session(s)")
  }
  let opened = open_session(args, root, cwd)
  let first = Runner::new(opened.0, opened.1, args.model)
  // Asked once, before the page exists. Whether this host can put a dialog in front of the reader
  // is a fact about the process, and the sidebar is drawn from it: a host that cannot open one
  // gets no button, because a button that cannot work is worse than none.
  let can_pick = offers_picker(args)
  let app : App = {
    root,
    default_model_id: args.model,
    base_url: args.base_url,
    // A key is no longer required to start: with none, the page comes up and the panel is where a
    // reader puts one. Starting with nothing usable and refusing to serve is how a missing key
    // used to look, and it gave no way to fix it without editing a shell profile.
    api_key: "",
    key_source: "none",
    key_hint: "",
    env_key,
    env_key_set: env_key != "",
    settings,
    settings_lock: @async.Mutex(),
    address: "127.0.0.1:\{args.port}",
    flag_max_cost: args.max_cost,
    flag_max_rounds: args.max_rounds,
    flag_max_seconds: args.max_seconds,
    limits: @core.choose_limits(
      args.max_rounds,
      args.max_cost,
      args.max_seconds,
      settings,
    ),
    hub: @server.Hub::new(),
    registry: [first],
    // The records from last time, not an empty store. A background job outlives the tool call that
    // started it, and it outlives the server too when the server is killed — so the previous run's
    // children are processes that exist and that only this file remembers. An empty store here is
    // how those become orphans nobody can find.
    jobs: @platform.load_jobs(home),
    labels: LabelCache::new(),
    home,
    skills_by_cwd: Map([]),
    live_pids: [],
    saved_jobs: "",
    displayed: first.path,
    deleted: None,
    expanded: Map([]),
    can_pick,
  }
  app.set_key(choice)
  // Logged, so a reader who is wondering which of three keys is in use can find out from the
  // terminal the process was started in.
  log("settings \{@platform.settings_path(home)}")
  match choice {
    Some(chosen) =>
      log(
        "key     \{@html.mask_key(chosen.key)} from \{key_source_label(key_source_name(Some(chosen)))}",
      )
    None => log("key     none: save one in the settings panel")
  }
  log("wei     http://127.0.0.1:\{args.port}")
  log("model   \{args.model}")
  // Which tools a turn gets, and where the answer came from. A reader who ran `--mode code` and is
  // wondering why the model is behaving differently should be able to see it without opening the
  // panel — and `saved` says the panel is where it came from.
  log(
    "mode    \{app.settings.tool_mode.to_string()} (\{app.tools().length()} tools\{if args.mode is Some(_) { ", --mode" } else { ", saved" }})",
  )
  log("cwd     \{cwd}")
  log("session \{first.path}")
  log("store   \{root}")
  // Before the server starts serving, so a panel that asks what is running gets an answer that has
  // already been checked against the process table rather than one still claiming last run's jobs.
  app.reconcile_jobs()

  // Display changes go through a queue so that the order they arrive in is the order they happen
  // in: two clicks in quick succession must not leave the page showing the first one. Turns do not
  // go through it — they run in their own session's slot, in parallel.
  let displays : @aqueue.Queue[Job] = @aqueue.Queue(
    kind=@aqueue.Kind::Unbounded,
  )

  @async.with_task_group(group => {
    // The one thing a route needs that belongs to the process rather than to the application: a
    // turn runs as a task of this group, so the group outlives the server that asked for it and
    // stops everything when it is cancelled.
    let requests = Requests::new(
      app,
      displays,
      (runner, text) => ignore(group.spawn(() => run_prompt(app, runner, text))),
      runner => {
        // The prompt is read back from the log rather than passed in, because the one in flight is the
        // one the interrupted turn was started with — the reader chose to continue it, not to retype it.
        let in_flight = match runner.session.in_flight_prompt() {
          Some(prompt) => prompt
          None => ""
        }
        ignore(
          group.spawn(() => run_prompt(app, runner, in_flight, continuing=true)),
        )
      },
      () => @platform.pick_directory(),
    )
    // Jobs are watched, not polled by the reader: a process that exits on its own has to stop being
    // listed as running, and the exit code is worth seeing. One process table per tick rather than
    // a `kill -0` per pid, because the question is the same for every job.
    ignore(
      group.spawn(() => {
        while true {
          @async.sleep(2000)
          let live : Array[Int] = []
          for entry in @platform.process_table() {
            live.push(entry.0)
          }
          let changed = app.jobs.settle_gone(
            pid => {
              let mut found = false
              for running in live {
                if running == pid {
                  found = true
                }
              }
              found
            },
            now=@env.now().reinterpret_as_int64(),
          )
          if changed {
            requests.tell(
              @html.Patch::Replace(
                target="jobs",
                html=render_jobs(app, @env.now().reinterpret_as_int64()),
              ),
            )
          }
        }
      }),
    )
    // The display worker. Guarded, because it runs in a task group whose other member is the
    // server: an error escaping here would cancel the listener, and one unreadable session file
    // would stop the process from serving anything — which looks exactly like a frozen page.
    ignore(
      group.spawn(() => {
        while true {
          let job = displays.get()
          // Logged here rather than in `apply_display`: a stderr write from a task running
          // concurrently with others aborts the process under `moon test`, so logging cannot live in
          // a module that is tested. A display change arriving from somewhere unexpected is worth
          // seeing, and the sidebar's click delegation is the only intended source.
          log(job.label())
          try requests.apply_display(job) catch {
            err => {
              log("job failed: \{err}")
              requests.say("failed: \{err}")
            }
          } noraise {
            _ => ()
          }
        }
      }),
    )
    // A port already taken is the one startup failure worth naming: it is what running a second
    // instance looks like. Converted rather than logged, so a single writer produces the message —
    // a log line racing the runtime's own error output garbles both.
    try @server.serve(args.port, app.hub, requests.routes()) catch {
      err =>
        raise Failure::Failure(
          "cannot listen on 127.0.0.1:\{args.port} (\{err}). Another instance may be running; pass --port to choose another.",
        )
    } noraise {
      _ => ()
    }
  })
}
