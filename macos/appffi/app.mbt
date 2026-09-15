///|
/// A native shell around the agent: one session, one turn at a time, and a line of JSON out for
/// every fact the host needs to draw.
///
/// This package is where the second front end is built from. It reuses everything below the view
/// — `core`, `platform`, `agent` — and shares neither `html` nor `server`: over there the server
/// owned the document and the browser patched it, and here the host owns the view and draws it
/// from facts. `macos/README.md` has the reasoning and what the MVP leaves out.
///
/// The state below is the state the web UI keeps in its `Runner`, minus everything that only means
/// something next to a document: the transcript window, the live patch ids, the subscribers. What
/// is left is what a session *is*.

///|
/// How long the command loop naps between looks at the inbox.
///
/// A poll because the inbox is filled from another thread and MoonBit has no way to be woken by
/// it that does not itself need a thread. 50ms is below the threshold where a person notices a
/// keystroke not landing, and the loop is two syscalls when the queue is empty.
const POLL_MS : Int = 50

///|
priv struct Shell {
  base_url : String
  jobs : @core.JobStore
  /// The settings in force. Replaced when the panel saves one, so that the file, this value and the
  /// next turn cannot disagree about which key is being sent.
  mut settings : @core.AppSettings
  /// Where the settings file lives. Kept for the same reason as `root`: what the panel writes and
  /// what it reads back have to be one path, and a second lookup is a second answer.
  home : String
  /// Where sessions live. Kept on the shell rather than looked up per use, because the list, a new
  /// session and the switch that reads one all have to agree about it.
  root : String
  /// The session as it stands. Replaced after each turn with the driver's copy, which is the one
  /// that has the new entries in it.
  mut session : @core.Session
  /// Which session is on screen. Not final: the reader can switch, which is what the sidebar is.
  mut path : String
  mut cwd : String
  mut model_id : String
  /// Whether a turn is running. Written by the turn and read by the command loop, which are the same
  /// thread — MoonBit's async is cooperative — so this needs no lock, only the discipline that the
  /// turn sets it before its first `await` and clears it after its last.
  mut busy : Bool
  /// What the sidebar's labels cost, cached across refreshes.
  labels : Labels
  /// One turn at a time, for the reason the web UI has the same lock: two turns sharing a session
  /// interleave their writes into one file and fork its history — a fork this project has already
  /// produced once, and it left entries naming a parent that no longer existed.
  turns : @async.Mutex
  /// Read by the running turn, written by the command loop, which is why it is a `Ref`: the
  /// `should_stop` closure has to see the newest value rather than the one captured when the turn
  /// began.
  aborting : Ref[Bool]
}

///|
/// Where the session log lives, unless the host says otherwise.
fn store_root(home : String) -> String {
  match @env.get_env_var("PI_SHELL_STORE") {
    Some(value) if value != "" => value
    _ => "\{home}/.pi-mb/sessions"
  }
}

///|
/// The key a turn will send, and where it came from.
///
/// The precedence is `@core.choose_api_key` rather than the order of three `if`s, so a variable
/// still overrules the saved key and the panel and the turn cannot disagree about which is in use.
///
/// pi's credential store is deliberately not consulted. The panel saves a key where this shell can
/// write it, and a third source that came from somewhere else — pi's own files, which this shell
/// cannot read back to describe — would be a key the panel could not explain.
fn resolve_key(settings : @core.AppSettings) -> @core.KeyChoice? {
  @core.choose_api_key(env_key(), settings.saved_api_key, None)
}

///|
/// The directory the agent works in, when no session says otherwise.
///
/// A double-clicked `.app` is launched with `/` as its working directory — Finder passes no
/// directory, and the kernel's default is the root — so taking that at face value would put every
/// session started from the Finder in a store slice of its own, run its tools against the root of
/// the volume, and describe a workspace called nothing at all. The home directory is the honest
/// stand-in: it is where a person's own terminal opens, and it is at least a directory that means
/// something.
///
/// Only `/` is treated this way. Anything else is a directory somebody chose — a shell's `cd`, a
/// launcher, "Open With" — and second-guessing those would be worse than the problem.
fn working_dir(cwd : String, home : String) -> String {
  if cwd == "/" {
    home
  } else {
    cwd
  }
}

