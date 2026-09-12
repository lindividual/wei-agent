///|
/// The web UI: an agent, its session, and an HTTP server, in one process and one
/// binary.
///
/// The server is the only writer of the document. The browser applies patches and
/// posts prompts; it holds no model of the conversation, so there is nothing for
/// it and the server to disagree about.
///
/// ## One turn at a time
///
/// Every request that changes the conversation — a prompt, a session switch —
/// becomes a job on a single queue, and one worker drains it. That is the whole
/// concurrency story, and it is load-bearing: two tabs sending a prompt at the
/// same moment must produce two turns in order, not two turns sharing one session
/// and interleaving their writes into one file. Ordering is the queue's, not the
/// HTTP layer's, so a switch issued mid-turn waits for that turn instead of
/// swapping the session out from under it.

///|
/// A one-way flag the running turn polls.
struct AbortFlag {
  mut value : Bool
}

///|
/// One queued piece of work.
enum Job {
  /// A user message to run as a turn.
  Prompt(String)
  /// Open this session file, wherever its workspace is.
  Switch(String)
  /// Start a new session in this working directory.
  New(String)
}

///|
/// Where the process should start.
enum Start {
  New
  /// The most recently written session for this directory.
  Continue
  /// A path, or a session id to look up under this directory.
  Session(String)
}

///|
/// A parsed command line.
struct Args {
  port : Int
  model : String
  start : Start
  store : String
}

///|
fn usage() -> String {
  "usage: ui [--port N] [--model M] [--continue | --resume <path|id>] [--store DIR]"
}

///|
fn parse_args(argv : Array[String]) -> Args raise {
  let mut port = 8790
  let mut model = "deepseek-v4-flash"
  let mut start = Start::New
  let mut store = ""
  let mut index = 1
  while index < argv.length() {
    let flag = argv[index]
    let needs_value = flag == "--port" ||
      flag == "--model" ||
      flag == "--resume" ||
      flag == "--store"
    if needs_value && index + 1 >= argv.length() {
      raise Failure::Failure("\{flag} needs a value\n\{usage()}")
    }
    match flag {
      "--port" => {
        port = try @string.parse_int(argv[index + 1]) catch {
          _ => raise Failure::Failure("--port needs a number")
        } noraise {
          value => value
        }
        index += 2
      }
      "--model" => {
        model = argv[index + 1]
        index += 2
      }
      "--resume" => {
        start = Session(argv[index + 1])
        index += 2
      }
      "--store" => {
        store = argv[index + 1]
        index += 2
      }
      "--continue" | "-c" => {
        start = Continue
        index += 1
      }
      "--new" => {
        start = New
        index += 1
      }
      "--help" | "-h" => raise Failure::Failure(usage())
      _ => raise Failure::Failure("unknown argument: \{flag}\n\{usage()}")
    }
  }
  { port, model, start, store, }
}

