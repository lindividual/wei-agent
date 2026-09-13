///|
/// The web UI: an agent, its sessions, and an HTTP server, in one process and one
/// binary.
///
/// The server is the only writer of the document. The browser applies patches and posts
/// prompts; it holds no model of the conversation, so there is nothing for it and the
/// server to disagree about.
///
/// ## Sessions run in parallel, one is displayed
///
/// Every open session owns its turn slot. Two sessions can therefore be working at the
/// same time, and switching which one is displayed interrupts nothing — the reader looks
/// at one conversation while another keeps going, which is the point of having several.
///
/// Within one session turns are serialized, and that is not a nicety: two turns sharing
/// a session interleave their writes into one file and fork its history. The first
/// version of this UI did exactly that, and the log it produced had entries with a parent
/// that no longer existed.
///
/// Patches are tagged with the session they belong to, so a browser showing one
/// conversation never receives another one's output.

///|
/// A one-way flag a running turn polls.
struct AbortFlag {
  mut value : Bool
}

///|
/// One queued change to what is displayed.
enum Job {
  /// Display this session, loading it if it is not open yet.
  Switch(String)
  /// Start a new session in this working directory, and display it.
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
/// Open the session the command line asked for, creating one when needed.
///
/// Resuming is where the format work pays off: the file was written by whatever ran last
/// — this process, an older build, or pi itself — and it is read back through the same
/// parser the round-trip verifier exercises.
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

// ── One open session ───────────────────────────────────────────────────────

///|
/// What the composer understands as a command rather than a message.
pub(all) enum Command {
  /// `/name <text>` sets the session's name; `/name` alone reports the current one.
  Name(String)
} derive(Eq, Debug)

///|
/// Read a command out of what the reader typed, or `None` for a message.
///
/// Only `/name` is intercepted. Treating every `/x` as a command would silently swallow messages
/// that happen to start with a slash — a path, a division, a regex — so an unknown one is left
/// alone and goes to the model.
pub fn parse_command(text : String) -> Command? {
  let trimmed = text.trim()
  if trimmed == "/name" {
    // Without an argument it reports rather than clears: a bare command should not be able to
    // throw away something the reader typed earlier.
    return Some(Name(""))
  }
  if trimmed.has_prefix("/name ") {
    return Some(Name(trimmed[6:].trim().to_owned()))
  }
  None
}

///|
/// A session, and whatever it is doing.
///
/// The turn slot lives here rather than behind one global queue: sessions are independent
/// of each other, and only turns *within* a session have to be ordered.
struct Runner {
  /// The session as it stands. Replaced after each turn with the driver's copy, which
  /// is the one that has the new entries in it.
  mut session : @core.Session
  path : String
  /// Which directory this session's tools run in. A property of the session, not of the
  /// process: opening a session moved the agent to where that session lived.
  cwd : String
  /// One turn at a time per session.
  turns : @async.Mutex
  /// Prompts waiting for this session's turn slot.
  mut waiting : Int
  mut busy : Bool
  aborting : AbortFlag
  /// What the running turn is doing, for the tasks panel.
  mut phase : String
  /// When the running turn started, for the tasks panel's elapsed time.
  mut since : Int64
  /// The tool that is running, so a stop can reach its process.
  mut tool : @agent.ToolHandle?
  /// Bumped by a stop. A queued prompt captured the epoch when it was accepted, so a stop
  /// drops everything that had not started yet — the reader who stops a session means the
  /// session, not just the turn that happened to be running.
  mut epoch : Int
  /// Turns started, which is what the exchange anchors are numbered by.
  mut turn : Int
  /// Output of the running turn as it has arrived. Kept so a browser that switches back
  /// mid-turn sees the work rather than an empty exchange.
  mut live : Array[@html.LivePiece]
  /// What the running turn was asked. The in-memory session is only updated when a turn
  /// ends, so this is the only record of the question while the answer is being written.
  mut prompt : String
  /// The line this session shows on the status bar while it is displayed.
  mut status : String
}

///|
fn Runner::new(session : @core.Session, path : String) -> Runner {
  let cwd = session.header.cwd
  let status = if session.entries.length() == 0 {
    "new session in \{cwd}"
  } else {
    "opened \{session.context().messages.length()} messages in \{cwd}"
  }
  {
    session,
    path,
    cwd,
    turns: @async.Mutex(),
    waiting: 0,
    busy: false,
    aborting: { value: false, },
    phase: "",
    since: 0L,
    tool: None,
    epoch: 0,
    turn: 0,
    live: [],
    prompt: "",
    status,
  }
}

///|
/// What the bar calls this session.
fn Runner::name_or_id(self : Runner) -> String {
  match self.session.name() {
    Some(name) => name
    None => short_id(self.path)
  }
}

///|
/// Whether this session has work in flight.
fn Runner::is_running(self : Runner) -> Bool {
  self.busy || self.waiting > 0
}

///|
/// Everything the requests need, in one place.
struct App {
  root : String
  model : String
  /// The model's context window, from the same catalog as the pricing: the number that turns
  /// "the conversation is 24k tokens" into "and that is 2% of what it can hold".
  context_window : Int
  api_key : String
  tools : Array[@core.ToolDef]
  hub : @server.Hub
  /// Open sessions, in the order they were opened.
  registry : Array[Runner]
  /// Background work, across every session. One store rather than one per session: the question
  /// "what is still running" is asked about the process, and a reader should not have to open
  /// five sessions to answer it.
  jobs : @core.JobStore
  /// Labels already read, so redrawing the sidebar does not re-read every session head.
  labels : LabelCache
  /// Pids that existed at the last look, so the job panel can show the processes that are still
  /// there instead of every pid a command was ever seen with. Refreshed with the panel, not inside
  /// it: rendering is pure.
  mut live_pids : Array[Int]
  /// The path of the session being displayed. Shared by every browser: there is one
  /// document, so there is one answer to "what is on screen".
  mut displayed : String
}

///|
fn App::running(self : App, path : String) -> Bool {
  for runner in self.registry {
    if runner.path == path {
      return runner.is_running()
    }
  }
  false
}

///|
fn App::runner(self : App, path : String) -> Runner? {
  for runner in self.registry {
    if runner.path == path {
      return Some(runner)
    }
  }
  None
}

///|
/// The session on screen.
///
/// Total rather than raising: `displayed` is only ever set from the registry and the
/// registry is never emptied, so the fallback is unreachable — and making every caller
/// handle an error that cannot happen would bury the interesting ones.
fn App::shown(self : App) -> Runner {
  match self.runner(self.displayed) {
    Some(runner) => runner
    None => self.registry[0]
  }
}

///|
/// Open a session if it is not open, and display it.
fn App::display(self : App, runner : Runner) -> Unit {
  match self.runner(runner.path) {
    None => self.registry.push(runner)
    Some(_) => ()
  }
  self.displayed = runner.path
}

///|
/// Ask a session to stop: the turn that is running, the command it is running, and the
/// prompts that have not started.
///
/// All three, because they are one intention. Setting the flag alone would leave the reader
/// waiting for a `sleep 300` to finish; dropping the queue is what makes "stop" mean the
/// session rather than the one turn that happened to be in flight.
fn Runner::stop(self : Runner) -> Unit {
  self.aborting.value = true
  self.epoch += 1
  match self.tool {
    Some(running) => (running.stop)()
    None => ()
  }
}

///|
/// How many other sessions are working right now.
fn App::others_running(self : App, shown : Runner) -> Int {
  let mut count = 0
  for runner in self.registry {
    if runner.path != shown.path && runner.is_running() {
      count += 1
    }
  }
  count
}

///|
/// A status line for one session: its own state, plus a note when work is happening
/// somewhere the reader cannot see. Otherwise a background turn is invisible, which is the
/// problem this whole design exists to avoid.
///
/// Used both for the snapshot and for the live patches, so the note cannot be present in
/// one and missing from the other.
fn App::label_for(self : App, runner : Runner, label : String) -> String {
  let others = self.others_running(runner)
  if others == 0 {
    label
  } else {
    "\{label} · \{others} other session(s) running"
  }
}

///|
/// The status line the page shows.
fn App::status_line(self : App, shown : Runner) -> String {
  self.label_for(shown, shown.status)
}

// ── The sidebar's view ─────────────────────────────────────────────────────

///|
/// What the sidebar needs to know about a session: what to call it, and what the reader called it.
pub(all) struct SessionFacts {
  /// The first thing the user asked, for sessions nobody has named.
  label : String
  /// The reader's own name for it, when they gave one.
  name : String?
} derive(Eq, Debug)

///|
/// Facts already worked out, keyed by session path.
///
/// They only change when the file does, and `list_sessions` already reports when that was — so a
/// lookup needs no syscall at all. It exists because the sidebar is rebuilt twice per turn (the
/// running mark changes) and reading every session's head to redraw it made that cost grow with the
/// store: 20 workspaces of 10 sessions came to 12MB read per refresh.
///
/// The name lives at the *end* of a log and the label at the beginning, so a miss reads the whole
/// file rather than a prefix. That is the honest way to find the newest `session_info` without an
/// index that could disagree with the log — and it is paid once per change, not once per refresh.
/// If a store of very many large sessions makes that visible, the fix is an index beside the store,
/// not a smaller read that gives wrong answers.
pub(all) struct LabelCache {
  mut entries : Map[String, (Int64, SessionFacts)]
}

///|
pub fn LabelCache::new() -> LabelCache {
  { entries: Map([]), }
}

///|
fn LabelCache::hit(
  self : LabelCache,
  path : String,
  modified : Int64,
) -> SessionFacts? {
  match self.entries.get(path) {
    Some((cached_at, facts)) =>
      if cached_at == modified {
        Some(facts)
      } else {
        None
      }
    None => None
  }
}

///|
fn LabelCache::store(
  self : LabelCache,
  path : String,
  modified : Int64,
  facts : SessionFacts,
) -> Unit {
  self.entries.set(path, (modified, facts))
}

///|
async fn LabelCache::label(
  self : LabelCache,
  path : String,
  modified : Int64,
) -> SessionFacts {
  match self.hit(path, modified) {
    Some(facts) => return facts
    None => ()
  }
  let text = @platform.read_text(path)
  let facts : SessionFacts = {
    // The first user message is near the top of the file, so the label only needs the beginning.
    label: @core.session_label(prefix_of(text, 16 * 1024)),
    name: session_name_of(text),
  }
  self.store(path, modified, facts)
  facts
}

///|
fn prefix_of(text : String, limit : Int) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned()
  }
}