///|
/// Open the session this process should show: the file named by `PI_SHELL_SESSION`, or a new one
/// in the current directory.
///
/// Resuming is the whole of the persistence work paying off — the file was written by whatever ran
/// last, and it is read back through the same parser the round-trip verifier exercises.
async fn open_session(
  shell_root : String,
  cwd : String,
) -> (@core.Session, String) {
  match @env.get_env_var("PI_SHELL_SESSION") {
    Some(path) if path != "" => {
      guard @platform.path_exists(path) else {
        raise Failure::Failure("no session file at \{path}")
      }
      let session = @platform.load_session(path)
      let entries = session.repair_entries(@env.now().reinterpret_as_int64())
      if entries.length() > 0 {
        // The closers go into the log, not only into memory: a repair that lives until the process
        // exits is not a repair.
        @platform.append_entries(path, entries)
        (session.add_entries(entries), path)
      } else {
        (session, path)
      }
    }
    _ => fresh_session(shell_root, cwd)
  }
}

///|
/// A session that has not been written yet: its header, and where it would go.
///
/// Not written here. A session is created empty and filled in by whoever appends the first entry,
/// which keeps a store from filling up with header-only files for conversations nobody ever had —
/// files a picker would have to show and a reader would have to scroll past.
fn fresh_session(root : String, cwd : String) -> (@core.Session, String) {
  let now = @env.now().reinterpret_as_int64()
  let id = @core.new_entry_id()
  let path = @core.session_file_path(root, cwd, now, id)
  let header : @core.SessionHeader = {
    id,
    timestamp: @core.format_iso_utc(now),
    cwd,
    parent_session: None,
    version: Some(3),
  }
  (@core.Session::new(header, []), path)
}

///|
async fn Shell::open() -> Shell {
  let home = match @env.get_env_var("HOME") {
    Some(value) if value != "" => value
    _ => raise Failure::Failure("HOME is not set")
  }
  let cwd = @platform.current_dir()
  let settings = @platform.load_settings(home)
  let root = store_root(home)
  let (session, path) = open_session(root, working_dir(cwd, home))
  // A resumed session brings its own directory with it: `PI_SHELL_SESSION` can name a file written
  // somewhere else, and running its tools in the directory this process happens to have been started
  // in would be a different session's workspace. An empty one is a header nobody filled in, and the
  // process's own directory is the better guess.
  let working = if session.header.cwd == "" {
    working_dir(cwd, home)
  } else {
    session.header.cwd
  }
  let base_url = match @env.get_env_var("DEEPSEEK_BASE_URL") {
    Some(value) if value != "" => value
    _ => "https://api.deepseek.com"
  }
  {
    base_url,
    jobs: @core.JobStore::new(),
    settings,
    home,
    root,
    session,
    path,
    cwd: working,
    model_id: session_model(session),
    busy: false,
    labels: Labels::new(),
    turns: @async.Mutex(),
    aborting: { val: false, },
  }
}

// ── the events ─────────────────────────────────────────────────────────────
//
// One function per event, so each field name exists in exactly one place. The shape is
// deliberately flat: a host-side `Codable` struct per `kind` is the whole of the Swift side's
// decoding, and there is no schema to keep in step beyond these names.

///|
/// Every event carries its `kind` first, because that is what the host switches on.
fn event(kind : String, fields : Array[(String, Json)]) -> Json {
  let pairs : Array[(String, Json)] = [("kind", Json::string(kind))]
  for field in fields {
    pairs.push(field)
  }
  Json::object(Map(pairs))
}