///|
fn field(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
async fn api_key(home : String) -> String? {
  match @env.get_env_var("DEEPSEEK_API_KEY") {
    Some(key) if key != "" => return Some(key)
    _ => ()
  }
  let path = "\{home}/.pi/agent/auth.json"
  if !@platform.path_exists(path) {
    return None
  }
  let store = @json.parse(@platform.read_text(path))
  let provider = match field(store, "deepseek") {
    Some(value) => value
    None => return None
  }
  match field(provider, "key") {
    Some(String(key)) => Some(key)
    _ => None
  }
}

///|
fn home_dir() -> String raise {
  match @env.get_env_var("HOME") {
    Some(home) if home != "" => home
    _ => raise Failure::Failure("HOME is not set")
  }
}

///|
/// A fresh session in this workspace, in memory and not yet on disk.
///
/// The file appears when the first entry is written, which is what keeps a store from
/// filling up with header-only sessions that a picker then has to show.
fn create_session(root : String, cwd : String) -> (@core.Session, String) {
  let now = @env.now().reinterpret_as_int64()
  let id = @core.new_entry_id()
  let path = @core.session_file_path(root, cwd, now, id)
  let header = new_header(id, cwd, now)
  (@core.Session::new(header, []), path)
}

///|
/// Open a path, closing an interrupted turn if there is one.
async fn open_path(path : String) -> @core.Session {
  let session = @platform.load_session(path)
  let entries = session.repair_entries(@env.now().reinterpret_as_int64())
  if entries.is_empty() {
    return session
  }
  // The closers go into the log, not only into memory: a repair that exists only
  // until the process exits is not a repair.
  @platform.append_entries(path, entries)
  session.add_entries(entries)
}

///|
/// A session header for a brand new conversation.
fn new_header(
  id : String,
  cwd : String,
  timestamp : Int64,
) -> @core.SessionHeader {
  {
    id,
    timestamp: @core.format_iso_utc(timestamp),
    cwd,
    parent_session: None,
    version: Some(3),
  }
}

///|
/// Open the session the command line asked for, creating one when needed.
///
/// Resuming is where the format work pays off: the file was written by whatever
/// ran last — this process, an older build, or pi itself — and it is read back
/// through the same parser the round-trip verifier exercises.
async fn open_session(
  args : Args,
  root : String,
  cwd : String,
) -> (@core.Session, String) {
  match args.start {
    New => create_session(root, cwd)
    Continue =>
      match @platform.newest_session(root, cwd) {
        None => create_session(root, cwd)
        Some(path) => (open_path(path), path)
      }
    Session(value) => {
      let path = if value.contains("/") {
        value
      } else {
        match @platform.find_session(root, value) {
          Some(found) => found
          None => raise Failure::Failure("no session \{value} in \{root}")
        }
      }
      if !@platform.path_exists(path) {
        raise Failure::Failure("no session file at \{path}")
      }
      (open_path(path), path)
    }
  }
}

///|
/// The sidebar's view of the store: every workspace that has sessions, newest
/// first, each described from the top of its newest file.
///
/// Bounded per file and per workspace on purpose. Describing a workspace means
/// reading one header, and a sidebar that read every session in full would make
/// opening the UI cost as much as replaying all of them.
async fn workspace_items(
  root : String,
  cwd : String,
  current_session : String,
) -> Array[@html.WorkspaceItem] {
  let out : Array[@html.WorkspaceItem] = []
  for stored in @platform.list_workspaces(root, sidebar_sessions()) {
    let sessions : Array[@html.SessionItem] = []
    for session in stored.sessions {
      let prefix = @platform.read_prefix(session.path, 64 * 1024)
      sessions.push({
        path: session.path,
        label: @core.session_label(prefix),
        modified: session.modified,
        current: session.path == current_session,
      })
    }
    out.push({
      cwd: stored.cwd,
      name: workspace_name(stored.cwd),
      active: stored.cwd == cwd,
      sessions,
      hidden: stored.total - sessions.length(),
    })
  }
  out
}

///|
/// How many sessions a workspace shows before it just says how many more there are.
fn sidebar_sessions() -> Int {
  10
}

///|
/// The last path component, which is what a reader recognises a project by.
fn workspace_name(cwd : String) -> String {
  let parts = cwd.split("/")
  let mut name = cwd
  for part in parts {
    if part != "" {
      name = part.to_owned()
    }
  }
  if name == "" {
    cwd
  } else {
    name
  }
}

///|
fn status_text(result : @agent.TurnResult, aborted : Bool) -> String {
  let out = StringBuilder()
  if aborted {
    out.write_string("stopped after \{result.model_calls} model calls")
  } else if !result.settled {
    // The model kept asking for tools until the limit. Said plainly, because the
    // reader is the one who has to decide what to do about it.
    out.write_string(
      "gave up after \{result.model_calls} model calls without a final answer",
    )
  } else {
    let plural = if result.model_calls == 1 { "" } else { "s" }
    out.write_string(
      "\{result.model_calls} model call\{plural}, \{result.tool_calls} tool calls",
    )
  }
  if result.compactions > 0 {
    out.write_string(", \{result.compactions} compacted")
  }
  let usage = result.usage
  if usage.total_tokens > 0 {
    out.write_string(
      " · \{usage.input} in / \{usage.output} out" +
      " · $\{format_cost(usage.cost.total)}",
    )
  }
  out.to_string()
}

///|
/// A cost with enough digits to be non-zero without being unreadable.
///
/// Cents are the wrong unit for a turn: a short one costs a few hundredths of a
/// millicent, and rounding to cents would print every turn as $0.00. Below a tenth
/// of a dollar the extra digits are the information.
fn format_cost(value : Double) -> String {
  let decimals = if value < 0.1 { 6 } else { 4 }
  let scale = if decimals == 6 { 1000000.0 } else { 10000.0 }
  let scaled = (value * scale).round().to_int()
  let text = "\{scaled}"
  let padded = if text.length() >= decimals {
    text
  } else {
    zeroes(decimals - text.length()) + text
  }
  "0." + padded
}

///|
fn zeroes(count : Int) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_char('0')
  }
  out.to_string()
}