///|
/// The name a session was given, read from its log.
///
/// The name lives at the end of a log and the label at the beginning, so finding it means reading
/// the whole file — once per change, since the result is cached. Parsing goes through the same entry
/// decoder as everything else, so a name written by pi is read here too; pattern-matching the JSON
/// would stop working the day a field moves.
///
/// If a store of very many large sessions ever makes that visible, the fix is an index beside the
/// store rather than a smaller read that gives wrong answers.
fn session_name_of(text : String) -> String? {
  let session = try @core.parse_session_file(text) catch {
    // A file being written while we read it may not parse. `None` is the right answer: the next
    // refresh reads it again.
    _ => return None
  } noraise {
    parsed => parsed
  }
  session.name()
}

///|
/// The sidebar's view of the store: every workspace that has sessions, newest first,
/// each described from the top of its newest file.
///
/// Bounded per file and per workspace on purpose. Describing a workspace means reading
/// one header, and a sidebar that read every session in full would make opening the UI
/// cost as much as replaying all of them.
async fn workspace_items(
  app : App,
  shown : Runner,
) -> Array[@html.WorkspaceItem] {
  let out : Array[@html.WorkspaceItem] = []
  for stored in @platform.list_workspaces(app.root, sidebar_sessions()) {
    let sessions : Array[@html.SessionItem] = []
    for session in stored.sessions {
      let facts = app.labels.label(session.path, session.modified)
      sessions.push({
        path: session.path,
        // The reader's own name wins, because that is what a name is for.
        label: match facts.name {
          Some(name) => name
          None =>
            // Failing a name, the first question — except for a session whose first turn is still
            // running, where the file has no label yet and "empty session" would be wrong for the
            // five minutes a long turn takes. The running turn is what we do know.
            if facts.label == "" {
              match app.runner(session.path) {
                Some(runner) => @html.clip_label(runner.prompt)
                None => ""
              }
            } else {
              facts.label
            }
        },
        modified: session.modified,
        current: session.path == shown.path,
        running: app.running(session.path),
      })
    }
    out.push({
      cwd: stored.cwd,
      name: workspace_name(stored.cwd),
      title: stored.title,
      active: stored.cwd == shown.cwd,
      sessions,
      hidden: stored.total - sessions.length(),
    })
  }
  // A session that has not been written yet is not in the store, and neither is its
  // workspace: a store knows nothing about a conversation until there is one. Showing the
  // workspace anyway keeps the reader oriented, and it keeps "+ new session" reachable —
  // in an empty store that button would otherwise not exist at all, which is the state
  // the very first prompt has to be typed into.
  let mut listed = false
  for item in out {
    if item.cwd == shown.cwd {
      listed = true
    }
  }
  if !listed {
    out.insert(0, {
      cwd: shown.cwd,
      name: workspace_name(shown.cwd),
      title: None,
      active: true,
      sessions: [
        {
          path: shown.path,
          label: "",
          modified: @env.now().reinterpret_as_int64(),
          current: true,
          running: shown.is_running(),
        },
      ],
      hidden: 0,
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

// ── Status text ────────────────────────────────────────────────────────────

///|
fn status_text(result : @agent.TurnResult, aborted : Bool) -> String {
  let out = StringBuilder()
  if aborted {
    out.write_string("stopped after \{result.model_calls} model calls")
  } else if !result.settled {
    // The model kept asking for tools until the limit. Said plainly, because the reader
    // is the one who has to decide what to do about it.
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
/// millicent, and rounding to cents would print every turn as $0.00. Below a tenth of a
/// dollar the extra digits are the information.
fn format_cost(value : Double) -> String {
  let decimals = if value < 0.1 { 6 } else { 4 }
  let scale = if decimals == 6 { 1000000.0 } else { 10000.0 }
  let scaled = (value * scale).round().to_int()
  let text = "\{scaled}"
  // Digits include the ones before the point, so a session that has cost a dollar is not printed
  // as a tenth of one. The point goes in `decimals` from the right whatever the magnitude.
  let padded = if text.length() >= decimals + 1 {
    text
  } else {
    zeroes(decimals + 1 - text.length()) + text
  }
  let cut = padded.length() - decimals
  padded[:cut].to_owned() + "." + padded[cut:].to_owned()
}

///|
fn zeroes(count : Int) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_char('0')
  }
  out.to_string()
}

// ── Running a turn ─────────────────────────────────────────────────────────

///|
/// Add a delta to the session's live view.
///
/// The live view is a mirror of what the browser is being sent, kept so that a browser
/// which connects (or switches back) later can be given the same picture. Text and
/// reasoning accumulate into one piece per block, keyed by the same element id the live
/// patches use — which is what lets the snapshot and the stream agree about where the
/// next delta goes.
fn Runner::trace(self : Runner, piece : @html.LivePiece) -> Unit {
  let key = match piece {
    @html.Text(id~, ..) => id
    @html.Thinking(id~, ..) => id
    @html.Tool(id~, ..) => id
  }
  for i in 0..<self.live.length() {
    let same = match self.live[i] {
      @html.Text(id~, ..) => id == key
      @html.Thinking(id~, ..) => id == key
      @html.Tool(id~, ..) => id == key
    }
    if same {
      // A delta for a block that is already there: replace it, since the live patches
      // carry the whole text rather than an increment.
      self.live[i] = piece
      return
    }
  }
  self.live.push(piece)
}

///|
/// Run one turn in this session, showing it to whoever is watching this session.
///
/// The caller holds the session's turn slot, so everything here can assume nothing else
/// is writing to this session's log.
async fn run_prompt(app : App, runner : Runner, text : String) -> Unit {
  runner.turns.acquire()
  defer runner.turns.release()
  runner.waiting -= 1
  let my_epoch = runner.epoch
  // A queued prompt that a stop has already answered does not run at all.
  if runner.waiting < 0 {
    runner.waiting = 0
  }
  if runner.aborting.value && my_epoch != runner.epoch {
    runner.turns.release()
    return
  }
  runner.busy = true
  runner.aborting.value = false
  runner.phase = "waiting for the model"
  runner.since = @env.now().reinterpret_as_int64()
  runner.turn += 1
  runner.live = []
  runner.prompt = text
  let index = runner.turn
  // The tag a client compares against is the session's short id, not its path: 80 bytes of path
  // on every frame of a stream is the largest single cost in the envelope.
  let session = short_id(runner.path)
  // The sidebar marks a session as running while it is, which is how work in a session
  // nobody is looking at stays visible.
  let refresh_sidebar = async fn() {
    match app.runner(app.displayed) {
      Some(visible) => {
        let html = workspace_items_and_render(app, visible)
        app.hub.broadcast(
          @html.Patch::Replace(target="sessions", html~).to_sse(),
        )
        // A turn starting or ending changes what the *displayed* session's line should
        // say, even when it is a different one that started: that is the difference
        // between "idle" and "1 other session running".
        app.hub.broadcast(
          @html.Patch::Status(text=app.label_for(visible, visible.status)).to_scoped_sse(
            visible.path,
          ),
        )
      }
      None => ()
    }
  }
  // The tasks panel is refreshed when the phase changes, not on a timer: the elapsed time in
  // it is counted by the browser, so a second-by-second frame would be paying for a number
  // the page can work out itself.
  let refresh_tasks = async fn() {
    app.hub.broadcast(
      @html.Patch::Replace(target="tasks", html=render_tasks(app, app.shown())).to_sse(),
    )
  }
  let status = async fn(label : String) {
    runner.status = label
    // Only the reader who is looking at this session needs its progress; the sidebar
    // refresh is what tells everyone else that work is happening.
    app.hub.broadcast(
      @html.Patch::Status(text=app.label_for(runner, label)).to_scoped_sse(
        session,
      ),
    )
  }
  // The background panel changes when a command outlives its tool call, which is a turn event;
  // the supervisor task covers the other direction, a process exiting on its own.
  let refresh_jobs = async fn() {
    refresh_live_pids(app)
    app.hub.broadcast(
      @html.Patch::Replace(
        target="jobs",
        html=render_jobs(app, @env.now().reinterpret_as_int64()),
      ).to_sse(),
    )
  }
  // The bar's figures are per session and come from the log, so they are recomputed when a
  // turn changes them rather than on every frame.
  let refresh_bar = async fn() {
    app.hub.broadcast(
      @html.Patch::Replace(
        target="bar",
        html=bar_node(app, app.shown()).render(),
      ).to_sse(),
    )
  }
  status("working…")
  refresh_sidebar()
  refresh_tasks()
  refresh_bar()
  refresh_jobs()

  // The reader's message appears at once, then a throwaway container everything the
  // model produces lands in. When the turn ends the container is replaced by the
  // properly rendered reply — reasoning collapsed, tool calls paired, markdown parsed —
  // so the streaming path never has to decide what the final markup looks like.
  app.hub.broadcast(
    @html.append_node(
      "transcript",
      @html.render_exchange_start(index, Some(text)),
    ).to_scoped_sse(session),
  )
  let stream_root = "streams-\{index}"
  app.hub.broadcast(
    @html.append_node(
      @html.blocks_id(index),
      @html.el("div", attrs=[@html.attr("id", stream_root)], children=[]),
    ).to_scoped_sse(session),
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
            app.hub.broadcast(
              @html.append_node(
                stream_root,
                @html.el(
                  "div",
                  attrs=[@html.cls("text"), @html.attr("id", id)],
                  children=[],
                ),
              ).to_scoped_sse(session),
            )
            // Small enough that the reader sees the first characters almost immediately, large
            // enough that a frame's envelope is not most of what it carries.
            let fresh = @html.StreamBuffer::new(id, threshold=24)
            open_text = Some(fresh)
            fresh
          }
        }
        match buffer.push(delta) {
          Some(patch) => app.hub.broadcast(patch.to_scoped_sse(session))
          None => ()
        }
        runner.trace(@html.Text(id=buffer.id, text=buffer.text))
      }
      @core.Thinking(delta~) => {
        // Reasoning is streamed too, into a collapsed container. Not streaming it was a
        // mistake: with a model that thinks before every tool call, the page then showed
        // nothing at all for minutes, which reads as a hang.
        let buffer = match open_thinking {
          Some(existing) => existing
          None => {
            stream_seq += 1
            let id = "thinking-\{index}-\{stream_seq}"
            app.hub.broadcast(
              @html.append_node(
                stream_root,
                @html.render_thinking_stream(id, "\{id}-body"),
              ).to_scoped_sse(session),
            )
            // Much larger than text: reasoning is collapsed, so a frame buys only the sense that
            // something is happening — and a thinking-heavy model sends a lot of it.
            let fresh = @html.StreamBuffer::new("\{id}-body", threshold=256)
            open_thinking = Some(fresh)
            fresh
          }
        }
        match buffer.push(delta) {
          Some(patch) => app.hub.broadcast(patch.to_scoped_sse(session))
          None => ()
        }
        runner.trace(
          @html.Thinking(id=strip_body_suffix(buffer.id), text=buffer.text),
        )
      }
    }
  }

  // Each finished tool is shown where it happened, so a long turn reads as work being
  // done rather than as silence.
  let mut tool_seq = 0
  let on_tool = (event : @agent.ToolEvent) => {
    tool_seq += 1
    let id = "live-tool-\{index}-\{tool_seq}"
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
    app.hub.broadcast(
      @html.append_node(stream_root, @html.render_tool(id, call, Some(result))).to_scoped_sse(
        session,
      ),
    )
    runner.trace(@html.Tool(id~, call~, result~))
  }

  // The counts are the cheapest possible "still alive" signal, and the one a reader
  // watches when a turn is taking minutes.
  let on_progress = (calls : Int, tools : Int) => {
    status("working… \{calls} model call(s), \{tools} tool call(s)")
  }

  let ctx = @agent.AgentContext::new(
    session=runner.session,
    session_path=runner.path,
    cwd=runner.cwd,
    api_key=app.api_key,
    system_prompt=@core.build_system_prompt(runner.cwd, app.tools),
    tools=app.tools,
    model=app.model,
    jobs=app.jobs,
  )
  // A failed turn must not take the process down, and must not leave the session marked
  // as busy: the log is on disk, and the reader needs to see what happened.
  try {
    let result = @agent.run_turn(
      ctx,
      text,
      @env.now().reinterpret_as_int64(),
      thinking_level="high",
      on_delta=report,
      should_stop=() => runner.aborting.value,
      on_tool~,
      on_progress~,
      on_tool_process=handle => {
        runner.phase = match handle {
          Some(running) => "running \{running.name}: \{running.detail}"
          None => "waiting for the model"
        }
        runner.tool = handle
        refresh_tasks()
      },
    )
    runner.session = result.session
    app.hub.broadcast(
      @html.replace_node(
        @html.blocks_id(index),
        @html.el(
          "div",
          attrs=[cls_blocks(), @html.attr("id", @html.blocks_id(index))],
          children=[
            @html.render_reply(
              index,
              0,
              @html.reply_pieces(result.session.context().messages),
            ),
          ],
        ),
      ).to_scoped_sse(session),
    )
    status(status_text(result, runner.aborting.value))
  } catch {
    err => {
      log("turn failed: \{err}")
      status("failed: \{err}")
    }
  } noraise {
    _ => ()
  }
  runner.live = []
  runner.prompt = ""
  runner.phase = ""
  runner.tool = None
  runner.busy = false
  refresh_sidebar()
  refresh_tasks()
  refresh_bar()
  refresh_jobs()
}