///|
/// The session that is open, and what a reader needs to know about it. Sent first, and again
/// whenever one of those four facts changes — saving a key is what made it a snapshot rather than a
/// greeting, because the window a key saves is a window that can send again.
fn say_ready(shell : Shell, key_source : String) -> Unit {
  emit(
    event("ready", [
      ("session", Json::string(shell.path)),
      ("model", Json::string(@core.model_spec_for(shell.model_id).0.label())),
      ("cwd", Json::string(shell.cwd)),
      // Named rather than implied: an empty key is a thing the host has to say out loud, and
      // "where did the key come from" is the question the first failure always raises.
      ("key", Json::string(key_source)),
    ]),
  )
}

///|
/// The prompt, echoed so the host can put it in the conversation without having kept its own
/// copy of what it sent.
fn say_user(text : String) -> Unit {
  emit(event("user", [("text", Json::string(text))]))
}

///|
/// A block of the answer, or of the reasoning, as it streams.
///
/// Deltas under one `id` rather than one string per frame: that is what makes the host's append
/// cheap, and it is the same decision the web UI made when a replacement-per-delta turned out to
/// be quadratic.
fn say_piece(kind : String, id : String, delta : String) -> Unit {
  emit(event(kind, [("id", Json::string(id)), ("delta", Json::string(delta))]))
}

///|
/// A tool, running or finished, always under the same id so the finished row replaces the running
/// one instead of leaving it behind.
fn say_tool(
  id : String,
  name : String,
  detail : String,
  done : Bool,
  output : String,
  is_error : Bool,
) -> Unit {
  emit(
    event("tool", [
      ("id", Json::string(id)),
      ("name", Json::string(name)),
      ("detail", Json::string(detail)),
      ("done", Json::boolean(done)),
      ("output", Json::string(output)),
      ("error", Json::boolean(is_error)),
    ]),
  )
}

///|
fn say_status(text : String) -> Unit {
  emit(event("status", [("text", Json::string(text))]))
}

///|
/// A turn is over. `text` is empty when it finished normally — the answer is the report — and
/// otherwise says which guard stopped it, which is the one thing the figures cannot say.
fn say_end(text : String, calls : Int, tools : Int, cost : Double) -> Unit {
  emit(
    event("end", [
      ("text", Json::string(text)),
      // Given an integer spelling rather than a float: JSON has one number type and a host that
      // decoded these as doubles would have to decide what `19.0` means for a count.
      ("calls", Json::number(calls.to_double(), repr=calls.to_string())),
      ("tools", Json::number(tools.to_double(), repr=tools.to_string())),
      ("cost", Json::string(@core.format_cost(cost))),
    ]),
  )
}

///|
fn say_error(text : String) -> Unit {
  emit(event("error", [("text", Json::string(text))]))
}

// ── one turn ───────────────────────────────────────────────────────────────

///|
/// What the host should say once a turn is over.
///
/// Deliberately not the turn's figures — those are reported as they happen, and saying them again
/// one line lower puts the same numbers on screen twice, which is where a reader stops trusting
/// either copy. What is left is what the figures cannot say.
fn ending_text(result : @agent.TurnResult, aborted : Bool) -> String {
  if aborted {
    "stopped"
  } else if result.cost_limit_hit {
    "stopped at the cost limit"
  } else if result.time_limit_hit {
    "stopped at the time limit"
  } else if !result.settled {
    "gave up without a final answer"
  } else {
    ""
  }
}

///|
/// The turn is over: the session can be left, replaced or deleted again.
fn Shell::clear_busy(self : Shell) -> Unit {
  self.busy = false
}