///|
/// Tell a running turn to stop, and say so, when the reader asks to go elsewhere.
///
/// Waiting for the turn would be the safe thing and the wrong one: a turn can run for
/// minutes, and someone who clicks another session has already decided they want to be
/// somewhere else. The turn stops at its next checkpoint and the log keeps whatever it
/// had already written, including — if it was mid-tool — a gap that `session_repair`
/// closes on the next open.
async fn ask_to_leave(
  hub : @server.Hub,
  aborting : AbortFlag,
  busy : Bool,
) -> Unit {
  if busy {
    aborting.value = true
    hub.broadcast(
      @html.Patch::Status(text="stopping the running turn…").to_sse(),
    )
  }
}

///|
/// Run one turn and describe it on the status line.
///
/// Shared by the initial prompt and by every queued one, so a turn behaves the
/// same however it was started.
async fn run_and_report(
  hub : @server.Hub,
  ctx : @agent.AgentContext,
  text : String,
  index : Int,
  aborting : AbortFlag,
  /// Told what the status line says, so that a browser connecting later can be
  /// caught up on it: the line is part of the page's state, not of one connection.
  set_status : (String) -> Unit,
) -> @agent.TurnResult {
  hub.broadcast(
    @html.append_node(
      "transcript",
      @html.render_exchange_start(index, Some(text)),
    ).to_sse(),
  )
  set_status("working…")
  hub.broadcast(@html.Patch::Status(text="working…").to_sse())

  // Streaming text lands in a throwaway container inside the section. When the
  // turn ends, the whole container is replaced by the properly rendered reply —
  // reasoning collapsed, tool calls paired, markdown parsed. The reader sees text
  // appear as it is written and then settle into its final shape, and nothing has
  // to be re-rendered incrementally to get there.
  let stream_root = "streams-\{index}"
  hub.broadcast(
    @html.append_node(
      @html.blocks_id(index),
      @html.el("div", attrs=[@html.attr("id", stream_root)], children=[]),
    ).to_sse(),
  )

  // A turn makes several model calls when it uses tools, and each one writes its own
  // text. Both containers are opened lazily, on the first delta, so a call that only
  // thinks does not leave an empty text element behind.
  let mut open_text : @html.StreamBuffer? = None
  let mut open_thinking : @html.StreamBuffer? = None
  let mut stream_seq = 0
  let report : async (@core.StreamEvent) -> Unit = event => {
    match event {
      @core.Text(delta~) => {
        let buffer = match open_text {
          Some(existing) => existing
          None => {
            stream_seq += 1
            let id = "stream-\{index}-\{stream_seq}"
            hub.broadcast(
              @html.append_node(
                stream_root,
                @html.el(
                  "div",
                  attrs=[@html.cls("text"), @html.attr("id", id)],
                  children=[],
                ),
              ).to_sse(),
            )
            // A small threshold: a short reply is only a few dozen characters, and
            // waiting for 64 of them would mean the reader sees nothing until the
            // turn is over — which is what streaming is for.
            let fresh = @html.StreamBuffer::new(id, threshold=8)
            open_text = Some(fresh)
            fresh
          }
        }
        match buffer.push(delta) {
          Some(patch) => hub.broadcast(patch.to_sse())
          None => ()
        }
      }
      @core.Thinking(delta~) => {
        // Reasoning is streamed too, into a collapsed container. Not streaming it
        // was a mistake: with a model that thinks before every tool call, the page
        // then showed nothing at all for minutes, which reads as a hang. The reader
        // sees "thinking…" and how the text grows if they open it, and the finished
        // turn re-renders it properly.
        let buffer = match open_thinking {
          Some(existing) => existing
          None => {
            stream_seq += 1
            let id = "thinking-\{index}-\{stream_seq}"
            let body = "\{id}-body"
            hub.broadcast(
              @html.append_node(
                stream_root,
                @html.render_thinking_stream(id, body),
              ).to_sse(),
            )
            // A larger threshold than text: this is collapsed, so the only thing a
            // frame buys is the sense that something is happening.
            let fresh = @html.StreamBuffer::new(body, threshold=64)
            open_thinking = Some(fresh)
            fresh
          }
        }
        match buffer.push(delta) {
          Some(patch) => hub.broadcast(patch.to_sse())
          None => ()
        }
      }
    }
  }

  // Each finished tool is shown where it happened, so a long turn reads as work
  // being done rather than as silence. The nodes are throwaway, like the streamed
  // text: the end of the turn replaces the whole container with the paired rendering.
  let mut tool_seq = 0
  let on_tool = (event : @agent.ToolEvent) => {
    tool_seq += 1
    let call : @core.Content = @core.ToolCall(
      id=event.call_id,
      name=event.name,
      arguments=event.arguments,
    )
    let result : @core.ToolResultMessage = {
      tool_call_id: event.call_id,
      tool_name: event.name,
      content: [@core.Text(event.output)],
      is_error: event.is_error,
      timestamp: 0L,
      details: None,
    }
    hub.broadcast(
      @html.append_node(
        stream_root,
        @html.render_tool("live-tool-\{index}-\{tool_seq}", call, Some(result)),
      ).to_sse(),
    )
  }

  // The counts are the cheapest possible "still alive" signal, and the one a reader
  // watches when a turn is taking minutes.
  let on_progress = (calls : Int, tools : Int) => {
    let label = "working… \{calls} model call(s), \{tools} tool call(s)"
    set_status(label)
    hub.broadcast(@html.Patch::Status(text=label).to_sse())
  }

  let result = @agent.run_turn(
    ctx,
    text,
    @env.now().reinterpret_as_int64(),
    thinking_level="high",
    on_delta=report,
    should_stop=() => aborting.value,
    on_tool~,
    on_progress~,
  )
  // Replace the streamed text with the finished rendering. Doing it in one patch
  // is why the streaming path can be simple: it never has to decide what the final
  // markup looks like.
  hub.broadcast(
    @html.replace_node(
      @html.blocks_id(index),
      @html.el(
        "div",
        attrs=[@html.cls("blocks"), @html.attr("id", @html.blocks_id(index))],
        children=[
          @html.render_reply(
            index,
            0,
            @html.reply_pieces(result.session.context().messages),
          ),
        ],
      ),
    ).to_sse(),
  )
  let summary = status_text(result, aborting.value)
  set_status(summary)
  hub.broadcast(@html.Patch::Status(text=summary).to_sse())
  result
}