///|
/// The blocks container's class attribute, which the replacement has to keep.
fn cls_blocks() -> @html.Attr {
  @html.cls("blocks")
}

///|
/// Undo the `-body` suffix a reasoning buffer carries, so the live view can key the piece
/// by the id of the element the *container* has.
fn strip_body_suffix(id : String) -> String {
  if id.has_suffix("-body") {
    id[:id.length() - 5].to_owned()
  } else {
    id
  }
}

///|
/// The sidebar as HTML, for the session being displayed.
async fn workspace_items_and_render(app : App, shown : Runner) -> String {
  let now = @env.now().reinterpret_as_int64()
  let items = workspace_items(app, shown)
  @html.render_sessions(items, now).render()
}

// ── The page ───────────────────────────────────────────────────────────────

///|
/// Take the process table the job panel filters against.
async fn refresh_live_pids(app : App) -> Unit {
  let pids : Array[Int] = []
  for entry in @platform.process_table() {
    pids.push(entry.0)
  }
  app.live_pids = pids
}

///|
/// Whether a pid is one the reader would find if they looked now.
fn App::still_running(self : App, pid : Int) -> Bool {
  for live in self.live_pids {
    if live == pid {
      return true
    }
  }
  false
}

///|
/// The background panel, as HTML: every job, live ones first.
fn render_jobs(app : App, now : Int64) -> String {
  let items : Array[@html.JobItem] = []
  for job in app.jobs.list() {
    // Every pid ever seen, minus the ones that are gone: a command is recorded with its own shell
    // and with the `ps` helper that reported it, and neither is what the reader is looking for.
    let pids : Array[Int] = []
    for pid in job.pids {
      if app.still_running(pid) {
        pids.push(pid)
      }
    }
    items.push({
      id: job.id,
      label: job.label,
      kind: job.kind,
      status: job.status.to_string(),
      age_ms: job.age_ms(now),
      pids,
      live: job.is_live(),
      detail: job.detail,
    })
  }
  @html.render_jobs(items, now).render()
}