///|
/// Run one prompt to completion, and say everything that happened.
///
/// The shape is the web UI's `run_turn` with the document taken out. What is left is the part that
/// was never about HTML: build the request from the session's own model and the process's settings,
/// stream, and report.
async fn Shell::run_turn(self : Shell, prompt : String) -> Unit {
  self.aborting.val = false
  // Before the first `await`, so that a command arriving during the turn sees it set. The sidebar
  // reads this: a turn is the one thing a session cannot be switched out from under.
  self.busy = true
  // A function rather than an assignment because `defer` takes an expression and an assignment is
  // not one — and the point is that this runs on the way out of every path, including the one that
  // failed.
  defer self.clear_busy()
  say_user(prompt)
  say_status("thinking…")
  let mode = self.settings.tool_mode
  // The session's model, not the process's: this is the one line that makes a resumed session's
  // recorded choice mean anything. Its pricing and window come from the same catalog entry, so a
  // turn cannot be billed at one model's rates while calling another.
  let spec = @core.model_spec_for(self.model_id).0
  let tools = @core.tools_for_mode(mode)
  let instructions = @core.choose_instructions(
    self.settings,
    @platform.workspace_agents_md(self.cwd),
  )
  let context = @agent.AgentContext::new(
    session=self.session,
    session_path=self.path,
    cwd=self.cwd,
    api_key=self.api_key(),
    system_prompt=@core.build_system_prompt(self.cwd, tools, mode~, sections=[
      instructions.text,
    ]),
    tools~,
    model=spec.id,
    base_url=self.base_url,
    pricing=spec.pricing,
    context_window=spec.context_window,
    jobs=self.jobs,
  )
  // The two things that change while the turn runs: which block the deltas belong to, and which
  // row a tool report belongs to. Both are ids rather than nodes — the host holds the nodes, and
  // all that crosses is the name of the one to write into.
  let mut piece_id = ""
  let mut piece_seq = 0
  let mut piece_kind = ""
  // A tool is one row from start to finish, so the id is chosen when it starts and reused when it
  // reports. The report does not carry the id the start did — it carries the model's `call_id`,
  // which the running handle never had — so the pairing has to be kept here.
  let mut tool_seq = 0
  let mut open_tool : String? = None
  // Bumped by a tool, so the answer that follows one is a new block rather than more text on the
  // block from before the tool call.
  let new_piece = (kind : String) => {
    piece_seq += 1
    piece_id = "\{kind}-\{piece_seq}"
    piece_kind = kind
    piece_id
  }
  let on_delta : async (@core.StreamEvent) -> Unit = delta => {
    let (kind, text) = match delta {
      @core.Text(delta~) => ("reply", delta)
      @core.Thinking(delta~) => ("thinking", delta)
    }
    let id = if piece_kind == kind { piece_id } else { new_piece(kind) }
    say_piece(kind, id, text)
  }
  let on_tool_process : async (@agent.ToolHandle?) -> Unit = handle => {
    match handle {
      Some(running) => {
        tool_seq += 1
        let id = "tool-\{tool_seq}"
        open_tool = Some(id)
        // The next text belongs to a new block. This is the moment the previous one stopped being
        // the newest thing that happened.
        piece_kind = ""
        say_tool(id, running.name, running.detail, false, "", false)
      }
      None => ()
    }
  }
  let on_tool : async (@agent.ToolEvent) -> Unit = report => {
    let id = match open_tool {
      Some(value) => value
      None => {
        // A report that was never announced. Rare, and worth handling rather than dropping: a
        // tool result that never reaches the reader is a turn that looks stalled.
        tool_seq += 1
        "tool-\{tool_seq}"
      }
    }
    open_tool = None
    say_tool(id, report.name, "", true, report.output, report.is_error)
  }
  // The counts are the cheapest possible "still alive" signal, and the one a reader watches when a
  // turn is taking minutes — a turn can run nineteen model calls and twenty-five tool calls, and
  // silence for that long reads as a hang.
  let on_progress : async (Int, Int) -> Unit = (calls, tools_done) => {
    say_status("working… \{calls} model call(s), \{tools_done} tool call(s)")
  }
  // Every commit, not just the end of the turn: this is what makes a cost figure move while the
  // turn runs, because each model call's numbers are in the log the moment the response ends.
  let on_commit : async (@core.Session) -> Unit = committed => {
    self.session = committed
  }
  let limits = @core.choose_limits(None, None, None, self.settings)
  let started = @env.now().reinterpret_as_int64()
  let finished = @agent.run_turn(
    context,
    prompt,
    started,
    thinking_level="high",
    max_rounds=limits.max_rounds.value.to_int(),
    max_cost=limits.max_cost.value,
    max_seconds=limits.max_seconds.value.to_int(),
    continuing=self.session.turn_in_flight(),
    on_delta~,
    should_stop=() => self.aborting.val,
    on_tool~,
    on_tool_process~,
    on_progress~,
    on_commit~,
  ) catch {
    err => {
      say_error("the turn failed: \{err}")
      say_status("failed")
      return
    }
  }
  self.session = finished.session
  say_end(
    ending_text(finished, self.aborting.val),
    finished.model_calls,
    finished.tool_calls,
    finished.usage.cost.total,
  )
}