///|
async fn main {
  let argv = @env.args()
  let args = parse_args(argv)
  let home = home_dir()
  let key = match api_key(home) {
    Some(key) => key
    None =>
      raise Failure::Failure(
        "no DeepSeek key: set DEEPSEEK_API_KEY or log in with pi",
      )
  }
  let root = if args.store == "" {
    "\{home}/.pi-mb/sessions"
  } else {
    args.store
  }
  let cwd = @platform.current_dir()
  // Header-only sessions accumulate from every start that never got used. Ten minutes
  // is long enough that a session another instance is writing right now is safe.
  let pruned = @platform.prune_empty_sessions(
    @core.session_dir_for(root, cwd),
    10L * 60L * 1000L,
  )
  if pruned > 0 {
    log("pruned   \{pruned} empty session(s)")
  }
  let opened = open_session(args, root, cwd)
  let mut session = opened.0
  let mut session_path = opened.1
  // Which directory the agent works in. Not a constant: opening a session from
  // another workspace moves the agent there, tools included.
  let mut cwd = cwd

  let tools = @core.builtin_tools()
  let hub = @server.Hub::new()
  // Shared with the running turn. A cell rather than a `Ref` so there is nothing
  // to import, and mutable rather than a channel because the check has to be
  // synchronous — it runs inside a read loop.
  let aborting : AbortFlag = { value: false, }
  // Jobs instead of direct calls: the worker below is the only thing that touches
  // `session`, so two requests can never overlap on it.
  let jobs : @aqueue.Queue[Job] = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)
  let mut busy = false
  let mut turn = 0
  // The status line belongs to the snapshot, not only to the patches that set it during
  // a turn: a reconnecting browser must not keep showing the summary of a turn that the
  // process it just reconnected to knows nothing about. It starts by saying what is
  // open — including a new session, which has no sidebar row until it is written.
  let mut status_line = if session.entries.length() == 0 {
    "new session in \{cwd}"
  } else {
    "opened \{session.context().messages.length()} messages in \{cwd}"
  }

  let transcript = () => {
    @html.render_transcript(session.context().messages).render()
  }
  let sessions = async fn() {
    let now = @env.now().reinterpret_as_int64()
    let items = workspace_items(root, cwd, session_path)
    @html.render_sessions(items, now).render()
  }
  // Everything that can change while a browser is watching. One definition, used
  // by the first frame of every connection and after a session switch: a reconnect
  // and a switch therefore cannot disagree about what has to be re-sent.
  let regions = async fn() {
    [
      @html.Patch::Replace(target="transcript", html=transcript()),
      @html.Patch::Replace(target="sessions", html=sessions()),
      // The status line is part of what a connection has to be caught up on: a
      // browser that reconnects to a restarted process must not keep showing the
      // summary of a turn that process knows nothing about.
      @html.Patch::Status(text=status_line),
    ]
  }

  let routes : @server.Routes = {
    page: async fn() {
      let row = @html.el("div", attrs=[@html.cls("layout")], children=[
        @html.raw(sessions()),
        @html.raw(transcript()),
      ])
      @html.render_page("pi", stylesheet(), client_script(), [
        row,
        composer(),
        @html.render_status(""),
      ]).render()
    },
    regions,
    prompt: async fn(text) {
      // Answered before the turn starts, so the browser is not left waiting on a
      // request that may take minutes.
      if busy {
        status_line = "queued behind the running turn"
        hub.broadcast(@html.Patch::Status(text=status_line).to_sse())
      }
      ignore(queue_try_put(jobs, Prompt(text)))
    },
    abort: () => aborting.value = true,
    switch_session: async fn(path) {
      ask_to_leave(hub, aborting, busy)
      ignore(queue_try_put(jobs, Switch(path)))
    },
    new_session: async fn(dir) {
      ask_to_leave(hub, aborting, busy)
      ignore(queue_try_put(jobs, New(dir)))
    },
  }

  log("pi-mb   http://127.0.0.1:\{args.port}")
  log("model   \{args.model}")
  log("cwd     \{cwd}")
  log("session \{session_path}")
  log("store   \{root}")

  @async.with_task_group(group => {
    ignore(
      group.spawn(() => {
        while true {
          let job = jobs.get()
          // Every job is guarded. These run inside a task group whose other member is
          // the server, so an error escaping here cancels the listener — one unreadable
          // session file would stop the process from serving anything at all, which
          // looks exactly like a frozen page. Reported instead, and the queue continues.
          try {
            match job {
              Switch(path) => {
                // A switch while a turn runs waits its turn in the queue, so this
                // never interrupts a turn that is writing to the session.
                let (next_session, next_path) = if !@platform.path_exists(path) {
                  create_session(root, cwd)
                } else {
                  (open_path(path), path)
                }
                session = next_session
                session_path = next_path
                // Opening a session moves the agent into its workspace: the session
                // records where it lived, which is the only trustworthy answer.
                cwd = next_session.header.cwd
                aborting.value = false
                status_line = "opened \{next_session.context().messages.length()} messages in \{cwd}"
                for patch in (routes.regions)() {
                  hub.broadcast(patch.to_sse())
                }
              }
              New(dir) => {
                let (next_session, next_path) = create_session(root, dir)
                session = next_session
                session_path = next_path
                cwd = dir
                aborting.value = false
                status_line = "new session in \{cwd}"
                for patch in (routes.regions)() {
                  hub.broadcast(patch.to_sse())
                }
              }
              Prompt(text) => {
                busy = true
                aborting.value = false
                turn += 1
                let index = turn
                // A session that has never had a turn shows as "(empty session)" in
                // the sidebar. Only that case needs the list refreshed afterwards:
                // re-reading every prefix after every turn would be paying for a
                // label that did not change.
                let relabel = @core.session_label(
                    @platform.read_prefix(session_path, 64 * 1024),
                  ) ==
                  ""
                let ctx = @agent.AgentContext::new(
                  session~,
                  session_path~,
                  cwd~,
                  api_key=key,
                  system_prompt=@core.build_system_prompt(cwd, tools),
                  tools~,
                  model=args.model,
                )
                // A failed turn must not take the process down: the session is on
                // disk, and the reader needs to see what happened rather than a
                // dead page.
                try
                  run_and_report(hub, ctx, text, index, aborting, text => {
                    status_line = text
                  })
                catch {
                  err => {
                    hub.broadcast(
                      @html.Patch::Status(text="failed: \{err}").to_sse(),
                    )
                    log("turn failed: \{err}")
                  }
                } noraise {
                  result => session = result.session
                }
                if relabel {
                  hub.broadcast(
                    @html.Patch::Replace(target="sessions", html=sessions()).to_sse(),
                  )
                }
                busy = false
              }
            }
          } catch {
            err => {
              log("job failed: \{err}")
              hub.broadcast(@html.Patch::Status(text="failed: \{err}").to_sse())
            }
          } noraise {
            _ => ()
          }
        }
      }),
    )
    // A port already taken is the one startup failure worth naming: it is what
    // running a second instance looks like. Converted rather than logged, so a
    // single writer produces the message — a log line racing the runtime's own
    // error output garbles both.
    try @server.serve(args.port, hub, routes) catch {
      err =>
        raise Failure::Failure(
          "cannot listen on 127.0.0.1:\{args.port} (\{err}). Another instance may be running; pass --port to choose another.",
        )
    } noraise {
      _ => ()
    }
  })
}

///|
/// Enqueue without blocking, reporting whether it worked.
///
/// The queue is unbounded and never closed, so this cannot fail in practice; the
/// wrapper exists so the call site does not have to say so.
fn queue_try_put(jobs : @aqueue.Queue[Job], job : Job) -> Bool {
  try jobs.try_put(job) catch {
    _ => false
  } noraise {
    queued => queued
  }
}