///|
/// The tasks panel, as HTML. Empty when nothing is running.
fn render_tasks(app : App, _shown : Runner) -> String {
  let items : Array[@html.TaskItem] = []
  for runner in app.registry {
    if runner.is_running() {
      items.push({
        path: runner.path,
        label: @html.clip_label(runner.prompt),
        session: short_id(runner.path),
        phase: runner.phase,
        since: runner.since,
        queued: runner.waiting,
      })
    }
  }
  @html.render_tasks(items).render()
}

///|
/// What is open: the session, the model, and — once the turn reporting fills them in — the
/// token and cost figures for it.
fn bar_node(app : App, shown : Runner) -> @html.Node {
  @html.render_bar(
    [
      // No workspace chip: the sidebar already marks which one is active, and repeating it cost
      // the width that kept the figures on the same line.
      // The id rather than the file name: the timestamp in the name is noise in a bar that is
      // read at a glance, and the full path is one hover away.
      // A name if the reader gave one; otherwise the id, which is at least short and matches the
      // file on disk.
      @html.chip("session", shown.name_or_id(), detail=shown.path),
      @html.chip(
        "model",
        app.model,
        detail="\{workspace_name(shown.cwd)} · \{shown.cwd}",
      ),
    ],
    right=usage_chips(app, shown),
  )
}