///|
/// The key this process should send, resolved at the moment of the turn so that saving one means
/// the next turn uses it rather than the next process.
fn Shell::api_key(self : Shell) -> String {
  match resolve_key(self.settings) {
    Some(choice) => choice.key
    None => ""
  }
}

// ── the command loop ───────────────────────────────────────────────────────

///|
/// What a command from the host means.
///
/// Bare text is a prompt; the rest are the words a host can say that are not one — `abort`, `quit`,
/// and the sidebar's four. Words rather than a protocol because the host is the only caller, and a
/// protocol for seven words is a second thing to keep in step with it.
///
/// Paths are not quoted: a session path is a path, and one with a newline in it could not have
/// arrived as one line of a line-oriented protocol anyway.
fn command_of(line : String) -> Command {
  match line {
    "abort" => Abort
    "quit" => Quit
    "/sessions" => ListSessions
    "/new" => NewSession
    "/settings" => ListSettings
    "/key-clear" => ClearKey
    _ =>
      if line.has_prefix("/model ") {
        Model(line[7:].trim().to_owned())
      } else if line == "/model" {
        ReportModel
      } else if line.has_prefix("/open ") {
        Open(line[6:].trim().to_owned())
      } else if line.has_prefix("/delete ") {
        Delete(line[8:].trim().to_owned())
      } else if line.has_prefix("/mode ") {
        SetMode(line[6:].trim().to_owned())
      } else if line.has_prefix("/key ") {
        // Not trimmed: a key is a credential, and a space inside one is the credential's business.
        // The trailing newline is already gone — commands arrive one line at a time.
        SaveKey(line[5:].to_owned())
      } else {
        Prompt(line)
      }
  }
}

///|
priv enum Command {
  Prompt(String)
  Abort
  Quit
  Model(String)
  ReportModel
  ListSessions
  NewSession
  Open(String)
  Delete(String)
  ListSettings
  SaveKey(String)
  ClearKey
  SetMode(String)
}

///|
/// Whether the session can be left, replaced or removed, having said so if it cannot.
///
/// One turn at a time, and the turn owns the session while it runs: it appends to the file and
/// writes the session back at every commit, so switching away mid-turn would leave the reader
/// looking at a transcript that is not the one still being written. Refused rather than queued,
/// because the answer is one the reader can act on — stop the turn first.
fn Shell::idle(self : Shell) -> Bool {
  if self.busy {
    say_error("a turn is running — stop it first")
    return false
  }
  true
}