///|
/// What the session has used and spent, and how full its context is.
///
/// The totals come from the log (`Session::usage`), so they are the same after a restart as
/// before one. The context figure is the one that changes what happens next: it is compared
/// against the point where compaction would kick in, and marked when that is close.
fn usage_chips(app : App, shown : Runner) -> Array[@html.Node] {
  let usage = shown.session.usage()
  let window = app.context_window
  let context = @core.estimate_context_tokens(
    shown.session.prepared_context().messages,
  )
  let compact_soon = @core.should_compact(
    context,
    window,
    reserve_tokens=@core.CompactionSettings::for_window(window).reserve_tokens,
  )
  let tokens_detail = "input \{usage.input} · output \{usage.output}" +
    (if usage.reasoning > 0 { " · reasoning \{usage.reasoning}" } else { "" }) +
    " · over \{usage.replies} reply/ies"
  let cache_detail = "read \{usage.cache_read} · written \{usage.cache_write}" +
    " · a cache read is billed at a fraction of fresh input"
  let cost_detail = "input $\{format_cost(usage.cost.input)}" +
    " · output $\{format_cost(usage.cost.output)}" +
    " · cache read $\{format_cost(usage.cost.cache_read)}" +
    " · total $\{format_cost(usage.cost.total)}"
  [
    @html.chip(
      "tokens",
      "\{@html.compact_number(usage.input)} in / \{@html.compact_number(usage.output)} out",
      detail=tokens_detail,
    ),
    @html.chip(
      "cache",
      @html.compact_number(usage.cache_read),
      detail=cache_detail,
    ),
    @html.chip("cost", "$\{format_cost(usage.cost.total)}", detail=cost_detail),
    @html.chip_meter(
      "context",
      "\{@html.compact_number(context)} / \{@html.compact_number(window)}",
      context.to_double() / window.to_double(),
      warn=compact_soon,
      detail=if compact_soon {
        "compaction will summarize the older half of this conversation on the next turn"
      } else {
        "estimated from the messages the next request would send"
      },
    ),
  ]
}

///|
/// The id part of a session file name: `…_ab12cd34.jsonl` becomes `ab12cd34`.
fn short_id(path : String) -> String {
  let name = match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
  let stem = if name.has_suffix(".jsonl") {
    name[:name.length() - 6].to_owned()
  } else {
    name
  }
  match stem.rev_find("_") {
    Some(index) => stem[index + 1:].to_owned()
    None => stem
  }
}

///|
/// The whole conversation as it stands, including a turn that is still running.
fn transcript_node(app : App, shown : Runner) -> @html.Node {
  let extra : Array[@html.Node] = []
  if shown.busy {
    // A reader who switches back to a running turn should see its work rather than an
    // empty exchange — including before the first delta arrives, since the question is
    // not in the committed conversation yet either. The container carries the ids the
    // live patches target, so the output keeps arriving into the same nodes.
    let running = @html.render_running_exchange(
      shown.turn,
      shown.prompt,
      shown.live,
    )
    extra.push(running)
  }
  ignore(app)
  @html.render_transcript(
    shown.session.context().messages,
    // The same tag the scoped frames carry: the browser compares them, so they have to agree.
    session=short_id(shown.path),
    extra~,
  )
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
  // Header-only sessions accumulate from every start that never got used. Ten minutes is
  // long enough that a session another instance is writing right now is safe.
  let pruned = @platform.prune_empty_sessions(
    @core.session_dir_for(root, cwd),
    10L * 60L * 1000L,
  )
  if pruned > 0 {
    log("pruned   \{pruned} empty session(s)")
  }
  let opened = open_session(args, root, cwd)
  let first = Runner::new(opened.0, opened.1)
  let app : App = {
    root,
    model: args.model,
    context_window: @core.deepseek_v4_flash_context_window(),
    api_key: key,
    tools: @core.builtin_tools(),
    hub: @server.Hub::new(),
    registry: [first],
    jobs: @core.JobStore::new(),
    labels: LabelCache::new(),
    live_pids: [],
    displayed: first.path,
  }
  // Display changes go through a queue so that the order they arrive in is the order they
  // happen in: two clicks in quick succession must not leave the page showing the first
  // one. Turns do not go through it — they run in their own session's slot, in parallel.
  let jobs : @aqueue.Queue[Job] = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)

  let regions = async fn() {
    let shown = app.shown()
    let sidebar = workspace_items_and_render(app, shown)
    [
      @html.Patch::Replace(
        target="transcript",
        html=transcript_node(app, shown).render(),
      ),
      @html.Patch::Replace(target="sessions", html=sidebar),
      @html.Patch::Replace(target="tasks", html=render_tasks(app, shown)),
      @html.Patch::Replace(
        target="jobs",
        html=render_jobs(app, @env.now().reinterpret_as_int64()),
      ),
      @html.Patch::Replace(target="bar", html=bar_node(app, shown).render()),
      @html.Patch::Status(text=app.status_line(shown)),
    ]
  }

  log("pi-mb   http://127.0.0.1:\{args.port}")
  log("model   \{args.model}")
  log("cwd     \{cwd}")
  log("session \{first.path}")
  log("store   \{root}")

  @async.with_task_group(group => {
    let routes : @server.Routes = {
      page: async fn() {
        let shown = app.shown()
        // The sidebar holds two regions with different reasons to change: what is running, and
        // what exists.
        let sidebar = @html.render_sidebar([
          @html.raw(render_tasks(app, shown)),
          @html.raw(render_jobs(app, @env.now().reinterpret_as_int64())),
          @html.raw(workspace_items_and_render(app, shown)),
        ])
        let column = @html.el("div", attrs=[@html.cls("column")], children=[
          bar_node(app, shown),
          transcript_node(app, shown),
          @html.render_status(app.status_line(shown)),
          @html.composer(),
        ])
        let body = @html.el("div", attrs=[@html.cls("layout")], children=[
          sidebar, column,
        ])
        @html.render_page("pi", @html.stylesheet(), client_script(), [body]).render()
      },
      regions,
      prompt: async fn(text) {
        match parse_command(text) {
          Some(Name(value)) => {
            let shown = app.shown()
            if shown.is_running() {
              // Two writers on one log is the corruption this whole design avoids: the turn is
              // appending entries whose parent is its own leaf, and a rename appended now would
              // hang off a stale one and end up on a branch nobody walks.
              shown.status = "cannot rename while a turn is running"
              app.hub.broadcast(@html.Patch::Status(text=shown.status).to_sse())
            } else if value == "" {
              // A bare command reports rather than clears: it should not be able to throw away
              // something the reader typed earlier.
              shown.status = match shown.session.name() {
                Some(name) => "name: \{name}"
                None => "this session has no name (use /name <text>)"
              }
              app.hub.broadcast(@html.Patch::Status(text=shown.status).to_sse())
            } else {
              let entry = @core.session_name_entry(
                Some(value),
                shown.session.leaf_id,
                @env.now().reinterpret_as_int64(),
              )
              @platform.append_entry(shown.path, entry)
              shown.session = shown.session.add_entries([entry])
              shown.status = "named \{value}"
              // The sidebar row and the bar chip both change, and both are regions.
              for patch in regions() {
                app.hub.broadcast(patch.to_sse())
              }
            }
            return
          }
          None => ()
        }
        let shown = app.shown()
        shown.waiting += 1
        if shown.busy {
          shown.status = "queued behind the running turn"
          app.hub.broadcast(
            @html.Patch::Status(text=shown.status).to_scoped_sse(shown.path),
          )
        }
        // A task per prompt, serialized by the session's own slot: another session's turn
        // is unaffected, which is the whole point.
        ignore(group.spawn(() => run_prompt(app, shown, text)))
      },
      abort: (path : String) => {
        // Empty means the session on screen, which is what the Stop button next to the
        // composer sends.
        let target = if path == "" {
          app.shown()
        } else {
          match app.runner(path) {
            Some(runner) => runner
            None => app.shown()
          }
        }
        target.stop()
        // The panel and the sidebar both change the moment a stop is asked for, rather than
        // when the turn finally notices.
        app.hub.broadcast(
          @html.Patch::Replace(
            target="tasks",
            html=render_tasks(app, app.shown()),
          ).to_sse(),
        )
      },
      switch_session: fn(path) { ignore(queue_try_put(jobs, Switch(path))) },
      new_session: fn(dir) { ignore(queue_try_put(jobs, New(dir))) },
      kill_job: async fn(id) {
        // Ask, then insist: the status shows "stopping" until the processes are actually gone,
        // which is what tells a reader whether a process is ignoring SIGTERM.
        let pids = app.jobs.request_stop(id)
        ignore(@platform.kill_pids(pids))
        app.jobs.finish(
          id,
          @core.JobStatus::Killed,
          detail="stopped from the panel",
          finished_at=@env.now().reinterpret_as_int64(),
        )
        app.hub.broadcast(
          @html.Patch::Replace(
            target="jobs",
            html=render_jobs(app, @env.now().reinterpret_as_int64()),
          ).to_sse(),
        )
      },
      add_workspace: async fn(path) {
        match @platform.canonical_dir(path) {
          None =>
            // Said on the status line rather than raised: the reader typed a path, and the useful
            // answer is which path was wrong.
            app.hub.broadcast(
              @html.Patch::Status(text="not a directory: \{path}").to_sse(),
            )
          Some(cwd) => {
            let dir = @core.session_dir_for(app.root, cwd)
            @platform.write_workspace(dir, { cwd, title: None, })
            ignore(queue_try_put(jobs, New(cwd)))
          }
        }
      },
    }

    // Jobs are watched, not polled by the reader: a process that exits on its own has to stop
    // being listed as running, and the exit code is worth seeing. One `kill -0` per recorded pid
    // every couple of seconds is the whole cost.
    ignore(
      group.spawn(() => {
        while true {
          @async.sleep(2000)
          // One process table for the whole tick rather than a `/bin/kill -0` per pid: the
          // question is the same for every job, and asking it per pid spawns a process per pid.
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
            app.hub.broadcast(
              @html.Patch::Replace(
                target="jobs",
                html=render_jobs(app, @env.now().reinterpret_as_int64()),
              ).to_sse(),
            )
          }
        }
      }),
    )
    ignore(
      group.spawn(() => {
        while true {
          let job = jobs.get()
          // Guarded: this runs in a task group whose other member is the server, so an
          // error escaping here would cancel the listener — one unreadable session file
          // would stop the process from serving anything, which looks exactly like a
          // frozen page.
          try {
            match job {
              Switch(path) =>
                if @platform.path_exists(path) {
                  // An already-open session is displayed as it is. Re-reading it from
                  // disk would throw away the state of a turn that may be running in it.
                  let runner = match app.runner(path) {
                    Some(existing) => existing
                    None => Runner::new(open_path(path), path)
                  }
                  app.display(runner)
                } else {
                  let (session, fresh) = create_session(
                    app.root,
                    shown_cwd(app),
                  )
                  app.display(Runner::new(session, fresh))
                }
              New(dir) => {
                let (session, path) = create_session(app.root, dir)
                app.display(Runner::new(session, path))
              }
            }
            // Nothing is stopped to get here: the session that was on screen keeps
            // running, in its own slot, out of sight.
            for patch in regions() {
              app.hub.broadcast(patch.to_sse())
            }
          } catch {
            err => {
              log("job failed: \{err}")
              app.hub.broadcast(
                @html.Patch::Status(text="failed: \{err}").to_sse(),
              )
            }
          } noraise {
            _ => ()
          }
        }
      }),
    )
    // A port already taken is the one startup failure worth naming: it is what running a
    // second instance looks like. Converted rather than logged, so a single writer
    // produces the message — a log line racing the runtime's own error output garbles
    // both.
    try @server.serve(args.port, app.hub, routes) catch {
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
/// The working directory of the session on screen, for a switch to a session that is gone.
fn shown_cwd(app : App) -> String {
  match app.runner(app.displayed) {
    Some(runner) => runner.cwd
    None => @platform.current_dir()
  }
}

///|
/// Enqueue without blocking, reporting whether it worked.
///
/// The queue is unbounded and never closed, so this cannot fail in practice; the wrapper
/// exists so the call site does not have to say so.
fn queue_try_put(jobs : @aqueue.Queue[Job], job : Job) -> Bool {
  try jobs.try_put(job) catch {
    _ => false
  } noraise {
    queued => queued
  }
}