///|
/// Take commands until the host says to quit.
///
/// The loop is a poll rather than a wakeup, and the reason is the price of the alternative: being
/// woken from another thread needs a pipe and a reader registered with the event loop, which is a
/// second thread and a second failure mode for a keystroke that is already fast enough. The cost of
/// the poll is two syscalls when there is nothing to read.
///
/// A prompt does not run here. It is spawned, because a turn takes minutes and the commands that
/// arrive during one are exactly the commands that matter — `abort` is useless if the loop reading
/// it is blocked behind the turn it is meant to stop.
async fn Shell::serve(self : Shell) -> Unit {
  let choice = resolve_key(self.settings)
  let key_source = match choice {
    Some(c) =>
      match c.source {
        @core.Environment => "DEEPSEEK_API_KEY"
        @core.Saved => "saved"
        @core.Pi => "pi"
      }
    None => "missing"
  }
  say_ready(self, key_source)
  // A session that was resumed — by `PI_SHELL_SESSION`, or by whatever ran last — has a transcript
  // already, and the host has never seen any of it. The same replay a switch gets, because it is the
  // same situation: a conversation the reader is looking at and the window is not.
  say_history(self.session)
  // The list goes out with the first breath rather than when the sidebar asks for it: the window is
  // drawn before this line arrives, and a sidebar that fills in a moment later is a sidebar the
  // reader watches arrive.
  self.say_sessions()
  if choice is None {
    say_error("no API key: set DEEPSEEK_API_KEY and reopen")
  }
  @async.with_task_group(group => {
    let mut quit = false
    while !quit {
      let line = take_command()
      if line != "" {
        match command_of(line) {
          Prompt(text) =>
            group.spawn_bg(
              () => {
                // One turn at a time per session. Acquired inside the spawned task rather than
                // before spawning it, because a command loop that blocks here is a command loop
                // that cannot answer `abort`.
                self.turns.acquire()
                defer self.turns.release()
                self.run_turn(text)
                // After the lock, not inside the turn: the label of a session nobody has asked
                // anything in yet is written by its first entry, and the list is what says so.
                self.say_sessions()
              },
              no_wait=true,
            )
          Abort => {
            self.aborting.val = true
            say_status("stopping…")
          }
          ListSessions => self.say_sessions()
          NewSession => if self.idle() { self.create() }
          Open(path) => if self.idle() { self.show(path) }
          Delete(path) => if self.idle() { self.discard(path) }
          ListSettings => self.say_settings()
          SaveKey(key) => self.save_key(key)
          ClearKey => self.save_key("")
          // Deliberately not gated on being idle: a mode is read when the next request is built, so
          // changing it mid-turn is a decision about the turn after this one — which is allowed, and
          // is exactly when a reader wants it.
          SetMode(name) => self.set_mode(name)
          ReportModel => say_status(self.model_report())
          Model(id) => {
            let (_, known) = @core.model_spec_for(id)
            if known {
              self.model_id = id
              say_status("model: \{@core.model_spec_for(id).0.label()}")
            } else {
              // Refused rather than accepted, and the reason is what makes it worth a branch: a
              // model this build does not know has no pricing and no context window, so accepting
              // one would bill the turn at the default's rates and silently send the wrong prompt.
              say_error(
                "unknown model \{id} · available: \{@core.model_ids().join(", ")}",
              )
            }
          }
          Quit => {
            self.aborting.val = true
            quit = true
          }
        }
      }
      @async.sleep(POLL_MS)
    }
  })
}

///|
fn Shell::model_report(self : Shell) -> String {
  let (spec, known) = @core.model_spec_for(self.model_id)
  let current = if known {
    spec.label()
  } else {
    // The log names a model this build does not have. Said plainly, because the alternative is a
    // reader wondering why the cost figures look wrong for the model they thought they chose.
    "\{self.model_id} (unknown to this build; running on \{spec.id})"
  }
  "model: \{current} · available: \{@core.model_ids().join(", ")}"
}

// ── the entry point ────────────────────────────────────────────────────────

///|
/// Start the shell, and say so if it could not start.
async fn start() -> Unit {
  let shell = Shell::open() catch {
    err => {
      say_error("could not start: \{err}")
      return
    }
  }
  shell.serve()
}

///|
/// The entry point the host calls, once, on a thread of its own.
///
/// Not the main thread, and that is a requirement rather than a preference: macOS wants the main
/// thread for its own event loop, and `moonbitlang/async` wants one to run the event loop that
/// drives every socket and timer the agent uses. The two cannot be the same thread, so the host
/// gives MoonBit a thread and keeps its own. See `macos/README.md`.
///
/// `run_async_main` is `moonbitlang/async`'s own entry point — the runtime's event loop setup, the
/// signal handling and the cleanup after the last task — spelled out here rather than left to the
/// compiler because this package has no `main` to hang it on.
#export_name("pi_run")
pub fn run() -> Unit {
  @async.run_async_main(start)
}
