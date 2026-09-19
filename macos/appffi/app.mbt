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
/// One session the process has open: its log, where its tools run, which model it calls, and the turn
/// in flight here.
///
/// The reason this type exists is concurrency. The shell used to hold one session's state directly,
/// which made "two sessions running" impossible to express: the running turn wrote `self.session`,
/// `self.turn` and `self.busy`, so a second turn would have written over the first, and a switch
/// mid-turn was therefore refused. With the state per session, a turn writes *this* struct and is
/// indifferent to which one the window happens to be showing.
///
/// Everything shared between sessions — the settings, the endpoint, the job store, the key — stays on
/// `Shell`. What is here is what a conversation *is*, which is exactly what the web UI keeps in its
/// `Runner` for the same reason.
priv struct Open {
  /// The session as it stands. Replaced after each turn with the driver's copy, which is the one
  /// that has the new entries in it.
  mut session : @core.Session
  /// The file. The identity of this session, and the thing a switch compares.
  path : String
  cwd : String
  mut model_id : String
  /// How much thinking this session's next turn asks the model for.
  ///
  /// **Always a level `model_id` can run at.** The levels are per model (`ModelSpec::thinking_levels`)
  /// and this value travels with the session rather than with the model — a log records it, a fork
  /// copies it, a new session inherits the reader's last choice — so the two can disagree, and it is
  /// the level that has to give: the model is what the reader picked for the task. `Shell::retarget`
  /// and `Shell::set_think_level` are the only two writers, and each is what keeps that invariant:
  /// one re-settles the level when the model changes, the other refuses a level the model has not got.
  ///
  /// A field rather than read from the log at every turn, because the log is written by the driver and
  /// the reader can change this between turns, before any of it is recorded — the same reason `model_id`
  /// is here rather than looked up from the last assistant message.
  mut think_level : String
  /// How many turns have run in *this* session.
  ///
  /// Not a figure anybody reads: it is the number that makes a row's name unique. See `row_id` —
  /// which is why it is per session rather than per process. Two sessions both naming their first
  /// block `reply-1-1` is fine while only one of them is on screen, and the moment a replay of one
  /// can land in the other's transcript it is not.
  mut turn : Int
  /// Whether a turn is running *here*. Written by the turn and read by the command loop, which are
  /// the same thread — MoonBit's async is cooperative — so this needs no lock, only the discipline
  /// that the turn sets it before its first `await` and clears it after its last.
  mut busy : Bool
  /// One turn at a time *in this session*, for the reason the web UI has the same lock: two turns
  /// sharing a session interleave their writes into one file and fork its history — a fork this
  /// project has already produced once, and it left entries naming a parent that no longer existed.
  ///
  /// Per session rather than per process, which is the whole of this refactor: A and B are
  /// independent, and only turns within one of them have to be ordered.
  turns : @async.Mutex
  /// Whether this session's turn has been asked to stop.
  ///
  /// Read by the running turn, written by the command loop, which is why it is a `Ref`: the
  /// `should_stop` closure has to see the newest value rather than the one captured when the turn
  /// began. Per session, so that stopping one conversation does not stop another.
  aborting : Ref[Bool]
  /// Pictures waiting to go out with this session's next prompt, in the order they were attached.
  ///
  /// Per session, so that a screenshot attached for one question cannot arrive with another: two
  /// conversations are two things being written, and a draft belongs to the one it was written in.
  mut attached : Array[Attachment]
  /// This session's last turn's figures, and whether there has been one. Kept so that a window opened
  /// or a session switched mid-conversation can be told what the turn cost without waiting for the
  /// next one to end — the log knows the totals, but nothing in it says which of them were the last
  /// turn's.
  mut last_turn : LastTurn
  /// The tool this session's turn is running, and the way to stop it.
  ///
  /// **Kept because a stop has to reach the child process, and a flag cannot.** `aborting` is read by the
  /// turn between steps, and the step in progress *is* the tool: a `bash` command asked to run a test suite
  /// runs for minutes, and until this was kept, pressing Stop during one did nothing at all — the turn was
  /// marked, and the reader waited for a command they had already asked to end. The handle is the driver's
  /// own (it cancels the task the tool runs in, which is what escalates to killing the process), so this is
  /// where it has to be held for a command arriving from the host to reach it.
  ///
  /// Cleared when the tool reports, and when the turn ends, so a stale handle cannot stop something else.
  mut running_tool : @agent.ToolHandle?
  /// The rendering of the block that is still arriving here.
  ///
  /// Kept because it is the one thing that makes live markdown affordable: every frame after the
  /// first is a diff against what has already been sent, so the work is proportional to what is *new*
  /// rather than to the length of the answer. See `LiveMarkdown`.
  mut live : LiveMarkdown?
  /// The messages of this session's last request, so the next turn's first one can be measured
  /// against them.
  ///
  /// Kept because the seam between two turns is where the trim boundary most often moves — the turn
  /// just appended the messages that released it — and that first request is otherwise the one
  /// request per turn nothing compares to anything, which is how the most expensive rewrite in a
  /// session stayed invisible. Per session, like everything else here: two conversations in one
  /// process have two last requests, and comparing across them would be a figure about two
  /// conversations.
  ///
  /// Empty means "no previous request", which is the state a just-opened session is in.
  mut previous_request : Array[Json]
}

///|
/// One growing block, and what the host has been told about it so far.
///
/// The rules that make this correct are worth stating, because they are what the two fields are for:
///
/// - the shell sends the host **suffixes** of a block's parse, each naming the index it starts at.
///   `sent` is the shell's record of what those suffixes add up to, and `diff_prefix(sent, ...)` is
///   how the next suffix is found.
/// - the two sides therefore have to stay in step, which holds because the host keeps one transcript
///   per session and the shell replays a session's history only for a host that has never seen it —
///   and because nothing in the emit path drops a line. A `from` the host cannot apply is documented
///   as a no-op on its side rather than as corruption.
/// - `at_length` and `at_ms` are the two gates on how often a frame is worth sending at all. Both are
///   needed: characters alone let a slow model's *every* delta pay for a parse, and time alone lets a
///   fast one pile up a second of text and then send it all at once — which is a stall in the middle
///   of a stream, the one thing streaming exists to avoid.
priv struct LiveMarkdown {
  /// The row this belongs to. A frame for one block is never diffed against another's.
  id : String
  /// Every block sent for this row so far, in order.
  mut sent : Array[@md.Block]
  /// The block's length when the last frame went out.
  mut at_length : Int
  /// When the last frame went out.
  mut at_ms : UInt64
}

///|
/// How long a growing block waits between frames.
///
/// Measured against what it costs: parsing the tail of a block is tens of microseconds, and a frame a
/// pixel taller is what redraws the transcript. Six a second is under what a reader can see change,
/// and it is the same cadence the web UI's flush timer landed on for the same reason.
const LIVE_MARKDOWN_MS : UInt64 = 150

///|
/// How much new text makes a frame worth sending before the timer says so.
///
/// Without it, a model streaming one character at a time would still pay the parse on every delta
/// that passed the clock — which is the case this whole feature is *not* for: a reader watches a
/// block arrive a line at a time, not a character at a time.
const LIVE_MARKDOWN_CHARS : Int = 64

///|
/// Mark a session as no longer running a turn.
///
/// A function rather than an assignment because `defer` needs a *value*, and MoonBit has no assignment
/// expression. The flag is cleared on the way out of `run_turn` by every path including the one that
/// raises, which is what a `defer` is for.
fn clear_busy(open : Open) -> Unit {
  open.busy = false
}

///|
/// Forget the tool this session's turn was running.
///
/// A closure because `defer` needs a value, for the same reason `clear_busy` is one.
fn clear_running_tool(open : Open) -> Unit {
  open.running_tool = None
}

///|
/// Stop the command this session's turn is running, if there is one.
///
/// **The flag is not enough, and this is the whole of that.** `aborting` is read between steps, and the
/// step in progress is the tool — so a reader who pressed Stop during a two-minute test suite watched it
/// run to the end. Cancelling the task the tool runs in is what reaches the child process.
///
/// Taken rather than read, so that a second Stop — or one arriving after the tool has already reported —
/// is a no-op instead of cancelling whatever the turn started next.
fn stop_running_tool(open : Open) -> Unit {
  let running = open.running_tool
  open.running_tool = None
  match running {
    Some(handle) => (handle.stop)()
    None => ()
  }
}

///|
/// A session that has just been opened in this process, with nothing in it yet.
fn Open::new(
  path : String,
  cwd : String,
  model_id : String,
  think_level : String,
  session : @core.Session,
) -> Open {
  {
    session,
    path,
    cwd,
    model_id,
    think_level,
    turn: 0,
    busy: false,
    turns: @async.Mutex(),
    aborting: { val: false, },
    attached: [],
    last_turn: no_last_turn(),
    running_tool: None,
    live: None,
    previous_request: [],
  }
}

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
  /// The sessions the reader has pinned, as paths, in the order the file holds them.
  ///
  /// Held here rather than looked up per use because the list is the only reader and it is rebuilt
  /// many times a turn: a pin is answered from memory, and the file is written when one changes
  /// rather than when one is read. The pins are not an order on screen — see `core/pins.mbt` — so
  /// this array is passed to the list to be *tested against*, never drawn in its own order.
  mut pins : Array[String]
  /// Where sessions live. Kept on the shell rather than looked up per use, because the list, a new
  /// session and the switch that reads one all have to agree about it.
  root : String
  /// Where the per-turn diagnostic line goes, or empty for none. See `World::debug_log`.
  debug_log : String
  /// Every session this process has open, in the order they were opened.
  ///
  /// Open means "this process is holding its log and may have a turn running in it", not "it is on
  /// screen". A session stays open while the reader looks elsewhere — that is the whole point of the
  /// registry — and a session with a turn in flight is kept here whatever the window shows.
  opens : Array[Open]
  /// Which of them is on screen. Not an index: deleting a session removes it from the registry, and
  /// the window must not then be showing whatever slid into that slot.
  mut current : String
  /// What the sidebar's labels cost, cached across refreshes.
  labels : Labels
  /// Which pids were alive at the last look, refreshed on a timer.
  ///
  /// Cached because the question is asked from several places per tick — the panel, and settling a
  /// job whose process has gone — and reading the process table is the expensive part. The web UI
  /// caches it for the same reason and on the same cadence.
  mut live_pids : Array[Int]
  /// The jobs file as it was last written, so that a store nobody has changed is not rewritten every
  /// two seconds. The same trick `ui/panels.mbt` uses, for the same reason: a settings file that is
  /// touched on every tick is a file a backup tool never leaves alone.
  mut saved_jobs : String
  /// The last jobs event, so an unchanged panel is not redrawn — and the host is not woken — every
  /// two seconds.
  mut sent_jobs : String
  /// The skills discovered per working directory.
  ///
  /// Keyed by directory rather than held once, because it is a fact about a *project*: two sessions
  /// open in two repositories must each see their own project's skills. Cached because discovery
  /// reads the filesystem and walks a few roots, and the three things that need it — the settings
  /// panel, `/skill:<name>` expansion, and the list a bare `/skill` answers with — must see the
  /// *same* set. Two scans could disagree after a file appears between them, and then the panel would
  /// offer a skill that the expansion refuses.
  ///
  /// A directory missing from the map means "not looked yet" rather than "none found": an empty
  /// result is a real answer, and re-scanning for it on every use would put a directory walk in the
  /// path of every prompt.
  skills : Map[String, Array[@core.Skill]]
  /// Where this shell's facts go.
  ///
  /// **The seam**, and the reason it is a value rather than the C function it used to be called
  /// directly: a test can stand in front of a value and a test cannot stand in front of `wei_emit`.
  /// Every method below decides what to say and then hands it here, so what a command *says* is a
  /// thing a test can assert — where before, the only way to pin an event's shape was to rebuild
  /// it beside the code that builds it, and two hand-written copies of the same literal cannot
  /// disagree with each other.
  ///
  /// The host installs `emit`, which writes a line to `wei_emit`; a test installs an array it can
  /// read back. Nothing between the two is different, which is the point: callers and tests cross
  /// the same seam, or the seam is in the wrong place.
  out : (Json) -> Unit
}

///|
/// Say one thing, and say where it goes.
///
/// One method for all of them, so that the sink is reached in exactly one place: a shell that wrote
/// to `emit` directly from forty call sites would have forty seams, and none of them would be the
/// one a test could use.
fn Shell::emit(self : Shell, event : Json) -> Unit {
  (self.out)(event)
}

///|
/// The session on screen. Every command that does not name one acts on this.
///
/// Panics rather than returning an option: the registry is never empty while the loop runs — `open`
/// creates the first session and nothing removes the last one without replacing it — and a `Some` that
/// every caller has to unwrap would be a lie about a state that cannot happen.
fn Shell::shown(self : Shell) -> Open {
  match self.open_of(self.current) {
    Some(open) => open
    None => abort("no session on screen: \{self.current}")
  }
}

///|
/// One open session by its file, or `None` when this process is not holding it.
fn Shell::open_of(self : Shell, path : String) -> Open? {
  for open in self.opens {
    if open.path == path {
      return Some(open)
    }
  }
  None
}

///|
/// Put a session on screen, opening it in the registry if it is not there yet.
///
/// The one place `current` is written, so that "which session is shown" has a single answer rather
/// than one per command that happens to need it.
fn Shell::display(self : Shell, open : Open) -> Unit {
  match self.open_of(open.path) {
    None => self.opens.push(open)
    Some(_) => ()
  }
  self.current = open.path
}

///|
/// One picture on its way to a model, already in the shape the wire wants.
priv struct Attachment {
  /// What the reader picked it from. Shown, and used as the key an attach of the same file replaces.
  path : String
  mime_type : String
  /// Base64 of the file's bytes.
  data : String
}

///|
/// What the previous turn cost, for the line under the composer.
///
/// Empty when nothing has been sent in this session, which the host draws as less rather than as
/// zeroes: a turn that has not happened has no figures, and printing `0` for it would say a turn was
/// free.
priv struct LastTurn {
  usage : @core.Usage
  model_calls : Int
  tool_calls : Int
  cost : Double
  /// Whether the fields above describe a turn that happened.
  present : Bool
}

///|
/// An empty turn's figures, and the value a fresh shell starts with.
fn no_last_turn() -> LastTurn {
  {
    usage: @core.Usage::zero(),
    model_calls: 0,
    tool_calls: 0,
    cost: 0.0,
    present: false,
  }
}

///|
/// Where the session log lives, unless the host says otherwise.
fn store_root(home : String) -> String {
  match @env.get_env_var("WEI_STORE") {
    Some(value) if value != "" => value
    _ => "\{home}/.wei/sessions"
  }
}

///|
/// The key a turn will send, and where it came from.
///
/// The precedence is `@core.choose_api_key` rather than the order of two `if`s, so a variable still
/// overrules the saved key and the panel and the turn cannot disagree about which is in use.
///
/// There is no third source. The panel saves a key where this shell can read it back, so the panel
/// can always explain what is being sent; a key that came from somewhere this shell cannot describe
/// would be a key the panel could not explain.
fn resolve_key(settings : @core.AppSettings) -> @core.KeyChoice? {
  @core.choose_api_key(env_key(), settings.saved_api_key)
}

///|
/// The directory the agent works in, when the process has none of its own.
///
/// A double-clicked `.app` is launched with `/` as its working directory — Finder passes no
/// directory, and the kernel's default is the root — so taking that at face value would put every
/// session started from the Finder in a store slice of its own, run its tools against the root of
/// the volume, and describe a workspace called nothing at all. `/` therefore means "no directory was
/// chosen", and what is left is the two answers below, in the order that gets the reader's own
/// situation first:
///
/// 1. **The workspace used last**, which is the only thing this program knows about a reader who did
///    not say. It is what the sidebar's order already means, so the app opens where they left off
///    rather than somewhere new — and, unlike the fallback, it is a *place they chose*, which is
///    what keeps a launch from quietly growing a workspace in a directory nobody meant to work in.
/// 2. **The home directory**, when there is no store to ask. That is the honest stand-in for a first
///    run — where a person's own terminal opens, and at least a directory that means something — and
///    it is now the only launch that can reach this branch.
///
/// Only `/` is treated this way. Anything else is a directory somebody chose — a shell's `cd`, a
/// launcher, "Open With" — and second-guessing those would be worse than the problem.
fn start_dir(cwd : String, last_workspace : String, home : String) -> String {
  if cwd != "/" {
    return cwd
  }
  if last_workspace != "" {
    return last_workspace
  }
  home
}

///|
/// The workspace at the top of the store's own order: the one the reader worked in last.
///
/// The listing `say_sessions` draws from, read for one field of its first entry. That is a readdir,
/// a stat per session and the first 8KB of one header per workspace (`list_workspaces`), which is
/// the price of the answer at a launch that has no directory of its own — and it is the same read
/// the sidebar does a moment later.
///
/// Empty when there is no store yet, or nothing in it that can name a directory. The caller supplies
/// the fallback; this returns "the store has no answer" and not a guess.
async fn last_workspace(root : String) -> String {
  let stored = @platform.list_workspaces(root)
  if stored.is_empty() {
    ""
  } else {
    stored[0].cwd
  }
}

///|
/// Open the session this process should show: the file named by `WEI_SESSION`, or a new one
/// in the current directory.
///
/// Resuming is the whole of the persistence work paying off — the file was written by whatever ran
/// last, and it is read back through the same parser the round-trip verifier exercises.
async fn open_session(
  shell_root : String,
  cwd : String,
) -> (@core.Session, String) {
  match @env.get_env_var("WEI_SESSION") {
    Some(path) if path != "" => {
      guard @platform.path_exists(path) else {
        raise Failure::Failure("no session file at \{path}")
      }
      // The transcript is made valid before anything reads it, by the one implementation of that
      // rule (`@agent.repair_session`): a log written by a process that died, or by an older build,
      // can have a tool result in the wrong place, and the first request built from it would be
      // refused. The interrupted turn is left open — offering to continue it is the app's business,
      // and this is not the place to decide it.
      let loaded = @platform.load_session(path)
      let session = @agent.repair_session(
        loaded,
        path,
        @env.now().reinterpret_as_int64(),
      )
      (session, path)
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
/// Everything the shell has to read out of the world before it can exist.
///
/// **Why the split.** `Shell::open` used to do both jobs at once: it read the environment, the
/// filesystem and the process table, *and* it assembled the struct. That made the struct
/// unconstructible anywhere but a real launch — so the fifty methods hanging off it, and every
/// decision they make, could only be exercised by opening the app. Reading is now this type's job
/// and only this type's job; assembling is `Shell::of`, which is pure, and therefore reachable from
/// a test with a literal.
///
/// The fields are the answers rather than the questions: `start` rather than "which directory
/// should I start in", `session` and `path` rather than "which session should I open". A field that
/// named a question would put the reading back inside `of`.
priv struct World {
  home : String
  settings : @core.AppSettings
  root : String
  /// Where a session's tools run when the session itself does not say.
  start : String
  base_url : String
  jobs : @core.JobStore
  pins : Array[String]
  session : @core.Session
  path : String
  /// Where a per-turn diagnostic line goes, when somebody asked for one.
  ///
  /// Read here with the other environment facts, for the reason the whole `World`/`Shell` split
  /// exists: one place reads the world, and everything else is pure. Empty means no line is written,
  /// which is the ordinary case.
  debug_log : String
}

///|
/// Read the world: the environment, the store, the session to open.
///
/// The only part of starting that touches anything, and it is `async` because reading a session is.
/// Everything it returns is a value, so all of starting is: gather, then assemble.
async fn gather() -> World {
  let home = match @env.get_env_var("HOME") {
    Some(value) if value != "" => value
    _ => raise Failure::Failure("HOME is not set")
  }
  let cwd = @platform.current_dir()
  let settings = @platform.load_settings(home)
  let root = store_root(home)
  // What a session's directory is when nothing else says: `start_dir` above, with the store's own
  // answer to "where was I".
  let start = start_dir(cwd, last_workspace(root), home)
  let (session, path) = open_session(root, start)
  let base_url = match @env.get_env_var("DEEPSEEK_BASE_URL") {
    Some(value) if value != "" => value
    _ => "https://api.deepseek.com"
  }
  {
    home,
    settings,
    root,
    start,
    base_url,
    // Read back from the previous run rather than started empty. A job is a *process*, and the whole
    // reason the panel exists is work that outlived the thing that started it — including this
    // program. A store that began empty every launch would forget a `sleep 3600` it left running,
    // with no way to stop it from here.
    jobs: @platform.load_jobs(home),
    pins: @platform.load_pins(home),
    session,
    path,
    // The same variable `WeiKit.WireLog` writes the host's side of the wire to, and read here so
    // that one `WEI_DEBUG` turns on both halves. Off unless asked for, because a log beside the app
    // that fills up unasked is a surprise.
    debug_log: match @env.get_env_var("WEI_DEBUG") {
      Some(value) if value != "" => value
      _ => ""
    },
  }
}

///|
/// The shell that owns this world, with somewhere to say things.
///
/// Pure, and the seam a test comes in through. `out` is where this shell's facts go, so a literal
/// `World` and an array to record into are all it takes to ask what a command *says* — without
/// opening the app, reading a store, or listening on a wire.
fn Shell::of(world : World, out? : (Json) -> Unit = emit) -> Shell {
  // A resumed session brings its own directory with it: `WEI_SESSION` can name a file written
  // somewhere else, and running its tools in the directory this process happens to have been started
  // in would be a different session's workspace. An empty one is a header nobody filled in, and the
  // directory the reader was last in is the better guess.
  let working = if world.session.header.cwd == "" {
    world.start
  } else {
    world.session.header.cwd
  }
  let opening = Open::new(
    world.path,
    working,
    session_model(world.session),
    // The level the log recorded for this session's model, or that model's default for a session
    // nobody has asked anything of yet — the same rule the model itself follows on the line above.
    session_level(world.session, session_model(world.session)),
    world.session,
  )
  {
    base_url: world.base_url,
    jobs: world.jobs,
    settings: world.settings,
    home: world.home,
    debug_log: world.debug_log,
    pins: world.pins,
    root: world.root,
    // One session to begin with. The others are opened by switching, and none of them is opened
    // eagerly: a registry that read every session in the store would pay for conversations nobody
    // asked for, which is the same cost the sidebar avoids by describing them instead of reading
    // them.
    opens: [opening],
    current: world.path,
    labels: Labels::new(),
    live_pids: [],
    saved_jobs: "",
    sent_jobs: "",
    skills: Map([]),
    // The wire, unless somebody hands in a different one. See `Shell::emit`.
    out,
  }
}

///|
/// The shell this process runs on: gather the world, assemble it, and open.
async fn Shell::open() -> Shell {
  Shell::of(gather())
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
/// A fact about one session, with the session named.
///
/// Naming it is what makes more than one turn possible at a time: the host draws a transcript per
/// session, and a delta it cannot place is a delta it would have to write into whatever happens to be
/// on screen — which is exactly the failure this field prevents, and one that only appears once two
/// conversations are moving at once.
///
/// An **empty** `session` means "the one on screen", and that is deliberate rather than lazy: most of
/// what the shell says is an answer to something the reader just did to the session they are looking
/// at (a bad path, an unknown model), and those need no name to be understood. Only a running turn has
/// to say where it belongs, because a running turn is the one thing that can be about a conversation
/// nobody is looking at.
fn session_event(
  path : String,
  kind : String,
  fields : Array[(String, Json)],
) -> Json {
  let pairs : Array[(String, Json)] = [
    ("kind", Json::string(kind)),
    ("session", Json::string(path)),
  ]
  for field in fields {
    pairs.push(field)
  }
  Json::object(Map(pairs))
}

///|
/// The session that is open, and what a reader needs to know about it. Sent first, and again
/// whenever one of those four facts changes — saving a key is what made it a snapshot rather than a
/// greeting, because the window a key saves is a window that can send again.
fn Shell::say_ready(self : Shell, open : Open, key_source : String) -> Unit {
  self.emit(ready_event(open, key_source))
}

///|
/// The `ready` event, from the facts rather than from the shell.
///
/// Split out for the reason the others are: the field names are the contract with the host, and a
/// contract that can only be asserted by standing up a whole shell is one nobody asserts.
fn ready_event(open : Open, key_source : String) -> Json {
  session_event(open.path, "ready", [
    ("model", Json::string(model_name(open))),
    ("cwd", Json::string(open.cwd)),
    // Named rather than implied: an empty key is a thing the host has to say out loud, and
    // "where did the key come from" is the question the first failure always raises.
    ("key", Json::string(key_source)),
  ])
}

///|
/// The prompt, echoed so the host can put it in the conversation without having kept its own
/// copy of what it sent.
///
/// `images` are the pictures that went out with it, **carried with the prompt rather than as an event
/// of their own**: they are part of the question, the shell takes them off the composer in the same
/// breath, and a separate event would be a second thing for the host to keep in step with a question
/// that may already be drawn.
fn Shell::say_user(
  self : Shell,
  path : String,
  text : String,
  continued? : Bool = false,
  images? : Array[(String, String)] = [],
) -> Unit {
  self.emit(user_event(path, text, continued, images))
}

///|
/// The prompt, echoed, as the wire carries it.
///
/// The routing `session` comes from here rather than being written into the test: a `user` event is
/// about a conversation, and the prompt for a turn in a background session has to land in that
/// session's transcript rather than in whichever one happens to be on screen.
fn user_event(
  path : String,
  text : String,
  continued : Bool,
  images : Array[(String, String)],
) -> Json {
  session_event(path, "user", user_fields(text, continued, images))
}

///|
/// The fields of a `user` event, as a pure function.
///
/// Split out from `say_user` because the emit path cannot be asserted (nothing here defines
/// `wei_emit`) and this is a **rule**: whether a prompt was a `/skill:<name>` command, and what the
/// three parts of it are, is the decision the whole transcript hangs on — a host that is told the
/// wrong thing about it draws a page of somebody else's instructions as the reader's own sentence.
fn user_fields(
  text : String,
  continued : Bool,
  images : Array[(String, String)],
) -> Array[(String, Json)] {
  let pictures : Array[Json] = []
  for (mime_type, data) in images {
    pictures.push(image_row(mime_type, data))
  }
  let fields : Array[(String, Json)] = [
    ("text", Json::string(text)),
    // A continued turn carries a prompt the host has already seen: it is the last user message in
    // the log, and appending it again would put the question on screen twice. The flag is what
    // lets the host start a new turn — with a new set of row names — without drawing a second
    // question.
    ("continued", Json::boolean(continued)),
    ("images", Json::array(pictures)),
  ]
  // A `/skill:<name>` prompt is the shell's own framing with the skill's whole document inside it —
  // thousands of characters the reader never typed and should not have drawn at them. The three
  // parts go over as written when the prompt is one, so the host can show the command and fold the
  // body; a prompt that is not a framing adds nothing, and **no field at all** is what says so
  // rather than a flag whose false is the same fact as its absence.
  //
  // `text` still goes over whole, and deliberately: it is what the model was asked, which is what a
  // wire log is for and what an older host draws. The host's own history takes the same message apart
  // with the same function (`core.skill_expansion_parts`), so a replayed turn and a live one cannot
  // disagree about where the reader's words are.
  match @core.skill_expansion_parts(text) {
    Some((name, args, body)) =>
      fields.push(
        (
          "skill",
          Json::object(
            Map([
              ("name", Json::string(name)),
              ("args", Json::string(args)),
              ("body", Json::string(body)),
            ]),
          ),
        ),
      )
    None => ()
  }
  fields
}

///|
/// A block of the answer, or of the reasoning, as it streams.
///
/// Deltas under one `id` rather than one string per frame: that is what makes the host's append
/// cheap, and it is the same decision the web UI made when a replacement-per-delta turned out to
/// be quadratic.
fn Shell::say_piece(
  self : Shell,
  path : String,
  kind : String,
  id : String,
  delta : String,
) -> Unit {
  self.emit(piece_event(path, kind, id, delta))
}

///|
/// One delta of a streaming block, as the wire carries it.
fn piece_event(
  path : String,
  kind : String,
  id : String,
  delta : String,
) -> Json {
  session_event(path, kind, [
    ("id", Json::string(id)),
    ("delta", Json::string(delta)),
  ])
}

///|
/// A block that has stopped growing, and how to draw it.
///
/// The shell does the parsing because the host cannot: `AttributedString(markdown:)` takes the source
/// rather than a parse, so a table arrives as its own punctuation and a fenced block loses its
/// language. `md/` is cmark — the same engine the web UI renders with — so both front ends have the
/// same opinion about the same answer, which is the whole reason it is a shared package.
///
/// The parse is done here and *diffed*: the host keeps the blocks it has already been given, so what
/// crosses is the part that changed. The web UI sent the whole block once, at the end, because a host
/// that cannot keep a parse has to be given one; this one can, which is what makes rendering the
/// answer while it arrives affordable.
///
/// This is called where a block stops being the newest thing that happened — a tool call, the other
/// kind of text, or the end of the turn — which are exactly the moments the host stops appending to
/// that row. It is the one parse of the whole block; everything before it was the tail.
fn Shell::say_blocks(
  self : Shell,
  path : String,
  id : String,
  text : String,
  live : LiveMarkdown?,
) -> Unit {
  if id == "" || text == "" {
    return
  }
  let blocks = @md.parse(text)
  let from = match live {
    Some(state) if state.id == id => @md.diff_prefix(state.sent, blocks)
    _ => 0
  }
  self.say_blocks_from(path, id, from, blocks)
}

///|
/// Blocks `from` onwards, for a row the host already has the head of.
///
/// `from` is the number of leading blocks the host is holding, and it is a protocol field rather than
/// an implementation detail: a host that does not know about it would append the tail to a document
/// it never received the head of. The field is therefore required to be understood, and a host that
/// cannot apply it drops the frame rather than guessing (`WeiModel`'s `Conversation.apply`).
///
/// An **empty** tail is a real frame and is sent as one: it is how a block that turned out shorter
/// than its own prefix is corrected. Nothing in the live path sends one — `live_frame` refuses a frame
/// with nothing new — so this is the shape only the end of a block has.
fn Shell::say_blocks_from(
  self : Shell,
  path : String,
  id : String,
  from : Int,
  blocks : Array[@md.Block],
) -> Unit {
  if id == "" {
    return
  }
  self.emit(blocks_event(path, id, from, blocks))
}

///|
/// One `blocks` frame, as the wire carries it.
///
/// Takes the whole parse and the index the host has up to, rather than a pre-cut tail: which blocks
/// are the tail is the same fact as the `from` field, and deriving them in two places is how a frame
/// comes to say `from: 4` and carry five blocks.
fn blocks_event(
  path : String,
  id : String,
  from : Int,
  blocks : Array[@md.Block],
) -> Json {
  let tail : Array[Json] = []
  for index in from..<blocks.length() {
    tail.push(blocks[index].to_json())
  }
  session_event(path, "blocks", [
    ("id", Json::string(id)),
    ("from", Json::number(from.to_double(), repr=from.to_string())),
    ("blocks", Json::array(tail)),
  ])
}

///|
/// One live frame, as the wire carries it.
///
/// The same `blocks` kind as the finished one above, and the same routing field: a frame from a turn
/// in a background session has to land in *that* transcript. It differs only in that a frame carries
/// the tail from `from` while `blocks_event` cuts the tail itself, which is why there are two.
fn blocks_frame_event(path : String, frame : LiveFrame) -> Json {
  session_event(path, "blocks", frame.fields())
}

///|
/// Refresh the rendering of a block that is still arriving.
///
/// Called on every delta and refused most of the time — see `LiveMarkdown` for the two gates — so the
/// cost of a long answer is one parse every `LIVE_MARKDOWN_MS` of a block's *tail* rather than one
/// parse of the whole of it per delta.
///
/// `length` is the block's length so far, counted as the deltas arrive rather than read off the
/// buffer: materialising the whole of a growing block to ask how long it is would be the same
/// quadratic the rest of this exists to avoid.
fn Shell::live_blocks(
  self : Shell,
  path : String,
  open : Open,
  text : StringBuilder,
  length : Int,
  now : UInt64,
) -> Unit {
  match open.live {
    None => ()
    Some(state) =>
      // **The gate is asked before the string is built**, and the order is the difference between O(n)
      // and O(n²): `to_string` on a growing buffer copies everything arrived so far, and a block that
      // arrives in sixty-four character deltas would copy its own length hundreds of times. Refused
      // frames are the common case — most deltas — so they must cost nothing.
      if live_due(state, length, now) {
        match live_frame(state, text.to_string(), length, now) {
          Some(frame) => self.emit(blocks_frame_event(path, frame))
          None => ()
        }
      }
  }
}

///|
/// Whether this delta is worth a frame at all.
///
/// Two gates, and both are needed. The clock alone would let a fast model pile up a second of text and
/// then send it all at once — a stall in the middle of a stream, which is the one thing streaming
/// exists to avoid. The size alone would make a slow model's every delta pay for a parse, and a model
/// trickling out one character at a time is exactly the case this is *not* for.
fn live_due(state : LiveMarkdown, length : Int, now : UInt64) -> Bool {
  now - state.at_ms >= LIVE_MARKDOWN_MS ||
  length - state.at_length >= LIVE_MARKDOWN_CHARS
}

///|
/// One live frame, or nothing when it is too soon to be worth one.
///
/// The decision, the parse and the diff, separated from the emission so that they can be asserted:
/// what a frame says is a fact about a protocol two builds share, and a fact that is worth a test is
/// worth a function that can be called one.
///
/// Only the part up to the last blank line is parsed, and only the part that has changed is sent.
/// Everything after that boundary is one block that is still being written, and what the reader has
/// already read never moves — see `@md.safe_boundary`.
fn live_frame(
  state : LiveMarkdown,
  source : String,
  length : Int,
  now : UInt64,
) -> LiveFrame? {
  // Recorded before the work: a frame that turns out to have nothing new in it still moves the clock,
  // so the next delta is judged against *this* attempt rather than the last frame that happened to
  // send something. Nothing is recorded on the other path — a refused delta is refused again next
  // time, which is what makes the size gate work.
  state.at_length = length
  state.at_ms = now
  let at = @md.safe_boundary(source)
  let blocks = @md.parse(source[:at].to_owned())
  let from = @md.diff_prefix(state.sent, blocks)
  if from >= blocks.length() {
    // Nothing new *finished*: the open block is still growing, and it is already on the host's
    // screen as text. Sending it again would be a frame that redraws the same paragraph.
    return None
  }
  state.sent = blocks
  // The **tail**, not the whole parse: the host is holding the head, and a frame that repeated it
  // would be applied as `head + head + tail`. The web UI's equivalent sent whole blocks because it
  // had nothing to diff against; this path's whole point is that it does.
  Some({ id: state.id, from, blocks: blocks[from:].to_owned(), })
}

///|
/// What one live frame says.
///
/// The content and the framing, as separate things, because they fail separately: what a frame
/// *means* is a rule about two documents agreeing, and it is asserted by replaying a block's deltas
/// and comparing the result with one parse of the whole. How it is spelled on the wire is the `from`
/// field and the tagged objects, and that is asserted against a literal.
priv struct LiveFrame {
  /// The row this is the rendering of. Named on every frame rather than once, because the host files
  /// by it: a block's frames interleave with other blocks' in one stream, and a frame without an id
  /// has nothing to be applied to.
  id : String
  /// How many leading blocks the host is holding.
  from : Int
  /// The blocks from `from` on — and only those. A frame carrying the whole parse would be applied
  /// on the host as `head + head + tail`.
  blocks : Array[@md.Block]
}

///|
/// A frame as the wire carries it.
fn LiveFrame::fields(self : LiveFrame) -> Array[(String, Json)] {
  let tail : Array[Json] = []
  for block in self.blocks {
    tail.push(block.to_json())
  }
  [
    ("id", Json::string(self.id)),
    ("from", Json::number(self.from.to_double(), repr=self.from.to_string())),
    ("blocks", Json::array(tail)),
  ]
}

///|
/// A tool, running or finished, always under the same id so the finished row replaces the running
/// one instead of leaving it behind.
///
/// The shape is `tool_event`'s; what is here is the one line that makes it go out. The split is the
/// same one `models_event` and `usage_event` already have, and it is what lets the field names be
/// asserted at all: a test can call a function that returns Json, and it cannot call a function whose
/// only effect is to write to a wire it cannot see.
fn Shell::say_tool(
  self : Shell,
  path : String,
  id : String,
  name : String,
  detail : String,
  done : Bool,
  output : String,
  is_error : Bool,
) -> Unit {
  self.emit(tool_event(path, id, name, detail, done, output, is_error))
}

///|
/// One tool row, as the wire carries it.
///
/// Pure, and next to the emitter rather than in the test file, because the two lists of field names
/// were previously written twice — once here and once in `app_wbtest.mbt` — and neither could fail
/// when the other changed. A test that is a transcription of the implementation is not a test.
fn tool_event(
  path : String,
  id : String,
  name : String,
  detail : String,
  done : Bool,
  output : String,
  is_error : Bool,
) -> Json {
  session_event(path, "tool", [
    ("id", Json::string(id)),
    ("name", Json::string(name)),
    ("detail", Json::string(detail)),
    ("done", Json::boolean(done)),
    ("output", Json::string(output)),
    ("error", Json::boolean(is_error)),
  ])
}

///|
fn Shell::say_status(self : Shell, path : String, text : String) -> Unit {
  self.emit(status_event(path, text))
}

///|
/// What the shell is doing right now, as the wire carries it.
fn status_event(path : String, text : String) -> Json {
  session_event(path, "status", [("text", Json::string(text))])
}

///|
/// A turn is over. `text` is empty when it finished normally — the answer is the report — and
/// otherwise says which guard stopped it, which is the one thing the figures cannot say.
fn Shell::say_end(
  self : Shell,
  path : String,
  text : String,
  calls : Int,
  tools : Int,
  cost : Double,
) -> Unit {
  self.emit(end_event(path, text, calls, tools, cost))
}

///|
/// A turn's ending and its figures, as the wire carries them.
fn end_event(
  path : String,
  text : String,
  calls : Int,
  tools : Int,
  cost : Double,
) -> Json {
  session_event(path, "end", [
    ("text", Json::string(text)),
    // Given an integer spelling rather than a float: JSON has one number type and a host that
    // decoded these as doubles would have to decide what `19.0` means for a count.
    ("calls", Json::number(calls.to_double(), repr=calls.to_string())),
    ("tools", Json::number(tools.to_double(), repr=tools.to_string())),
    ("cost", Json::string(@core.format_cost(cost))),
  ])
}

///|
/// Something went wrong, and which session it went wrong in.
///
/// Defaulted to the session on screen because that is what almost every failure is about: a path the
/// reader picked, a model id they chose, a turn they asked for. The exception is a turn failing, and
/// it passes its own path — a background conversation breaking must not stop the one being watched
/// from being able to send.
fn Shell::say_error(
  self : Shell,
  text : String,
  session? : String = "",
) -> Unit {
  self.emit(error_event(session, text))
}

///|
/// Something went wrong, and which session it went wrong in.
fn error_event(session : String, text : String) -> Json {
  session_event(session, "error", [("text", Json::string(text))])
}

///|
/// Every model this build can call, which of them the session is on, and what each one costs.
///
/// Sent because the picker is a host control and the catalog is compiled into the shell: a list the
/// host kept of its own would be a second place for the two to disagree about what can be called, and
/// the shell is the one that refuses an id it does not know. The `vision` flag comes along so the
/// picker can say which models can be shown a picture — the reader is the one who has to decide
/// between the model and the screenshot they just attached.
///
/// **The prices come along as strings, already cut to their columns.** They are the reason a reader
/// opens this menu at all — the pro model is nine times flash's input rate, which is what the entry's
/// own doc comment in `core/model_catalog.mbt` says makes it worth choosing deliberately — and they
/// arrive formatted rather than as numbers because what the host does with them is *place* them: three
/// prices compared down a list need equal widths, which is a fact about the characters, and deriving
/// that in Swift would be a second implementation of the same rule. `unit` is the sentence the menu
/// says once instead of three times.
fn Shell::say_models(self : Shell, open : Open) -> Unit {
  self.emit(models_event(open.path, open.model_id))
}

///|
/// The same event, built from the model in force rather than from the shell.
///
/// Split out so the field names can be asserted without a session on disk, the same way the sessions
/// and the usage events are.
fn models_event(path : String, current : String) -> Json {
  let items : Array[Json] = []
  for spec in @core.model_catalog() {
    let (input, output, cached) = spec.pricing.columns()
    items.push(
      Json::object(
        Map([
          ("id", Json::string(spec.id)),
          ("label", Json::string(spec.label())),
          ("vision", Json::boolean(spec.vision)),
          (
            "prices",
            Json::object(
              Map([
                ("input", Json::string(input)),
                ("output", Json::string(output)),
                ("cached", Json::string(cached)),
              ]),
            ),
          ),
        ]),
      ),
    )
  }
  session_event(path, "models", [
    ("items", Json::array(items)),
    // The session's own model, which is the log's answer rather than the picker's: a resumed session
    // runs on whatever it recorded, and the picker has to show that rather than the default.
    ("current", Json::string(current)),
    // Empty when there is nothing to say, which is what the host checks before drawing a header.
    ("unit", Json::string(price_unit())),
  ])
}

///|
/// What the price columns are denominated in, said once for the whole menu.
///
/// A sentence rather than a unit symbol because the symbol would have to be repeated on every number to
/// be true of it (`$0.14`), which is three glyphs and three spaces of column width per row for a fact
/// that is the same on all of them. `in · out · cached` names the three columns in the order the rows
/// print them, so the header is also the legend.
fn price_unit() -> String {
  "US dollars per million tokens — in · out · cached"
}

///|
/// Say what thinking level the session is on.
///
/// One event for both the menu and the sentence about it, because they are two views of one fact: the
/// shell answers a reader twice from the same pair of values, and a second event built from the same
/// pair would be a second place for them to disagree.
fn Shell::say_think(self : Shell, open : Open) -> Unit {
  self.emit(think_event(open.path, open.model_id, open.think_level))
}

///|
/// The levels a model offers, and the one in force, as the wire carries them.
///
/// The items are the *model's* levels (`ThinkingLevels::offered`), not a list compiled in here: the
/// levels are per model, and a menu drawn from a shared table would offer `low` on a model that
/// rejects it. `current` is always one of them, because `Open::think_level` is kept that way.
///
/// Each item carries its own sentence, so the words a reader acts on are written next to the level
/// they are about — and in the shell, where the level's meaning is known, rather than in a host that
/// would have to learn what `xhigh` is. `default` marks the level a session gets when nobody has
/// said; the menu shows it rather than promising a behaviour it would have to re-derive.
///
/// Built from arguments rather than from `Open` so the field names can be asserted without a session
/// on disk, the same way `models_event` is.
fn think_event(path : String, model_id : String, current : String) -> Json {
  let levels = @core.model_spec_for(model_id).0.thinking_levels
  let fallback = levels.default_level()
  let items : Array[Json] = []
  for level in levels.offered() {
    items.push(
      Json::object(
        Map([
          ("id", Json::string(level)),
          ("label", Json::string(level_label(level))),
          ("detail", Json::string(level_detail(level))),
          ("default", Json::boolean(level == fallback)),
        ]),
      ),
    )
  }
  session_event(path, "think", [
    ("items", Json::array(items)),
    ("current", Json::string(current)),
  ])
}

///|
/// What a level calls itself, in words a reader picks by rather than the word the API takes.
///
/// `max` is left as it is because that is what it means: the most thinking this model does. A name
/// with no entry is shown as itself — a level this build has never heard of is still a level the
/// session is on, and hiding it would leave the menu with nothing ticked.
fn level_label(level : String) -> String {
  match level {
    "off" => "Off"
    "minimal" => "Minimal"
    "low" => "Low"
    "medium" => "Medium"
    "high" => "High"
    "xhigh" => "Extra high"
    "max" => "Max"
    _ => level
  }
}

///|
/// The one line that says what picking a level buys.
///
/// Written to be read *after* the level's own name — the menu shows `Low — thinks briefly — sooner first
/// word` — so each one says what the reader gets and pays rather than what the model does internally:
/// the reason to pick `low` is that it starts answering sooner, and "reasoning effort: low" says nothing
/// a reader could act on.
///
/// **Short, and measured.** A first version said all of it out in full sentences ("thinks a little: a
/// sooner first word, a smaller bill"), and the menu came out **511 points wide** — more than half the
/// window, for a control whose whole point is being a small choice (`AXMenuItem … [953,706 511x24]`,
/// read with the AX probe in `docs/macos-pitfalls.md` 第六节). That is the menu's own arithmetic and not
/// a style opinion: its width is its longest item, so every extra word is paid for in the one dimension
/// a menu cannot wrap. These are the same sentences cut to one clause each — measured as text, the
/// longest went from 470 to 330 points (`NSFont.menuFont`, both numbers in the same place).
///
/// Empty is a real answer, for a level this build has no words for: the host falls back to the name
/// rather than showing a sentence it had to invent.
fn level_detail(level : String) -> String {
  match level {
    "off" => "fastest and cheapest; answers may be shallower"
    "minimal" => "barely any thinking"
    "low" => "thinks briefly; a sooner first word"
    "medium" => "thinks a moderate amount"
    "high" => "thinks before answering"
    "xhigh" => "thinks at length"
    "max" => "thinks longest; slowest and dearest"
    _ => ""
  }
}

///|
/// The background jobs, as the panel draws them.
///
/// Only the live ones. The store keeps finished jobs — it is how a restart accounts for a process it
/// did not start, and how a kill still reaches every pid — but the panel answers "what is still
/// running", and a row for work that is over is a row with no action on it.
///
/// The pids that are still alive come along rather than the list as recorded: a command is registered
/// with its own shell and with the helper that reported it, and neither is what a reader looking for
/// the process in `ps` wants to see.
fn Shell::say_jobs(self : Shell) -> Unit {
  let json = jobs_event(
    self.jobs.list(),
    self.live_pids,
    @env.now().reinterpret_as_int64(),
  )
  // Sent when it changed, and only then. The tick is every two seconds and most of the time nothing
  // is running, so an unconditional send would put thirty identical empty events a minute on the
  // wire and wake the host just as often for a panel that is not on screen. A running job always
  // changes — its age moves — so the update still arrives while there is something to show.
  let text = json.stringify()
  if text == self.sent_jobs {
    return
  }
  self.sent_jobs = text
  self.emit(json)
}

///|
/// The same event, from the facts rather than from the shell.
///
/// Split out for the reason the others are: the field names are the contract with the host, and a
/// contract that can only be asserted by standing up a whole shell is one nobody asserts.
fn jobs_event(
  jobs : Array[@core.Job],
  live_pids : Array[Int],
  now : Int64,
) -> Json {
  let items : Array[Json] = []
  for job in jobs {
    if !job.is_live() {
      continue
    }
    let pids : Array[Json] = []
    for pid in job.pids {
      if live_pids.contains(pid) {
        pids.push(Json::number(pid.to_double(), repr=pid.to_string()))
      }
    }
    let age = job.age_ms(now)
    items.push(
      Json::object(
        Map([
          ("id", Json::string(job.id)),
          ("kind", Json::string(job.kind)),
          ("label", Json::string(job.label)),
          ("status", Json::string(job.status.to_string())),
          // Milliseconds, and an integer on the wire: the host formats it and keeps it counting, and
          // a duration is not a number a host should have to round.
          ("age_ms", Json::number(age.to_double(), repr=age.to_string())),
          ("pids", Json::array(pids)),
          ("session", Json::string(job.session)),
        ]),
      ),
    )
  }
  event("jobs", [("items", Json::array(items))])
}

///|
/// A row that stands in for something the conversation no longer holds in full.
///
/// A compaction is the case: the reader's own words are gone from what the model is sent, replaced by
/// a summary of them, and nothing else on the wire says so. It is a fact about the transcript rather
/// than about the turn's figures, which is why it is a row and not a status line — it belongs at the
/// point in the conversation where it happened.
///
/// `label` is what makes it legible: without it the summary is a paragraph a reader takes for an
/// answer. The same field carries the title of a branch summary, so one shape covers both.
fn Shell::say_note(
  self : Shell,
  path : String,
  text : String,
  label : String,
) -> Unit {
  self.emit(note_event(path, text, label))
}

///|
/// A row that stands in for something the conversation no longer holds, as the wire carries it.
fn note_event(path : String, text : String, label : String) -> Json {
  session_event(path, "note", [
    ("text", Json::string(text)),
    ("name", Json::string(label)),
  ])
}

///|
/// How many compactions a session's path holds, and the newest one's summary.
///
/// Counted rather than flagged: a turn can compact more than once, and what the host needs to know is
/// that the number went *up* — a boolean would miss the second one inside one turn.
fn compaction_state(session : @core.Session) -> (Int, String) {
  let mut count = 0
  let mut latest = ""
  for entry in session.path() {
    match entry.kind {
      @core.Compaction(summary~, ..) => {
        count += 1
        latest = summary
      }
      _ => ()
    }
  }
  (count, latest)
}

///|
/// The pictures waiting to go out with the next prompt.
///
/// Sent whole, on every change, for the same reason the session list is: the host draws the list of
/// attachments it was told about, and a host that had to apply adds and removes of its own would be
/// a second opinion about what is on its way. The bytes come along because they are what the host
/// previews from — a thumbnail it can draw without reading the file again, which is also what makes
/// the preview the picture the model will actually see.
fn Shell::say_images(self : Shell, open : Open) -> Unit {
  self.emit(
    images_event(
      open.path,
      open.attached,
      @core.model_sees_images(open.model_id),
    ),
  )
}

///|
/// The same event, built from the facts rather than from the shell.
///
/// Split out for the same reason `sessions_event` is: the field names are the contract with the host,
/// and a contract that can only be asserted by standing up a whole shell is one that gets asserted by
/// nobody.
fn images_event(
  path : String,
  items : Array[Attachment],
  can_send : Bool,
) -> Json {
  let images : Array[Json] = []
  for attachment in items {
    images.push(
      Json::object(
        Map([
          ("path", Json::string(attachment.path)),
          ("mime", Json::string(attachment.mime_type)),
          ("data", Json::string(attachment.data)),
        ]),
      ),
    )
  }
  session_event(path, "images", [
    ("items", Json::array(images)),
    // Whether the model on screen can be shown a picture at all. A fact about the model, sent with
    // the pictures because it is only interesting next to them, and because a reader who attaches a
    // screenshot to a text-only model should hear it before sending rather than after.
    ("can_send", Json::boolean(can_send)),
  ])
}

///|
/// What this session has used, and what the last turn cost.
///
/// Two figures rather than one, because they answer two questions a reader asks at different times.
/// The session total is what the conversation has cost; the turn's own numbers are what the last
/// question cost, which is what the line under the composer is for while a reader is deciding
/// whether to ask another one.
///
/// The numbers are raw and the formatting is the host's, except for cost: the cents-vs-dollars
/// decision is `core`'s (a turn costs a fraction of a cent, and rounding to cents would print every
/// turn as `$0.00`), and doing it twice is how the two front ends come to disagree.
///
/// `prompt` is the size of the most recent request as the provider measured it, which is the honest
/// answer to "how full is the context": it is what was actually sent, not an estimate of what would
/// be. Before anything has been sent there is no measurement, and zero is what that means.
///
/// The other half of the context story comes with it now — what the *next* request would cost, and
/// whether that is close enough to the window for compaction. See `ContextFacts`.
async fn Shell::say_usage(self : Shell, open : Open) -> Unit {
  let facts = self.context_facts(open)
  self.emit(
    usage_event(
      open.path,
      open.session.usage(),
      open.session.last_prompt_tokens(),
      facts,
      open.last_turn,
    ),
  )
}

///|
/// What the next request would cost, and how sure that is.
///
/// Apart from the totals because it answers a different question, and the difference is the one that
/// changes what happens next: the totals are what has been spent, and this is what is still
/// available. `tokens` is `core`'s anchored figure (the last size the provider reported, plus what
/// has been added since), and `source` says which of the two it leaned on — a host that prints an
/// estimate as if it were a measurement would be lying about the only number that decides when the
/// conversation is summarized.
///
/// `overhead` is carried separately rather than folded in, because "of which ~1,300 are the system
/// prompt and the tool schemas" is the part a reader can do nothing about and therefore wants named
/// rather than hidden in the total.
///
/// `compact_soon` is the same comparison the driver makes before it sends a request
/// (`@core.should_compact` with the reserve for this window), asked here so that the window can warn
/// *before* the turn that would summarize the conversation — which is the one moment this figure is
/// worth a reader's attention.
priv struct ContextFacts {
  tokens : Int
  provider_measured : Bool
  overhead : Int
  window : Int
  compact_soon : Bool
}

///|
/// The system prompt this session's next turn would send.
///
/// One definition, used by the turn that sends it and by the figure that prices it: a context
/// estimate built from a *different* prompt than the one on the wire is an estimate of a request
/// that never goes out, and the two would drift the first time either side changed.
async fn Shell::system_prompt(
  self : Shell,
  open : Open,
  tools : Array[@core.ToolDef],
) -> String {
  @core.build_system_prompt(
    open.cwd,
    tools,
    mode=self.settings.tool_mode,
    instructions=self.instructions(open),
    // The catalog the model reads to decide whether a skill applies. It was missing here while this
    // function's own comment said it was present, and the web and vim front ends both sent it: a
    // macOS session could only use a skill the reader already knew the name of, because nothing in
    // the prompt said which ones existed. Discovery and the setting are both per directory and
    // cached, so this adds no I/O to the turn.
    skills=self.enabled_skills(open.cwd),
    // Empty unless this conversation already ran with a tool the current mode does not have. The
    // setting can change mid-session, and without this the model would keep reaching for a tool
    // that is no longer declared.
    stale_tools=@core.stale_tool_names(open.session.context(), tools),
  )
}

///|
/// The instructions this workspace contributes, if any.
///
/// Split out because building it reads `AGENTS.md` and that is the only part of the estimate that is
/// I/O. Kept async rather than cached: a file the reader edits mid-session is a file the next turn
/// picks up, and a cached copy would price a prompt that no longer exists.
async fn Shell::instructions(self : Shell, open : Open) -> String {
  @core.choose_instructions(
    self.settings,
    @platform.workspace_agents_md(open.cwd),
  ).text
}

///|
/// Where the session stands against the window its model has.
///
/// `tokens` is zero for a conversation with nothing in it yet, and that is the same convention
/// `prompt` uses: a session that has asked nothing has no context to report, and a figure would be
/// the system prompt's own size dressed up as the conversation's.
async fn Shell::context_facts(self : Shell, open : Open) -> ContextFacts {
  let window = @core.model_spec_for(open.model_id).0.context_window
  let tools = @core.tools_for_mode(self.settings.tool_mode)
  let overhead = @core.request_overhead_tokens(
    self.system_prompt(open, tools),
    tools,
  )
  let has_conversation = !open.session.context().messages.is_empty()
  if !has_conversation {
    return {
      tokens: 0,
      provider_measured: false,
      overhead,
      window,
      compact_soon: false,
    }
  }
  // The prepared context rather than the raw one: trimming is part of what the next request will
  // carry, and a figure that ignored it would run ahead of the conversation it describes.
  let pressure = @core.context_pressure(
    open.session.prepared_context().messages,
    overhead,
  )
  {
    tokens: pressure.tokens,
    provider_measured: pressure.source is @core.Provider,
    overhead,
    window,
    compact_soon: @core.should_compact(
      pressure.tokens,
      window,
      reserve_tokens=@core.CompactionSettings::for_window(window).reserve_tokens,
    ),
  }
}

///|
/// The same event, built from the facts rather than from the shell.
///
/// Split out for the reason `images_event` is: this shape is read by a host that was written against
/// the field names, and pinning it should not require a session file.
fn usage_event(
  path : String,
  total : @core.SessionUsage,
  prompt : Int,
  context : ContextFacts,
  last : LastTurn,
) -> Json {
  // Built as a list of pairs, because the shape is flat and the optional fields are the only
  // interesting part: a cache share that does not exist is a field left out rather than a zero.
  // No `mut` on the binding: an array is a mutable structure, and this only ever grows it.
  let fields : Array[(String, Json)] = [
    (
      "turns",
      Json::number(total.replies.to_double(), repr=total.replies.to_string()),
    ),
    (
      "total",
      Json::number(
        total.total_tokens.to_double(),
        repr=total.total_tokens.to_string(),
      ),
    ),
    (
      "input",
      Json::number(total.input.to_double(), repr=total.input.to_string()),
    ),
    (
      "output",
      Json::number(total.output.to_double(), repr=total.output.to_string()),
    ),
    (
      "cache_read",
      Json::number(
        total.cache_read.to_double(),
        repr=total.cache_read.to_string(),
      ),
    ),
    (
      "cache_write",
      Json::number(
        total.cache_write.to_double(),
        repr=total.cache_write.to_string(),
      ),
    ),
    // Session reasoning tokens. Absent from a provider that does not report them, so it stays zero
    // rather than becoming a missing field: a total of nothing is zero, which is a fact, and the
    // host draws it as nothing said rather than as nothing measured.
    (
      "reasoning",
      Json::number(
        total.reasoning.to_double(),
        repr=total.reasoning.to_string(),
      ),
    ),
    ("prompt", Json::number(prompt.to_double(), repr=prompt.to_string())),
    // What the next request would carry, which is the prompt figure plus whatever has been added
    // since it was measured. Zero for a conversation with nothing in it — see `context_facts`.
    (
      "context",
      Json::number(context.tokens.to_double(), repr=context.tokens.to_string()),
    ),
    (
      "context_source",
      Json::string(
        if context.provider_measured {
          "provider"
        } else {
          "estimated"
        },
      ),
    ),
    (
      "overhead",
      Json::number(
        context.overhead.to_double(),
        repr=context.overhead.to_string(),
      ),
    ),
    (
      "window",
      Json::number(context.window.to_double(), repr=context.window.to_string()),
    ),
    ("compact_soon", Json::boolean(context.compact_soon)),
    ("cost", Json::string(@core.format_cost(total.cost.total))),
    ("cost_input", Json::string(@core.format_cost(total.cost.input))),
    ("cost_output", Json::string(@core.format_cost(total.cost.output))),
    ("cost_cache_read", Json::string(@core.format_cost(total.cost.cache_read))),
    (
      "cost_cache_write",
      Json::string(@core.format_cost(total.cost.cache_write)),
    ),
  ]
  match @core.format_cache_hit_percent(total.cache_read, total.billed_input()) {
    Some(percent) => fields.push(("cache_hit", Json::string(percent)))
    None => ()
  }
  if last.present {
    fields.push(
      (
        "last_model_calls",
        Json::number(
          last.model_calls.to_double(),
          repr=last.model_calls.to_string(),
        ),
      ),
    )
    fields.push(
      (
        "last_tool_calls",
        Json::number(
          last.tool_calls.to_double(),
          repr=last.tool_calls.to_string(),
        ),
      ),
    )
    fields.push(
      (
        "last_total",
        Json::number(
          last.usage.total_tokens.to_double(),
          repr=last.usage.total_tokens.to_string(),
        ),
      ),
    )
    // The last turn's own cache and reasoning figures, which are what explain the two cases a reader
    // notices: a turn that was cheap because its prompt was already cached, and a turn that was
    // expensive without producing much text. Both are left out when they are nothing, the way the
    // session's cache share is: a field that exists only to hold a zero is a field the host has to
    // learn to ignore.
    if last.usage.cache_read > 0 {
      fields.push(
        (
          "last_cache_read",
          Json::number(
            last.usage.cache_read.to_double(),
            repr=last.usage.cache_read.to_string(),
          ),
        ),
      )
    }
    match last.usage.reasoning {
      Some(reasoning) if reasoning > 0 =>
        fields.push(
          (
            "last_reasoning",
            Json::number(reasoning.to_double(), repr=reasoning.to_string()),
          ),
        )
      _ => ()
    }
    fields.push(
      (
        "last_input",
        Json::number(
          last.usage.input.to_double(),
          repr=last.usage.input.to_string(),
        ),
      ),
    )
    fields.push(
      (
        "last_output",
        Json::number(
          last.usage.output.to_double(),
          repr=last.usage.output.to_string(),
        ),
      ),
    )
    fields.push(("last_cost", Json::string(@core.format_cost(last.cost))))
  }
  session_event(path, "usage", fields)
}

// ── one turn ───────────────────────────────────────────────────────────────

///|
/// The name one row of a turn's stream carries.
///
/// Unique for the whole session, not merely within the turn, and that is the whole point: the host
/// appends a delta to *the row with this id*, so a second turn that named its first block `reply-1`
/// would have its text written into the first turn's row — the previous answer growing, the new one
/// never appearing as a row of its own, and the tool rows overwritten in place. Measured, not
/// imagined: that is what "the thinking and the tools disappear when I send the next prompt" was.
///
/// The web UI names its live blocks the same way (`stream-<turn>-<seq>`, `live-tool-<turn>-<seq>`),
/// for the same reason, and this is that rule with the document taken out.
fn row_id(kind : String, turn : Int, seq : Int) -> String {
  "\{kind}-\{turn}-\{seq}"
}

///|
/// What the line under the composer says between model calls: the turn is waiting on the model.
///
/// A named constant rather than a literal in two places, because two places is enough for them to
/// drift: the turn says it when it starts, and it is what a retry restores before any counts have
/// been reported.
let thinking_status : String = "thinking…"

///|
/// What the line says while a model call is waiting to be tried again.
///
/// A retry is the one stretch of a turn with nothing else to watch: the model has not answered, no
/// tool has run, and the counts have not moved. That silence is what a reader reads as a program
/// that has stopped working, and this is the sentence that fills it.
///
/// `None` is what the driver sends when the call comes back, and `restore` is the line the caller was
/// showing before: the pair is one fact about one line, which is why it is one function rather than
/// two. The line to put back is the caller's to know — it is the counts, written from the progress
/// reports — and it is passed rather than assumed, because restoring a thinner line than the reader
/// was watching would take the numbers away at the moment they are deciding whether to keep waiting.
fn retry_status(attempt : @agent.RetryAttempt?, restore : String) -> String {
  match attempt {
    Some(pending) =>
      "no answer — retrying (\{pending.next} of \{pending.total})"
    None => restore
  }
}

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
/// Run one prompt to completion, and say everything that happened.
///
/// The shape is the web UI's `run_turn` with the document taken out. What is left is the part that
/// was never about HTML: build the request from the session's own model and the process's settings,
/// stream, and report.
///
/// `open` is the session this turn belongs to, and it is a parameter rather than `self.shown()` for the
/// reason this whole refactor exists: the reader can switch away mid-answer, send somewhere else, and
/// come back — so a turn has to write *its* session and not "the one on screen". Every emission below
/// One line per turn saying how far each request had to be re-billed, when somebody asked for it.
///
/// The figure a turn reports cannot say what it cost to *send*: a request that is the previous one
/// plus a tail is read from cache almost entirely, and the same request with one message rewritten
/// in the middle is nearly all fresh input at fifty times the price. The turn's own `request_drift`
/// knows the difference, and until this existed nothing outside a test ever saw it -- including the
/// seam between two turns, which is where the trim boundary most often moves and therefore where the
/// expensive rewrites live.
///
/// Written to the same file `WEI_DEBUG` names for `WeiKit.WireLog`, so one variable turns on both
/// halves of a session's evidence, and off unless asked for. One JSON object per line so it can be
/// collected and read back later; a reader of the transcript is never shown it, because a boundary
/// moving is ordinary and a line on every turn would be noise.
async fn Shell::log_drift(
  self : Shell,
  path : String,
  finished : @agent.TurnResult,
) -> Unit {
  if self.debug_log == "" {
    return
  }
  let first : Json = match finished.request_drift {
    [] => Json::null()
    [drift, ..] =>
      Json::object(
        Map([
          ("comparable", Json::boolean(drift.comparable)),
          ("within_turn", Json::boolean(drift.within_turn)),
          ("messages", Json::number(drift.messages.to_double())),
          ("bytes", Json::number(drift.bytes.to_double())),
          ("first_changed", Json::number(drift.first_changed.to_double())),
          (
            "previous_messages",
            Json::number(drift.previous_messages.to_double()),
          ),
          ("changed_bytes", Json::number(drift.changed_bytes.to_double())),
        ]),
      )
  }
  // The worst rewrite of the turn as well, because "the first request was clean" and "nothing in
  // this turn was rewritten" are different answers and only the pair tells them apart.
  let mut worst = 0
  let mut comparable = 0
  for drift in finished.request_drift {
    if drift.changed_bytes > worst {
      worst = drift.changed_bytes
    }
    if drift.comparable {
      comparable += 1
    }
  }
  let line : Json = Json::object(
    Map([
      ("session", Json::string(path)),
      ("at", Json::number(@env.now().reinterpret_as_int64().to_double())),
      ("model_calls", Json::number(finished.model_calls.to_double())),
      ("comparable", Json::number(comparable.to_double())),
      ("worst_changed_bytes", Json::number(worst.to_double())),
      ("first", first),
    ]),
  )
  @platform.append_text(self.debug_log, line.stringify() + "\n") catch {
    _ => ()
  }
}

///|
/// carries `open.path` so the host can file it under the right transcript.
async fn Shell::run_turn(
  self : Shell,
  open : Open,
  prompt : String,
  continuing? : Bool = false,
) -> Unit {
  open.aborting.val = false
  // Before the first `await`, so that a command arriving during the turn sees it set. The sidebar
  // reads this: it is how a row gets its spinner.
  open.busy = true
  // Cleared by `defer` rather than at the end, and the reason it is a `defer` at all is that the turn
  // can leave by raising: `run_turn` catches its own failure, but a cancellation — the process being
  // asked to quit mid-answer — comes out of it as one. `defer` takes a value and MoonBit has no
  // assignment expression, so the flag is cleared by a closure.
  defer clear_busy(open)
  // A handle from this turn must not outlive it: the next turn's tools are different tools, and a stale one
  // would let Stop cancel work that belongs to a reader's *next* question.
  defer clear_running_tool(open)
  let path = open.path
  // A named skill becomes its own text here, before anything is echoed or written down.
  //
  // Before, because what the model is sent and what the log records have to be the same text: a
  // transcript that showed `/skill:moonbit do X` while the log held a skill block would read one way
  // while the turn ran and another way after a restart, which is the mismatch this file keeps
  // refusing to create anywhere else.
  //
  // Not for a continued turn. That prompt is read back out of the log, where it was already expanded
  // when it was first sent — expanding it again would look for a `/skill:` command in a skill block
  // and, finding none, leave the text alone for the wrong reason.
  let sent = if continuing {
    prompt
  } else {
    match self.expand_skill(open, prompt) {
      Some(expanded) => expanded
      None => prompt
    }
  }
  // The pictures go with the prompt and are taken off the composer here, before the first `await`:
  // they are part of the question being asked, and a reader who sends while the request is going out
  // must not send the same screenshot twice.
  let images : Array[@core.Content] = []
  for attachment in open.attached {
    images.push(
      @core.Content::Image(data=attachment.data, mime_type=attachment.mime_type),
    )
  }
  // Echoed from the same list the request is built from, and echoed here rather than after the
  // clearing below — this is the last moment the turn's pictures exist as a list. The ordering is the
  // point: a host that drew them from `say_images`, which follows, would be drawing a composer that
  // has already been emptied.
  self.say_user(
    path,
    sent,
    continued=continuing,
    images=attached_images(open.attached),
  )
  self.say_status(path, thinking_status)
  open.attached = []
  self.say_images(open)
  let mode = self.settings.tool_mode
  // The session's model, not the process's: this is the one line that makes a resumed session's
  // recorded choice mean anything. Its pricing and window come from the same catalog entry, so a
  // turn cannot be billed at one model's rates while calling another.
  let spec = @core.model_spec_for(open.model_id).0
  let tools = @core.tools_for_mode(mode)
  let context = @agent.AgentContext::new(
    session=open.session,
    session_path=path,
    cwd=open.cwd,
    api_key=self.api_key(),
    // The same function the context figure calls, rather than a second assembly of the same
    // sections: a turn that sent a prompt the estimate did not describe would make the size on the
    // bar a figure about a request nobody sends.
    system_prompt=self.system_prompt(open, tools),
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
  //
  // Bumped before anything is named, so that this turn's names cannot be last turn's. The sequences
  // below start at one again, which is exactly why they have to be paired with a turn: `reply-1` is
  // a name two turns would otherwise both choose.
  //
  // Counted per *session*, so two conversations both streaming their first answer both name it
  // `reply-1-1`. That is safe as long as a replay of one can never land in the other's transcript —
  // which is what the `session` on every one of these events is for, and why it is not optional.
  open.turn += 1
  let turn = open.turn
  let mut piece_id = ""
  let mut piece_seq = 0
  let mut piece_kind = ""
  // The text of the block that is still arriving, accumulated from the deltas so that its parse can
  // be sent the moment it stops. A `StringBuilder` rather than `+`: a long answer arrives in hundreds
  // of frames, and repeated concatenation is the quadratic this path exists to avoid.
  let piece_text = StringBuilder()
  // How much text the open block has, counted here rather than asked of the buffer: the two gates on
  // a live frame are about how much has arrived, and reading that off a `StringBuilder` means
  // building the string first.
  let mut piece_length = 0
  // The open block is over: send its parse, and start the next one empty. Called where a block stops
  // being the newest thing that happened — a tool, the other kind of text, or the end of the turn —
  // which are exactly the moments the host stops appending to that row.
  let close_piece = () => {
    // Only the kinds the host draws as markdown: see `draws_markdown`. A finished reasoning block
    // still crosses as text — that is what the peek draws — and the parse it would have carried was
    // the largest single thing on this wire.
    if draws_markdown(piece_kind) {
      self.say_blocks(path, piece_id, piece_text.to_string(), open.live)
    }
    open.live = None
    piece_text.reset()
    piece_length = 0
    piece_kind = ""
  }
  // A tool is one row from start to finish, so the id is chosen when it starts and reused when it
  // reports. The report does not carry the id the start did — it carries the model's `call_id`,
  // which the running handle never had — so the pairing has to be kept here.
  let mut tool_seq = 0
  let mut open_tool : String? = None
  // Bumped by a tool, so the answer that follows one is a new block rather than more text on the
  // block from before the tool call.
  let new_piece = (kind : String) => {
    // Before the id moves: whatever was arriving is finished, and this is the last moment its text is
    // still here.
    close_piece()
    piece_seq += 1
    piece_id = row_id(kind, turn, piece_seq)
    piece_kind = kind
    // A new block is a new parse. The host's row for this id starts with no blocks, so the state has
    // to start with none sent — keeping the previous block's would make the first frame a suffix of
    // a document the host never got the head of.
    //
    // **Only the answer gets one.** Reasoning is drawn as plain text by design, so a live parse of it
    // would be work nobody draws — and `close_piece` reads this back to decide what to diff, so a
    // state for a block that sent nothing live would be a diff against a document the host never got.
    open.live = if kind == "reply" {
      Some({ id: piece_id, sent: [], at_length: 0, at_ms: @env.now(), })
    } else {
      None
    }
    piece_id
  }
  let on_delta : async (@core.StreamEvent) -> Unit = delta => {
    let (kind, text) = match delta {
      @core.Text(delta~) => ("reply", delta)
      @core.Thinking(delta~) => ("thinking", delta)
    }
    let id = if piece_kind == kind { piece_id } else { new_piece(kind) }
    piece_text.write_string(text)
    piece_length += text.length()
    self.say_piece(path, kind, id, text)
    // **Only the answer is rendered live.** Reasoning is drawn on the host as plain text by design —
    // three lines of its tail while it arrives, a summary line once it stops — so a parse of it would
    // be work nobody draws: the reasoning frames were a third of the live traffic in a measured run.
    // Its *finished* parse still goes out, once, because that is the row's record of how to draw
    // itself; see `close_piece`.
    if kind == "reply" {
      self.live_blocks(path, open, piece_text, piece_length, @env.now())
    }
  }
  let on_tool_process : async (@agent.ToolHandle?) -> Unit = handle => {
    // **The handle is kept, not just drawn.** It is the only thing that can stop the command the reader is
    // watching, and `Abort` reads it — see `running_tool`. Set before the row goes out, so a stop that
    // arrives while the row is being drawn still finds it.
    open.running_tool = handle
    match handle {
      Some(running) => {
        tool_seq += 1
        let id = row_id("tool", turn, tool_seq)
        open_tool = Some(id)
        // The next text belongs to a new block. This is the moment the previous one stopped being
        // the newest thing that happened, so this is where its parse goes out.
        close_piece()
        self.say_tool(path, id, running.name, running.detail, false, "", false)
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
        row_id("tool", turn, tool_seq)
      }
    }
    open_tool = None
    self.say_tool(
      path,
      id,
      report.name,
      "",
      true,
      report.output,
      report.is_error,
    )
  }
  // The counts are the cheapest possible "still alive" signal, and the one a reader watches when a
  // turn is taking minutes.
  //
  // The last one is kept as well as said, because a retry has to put *something* back and the counts
  // are the most informative thing to put back — the reader who was watching "3 model call(s)" is the
  // reader deciding whether to keep waiting.
  let mut progress_line = thinking_status
  let on_progress : async (Int, Int) -> Unit = (calls, tools_done) => {
    progress_line = "working… \{calls} model call(s), \{tools_done} tool call(s)"
    self.say_status(path, progress_line)
  }
  // Every commit, not just the end of the turn: this is what makes a cost figure move while the
  // turn runs, because each model call's numbers are in the log the moment the response ends.
  //
  // The same callback is where a compaction becomes visible. It happens inside a model call, between
  // two deltas, and the reader is told by a row in the conversation — at the point where their own
  // words stopped being what the model was sent. `compactions` counted rather than a flag, because a
  // long turn can compact twice and a flag would report the first and swallow the second.
  let mut compactions = compaction_state(open.session).0
  let on_commit : async (@core.Session) -> Unit = committed => {
    open.session = committed
    let (count, summary) = compaction_state(committed)
    if count > compactions {
      compactions = count
      self.say_note(path, summary, "context compacted")
    }
  }
  let limits = @core.choose_limits(None, None, None, self.settings)
  let started = @env.now().reinterpret_as_int64()
  let finished = @agent.run_turn(
    context,
    sent,
    started,
    thinking_level=open.think_level,
    max_rounds=limits.max_rounds.value.to_int(),
    max_cost=limits.max_cost.value,
    max_seconds=limits.max_seconds.value.to_int(),
    // Never `continuing`, and the reason is the sentence this shell is built on: the reader types a
    // prompt, and a prompt is a new turn. Inferring it from the log — "the session has a turn open,
    // so this must be a resume" — has no way to tell an interrupted turn the reader wants to continue
    // from one they have moved on from, and it guessed wrong in the worst direction: after a turn
    // failed on a network error, the log kept its open turn, the next prompt was read as a resume,
    // and the reader's words were never sent at all. Measured, not imagined: typed text appeared
    // nowhere in the request.
    //
    // A new turn closes whatever was open as abandoned, which is what the web UI does when a reader
    // ignores the interrupted-turn notice and simply types. Continuing is offered there as a button
    // and belongs here as one too, if it is wanted — a decision the reader makes, not one the shell
    // makes for them.
    continuing~,
    // The last request this session sent, so this turn's first one is measured against it rather
    // than against nothing. `None` for a session that has not sent one yet.
    previous_request=if open.previous_request.is_empty() {
      None
    } else {
      Some(open.previous_request)
    },
    prompt_images=images,
    on_delta~,
    should_stop=() => open.aborting.val,
    on_tool~,
    on_tool_process~,
    on_progress~,
    // The status line while a call is being retried, and the line it goes back to when the answer
    // lands: the driver passes `None` for the second half, so this one callback is the whole
    // exchange rather than an event and a matching clean-up event.
    on_retry=attempt => {
      self.say_status(path, retry_status(attempt, progress_line))
    },
    on_commit~,
  ) catch {
    err => {
      // The block that was arriving stopped here, mid-sentence. Its parse still goes out: a turn that
      // failed partway through is exactly when a reader reads back what the model had said, and
      // plain text with a table in it is where a half-answer looks broken rather than cut short.
      close_piece()
      // Named, because a turn that fails in the background is a turn nobody is watching: the message
      // says which conversation it was about, or the reader sees a failure on screen that happened
      // somewhere else.
      self.say_error("the turn failed: \{@core.error_text(err)}", session=path)
      self.say_status(path, "failed")
      // The spend still moved — a request that was refused, or a stream that died halfway, was paid
      // for — so the totals are re-sent. `last_turn` is deliberately not updated: a turn that did not
      // finish has no figures of its own to report, and describing half a turn as the last one would
      // be the one place this line lies.
      self.say_usage(open)
      // A turn that failed is one the reader can still carry on: the log keeps it open, so the work it
      // did is in front of the model and `continue` re-sends the question it had been asked. The notice
      // that asks the reader to choose goes out **now**, with the error, rather than at the next switch
      // — a notice that arrives ten minutes later, when the reader has moved on, is a notice that
      // arrives for no reason.
      //
      // `busy` is cleared by hand first: the line below answers "is anything running this turn", and
      // the `defer` that would otherwise have cleared the flag has not run yet.
      clear_busy(open)
      self.say_turn_ended(open, "failed")
      return
    }
  }
  open.session = finished.session
  // Kept for the next turn's first request to be measured against. This is the write that makes the
  // seam between turns visible: without it every turn's first request is incomparable, and that is
  // where the trim boundary most often moves.
  open.previous_request = finished.last_request
  self.log_drift(path, finished)
  // The last block of the turn, which no tool and no new block ever closed.
  close_piece()
  // Kept for the line under the composer, and sent as part of the usage snapshot: what this turn
  // cost is a fact about a turn that is now over, and the next one will replace it.
  open.last_turn = {
    usage: finished.usage,
    model_calls: finished.model_calls,
    tool_calls: finished.tool_calls,
    cost: finished.usage.cost.total,
    present: true,
  }
  let aborted = open.aborting.val
  self.say_end(
    path,
    ending_text(finished, aborted),
    finished.model_calls,
    finished.tool_calls,
    finished.usage.cost.total,
  )
  self.say_usage(open)
  // The turn is closed in the log, so the snapshot the host is drawing from is out of date — and it
  // is out of date in the direction of a decision that no longer exists. `say_turn_ended` sends that
  // snapshot when the reader is watching this session, and a notice-banner fact when they are not:
  // a turn that ends in a conversation nobody has open is exactly the case that used to move the
  // window, and it is now the case the window is told about without being moved.
  self.say_turn_ended(open, if aborted { "stopped" } else { "finished" })
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

// ── skills ─────────────────────────────────────────────────────────────────
//
// upstream's `/skill:<name>`: the reader naming a skill rather than hoping the model picks it. The catalog
// in the system prompt tells the model what exists; this is the same text arriving because the
// *reader* decided it was relevant, which matters when a one-line description is not enough to
// persuade anyone.
//
// The syntax, the expansion and the framing are `core`'s and `platform`'s, shared with the web UI
// and tested there. What is here is only who decides to call them.

///|
/// The skills of a session's working directory, discovering them once per directory.
///
/// Keyed by directory rather than by session, because it is a fact about a *project*: two sessions open
/// in one repository must see the same skills, and discovering them twice would be two scans that could
/// disagree.
async fn Shell::skills_here(self : Shell, cwd : String) -> Array[@core.Skill] {
  match self.skills.get(cwd) {
    Some(cached) => return cached
    None => ()
  }
  let found = @platform.discover_skills(cwd, self.home)
  self.skills.set(cwd, found)
  found
}

///|
/// The skills a turn may actually use: discovered, minus the ones switched off.
///
/// Filtered at read time rather than at scan time, so turning one off takes effect on the next turn
/// without a rescan — and so the settings panel, which has to list what is off in order to turn it
/// back on, still sees everything.
async fn Shell::enabled_skills(
  self : Shell,
  cwd : String,
) -> Array[@core.Skill] {
  @core.enabled_skills(self.skills_here(cwd), self.settings.disabled_skills)
}

///|
/// Expand a `/skill:<name>` prompt into the skill's own text, or `None` when the text is not that.
///
/// `None` covers three cases the caller treats identically — not a skill command, no such name, and
/// a file that has since been deleted — and all three send the text on as the reader typed it. That
/// is upstream's behaviour, and it is what keeps a stray `/skill:` from eating a message.
async fn Shell::expand_skill(
  self : Shell,
  open : Open,
  text : String,
) -> String? {
  let (name, args) = match @core.skill_command_parts(text) {
    Some(parts) => parts
    None => return None
  }
  @platform.expand_skill_command(self.enabled_skills(open.cwd), name, args)
}

///|
/// What a bare `/skill` answers with.
///
/// Asked of the *enabled* skills, because the question is "what can I use here" and a name that is
/// switched off would be an answer that does nothing when tried.
fn skill_list_text(skills : Array[@core.Skill]) -> String {
  let out = StringBuilder()
  for skill in @core.dedup_skills(skills) {
    if out.to_string() != "" {
      out.write_string("\n")
    }
    if skill.description == "" {
      out.write_string("/skill:\{skill.name}")
    } else {
      out.write_string("/skill:\{skill.name} — \{skill.description}")
    }
  }
  out.to_string()
}

///|
/// Answer the reader who typed `/skill` on its own: what is here, rather than a turn.
///
/// No turn, and deliberately: the question is about this machine rather than about the conversation,
/// so there is nothing to ask the model and nothing to spend. It lands as a row in the transcript
/// because that is where the reader is looking, and it is labelled so it cannot be taken for an
/// answer somebody gave.
async fn Shell::list_skills(self : Shell, open : Open) -> Unit {
  let skills = self.enabled_skills(open.cwd)
  if skills.length() == 0 {
    self.say_status(
      open.path,
      "no skills here — a skill is a directory with SKILL.md in ~/.wei/skills or .wei/skills",
    )
    return
  }
  self.say_note(open.path, skill_list_text(skills), "skills")
}

// ── the command loop ───────────────────────────────────────────────────────

///|
/// What a command from the host means.
///
/// Bare text is a prompt; the rest are the words a host can say that are not one. Words rather
/// than a protocol because the host is the only caller, and a protocol for a dozen words is a
/// second thing to keep in step with it.
///
/// Paths are not quoted, and the last argument of a path command is always the *last* argument: a
/// session path is a path, and a path with a space in it is a file somebody can have — which is
/// why the path commands are parsed from the end rather than by splitting on every space.
///
/// Nothing here is line-based: the inbox hands over whatever the host sent, so a prompt with
/// newlines in it arrives whole and is sent to the model as one message. Only the first word is
/// ever looked at, which is what keeps a pasted stack trace from being read as a command.
fn command_of(line : String) -> Command {
  match line {
    "abort" => Abort
    "quit" => Quit
    // The four words that are not slash commands, spelled both ways. The host sends the bare word —
    // they are about the process rather than about a session — but a reader driving `wei-cli` by
    // hand writes a slash, and a word that means one thing with one and something else with the other
    // is a word nobody can remember.
    "continue" | "/continue" => ContinueTurn
    "dismiss" | "/dismiss" => DismissTurn
    "/sessions" => ListSessions
    // Bare: the session on screen's directory. With a path: the project the host named, which is what
    // the window's own "New Session" sends — see `Shell::create_in` for why the host is the side that
    // knows it, and `/new-in` for the word that adds a project rather than opening a session.
    "/new" => NewSession("")
    // Forking the session on screen. A bare word with no argument, unlike the path commands below: what
    // it acts on is the session that is already open, and there is nothing a host could usefully name.
    "/fork" => Fork
    "/settings" => ListSettings
    "/key-clear" => ClearKey
    "/attach-clear" => ClearAttachments
    "/usage" => ReportUsage
    "/jobs" => ReportJobs
    // A word without its argument is *not* a prompt. Every one of these was a fall-through once, which
    // meant a mistyped or truncated command was sent to the model as a question — a path command with
    // its path cut off would have been billed for and answered. The empty argument reaches the same
    // handler as a bad one, so what the reader gets is the sentence that says what was missing.
    "/open" => Open("")
    // The transcript's own paging: the id of the oldest row the host already has. A bare word is
    // answered with the same "which argument is missing" sentence as every other path command, because
    // a request to page that says nothing about where from is one the shell cannot guess at.
    "/earlier" => Earlier("")
    "/delete" => Delete("")
    // Two words for the two halves of removing a project: the list forgets it, and the checkbox in the
    // dialog is what decides whether the conversations go with it. Kept apart rather than one command
    // with a flag because they are two different acts — see `Shell::remove_workspace`.
    "/workspace-remove" => WorkspaceRemove("")
    "/workspace-delete" => WorkspaceDelete("")
    // The same act with the other answer to "and the file?": the word is separate rather than a flag
    // inside `/delete`, because the two are two intentions and a reader of a wire log should be able to
    // see which one was asked for. Neither is spelled without its path, for the reason below.
    "/purge" => Purge("")
    "/attach" => Attach("")
    "/attach-temp" => AttachTemp("")
    "/job-kill" => KillJob("")
    "/detach" => Detach("")
    "/new-in" => NewIn("")
    "/restore" => Restore("")
    "/rename" => Rename("", "")
    // `<path> <on|off>`. Two words rather than a bare path that toggles, because the *host* is also
    // the side that draws the menu item: a command that flipped the bit would make the item's label
    // and its effect two readings of the same intent, and a menu item reading "Unpin" while the
    // shell decides to pin is a menu item that lies. `off` is also the word a hand-written line
    // needs to take a pin away.
    "/pin" => SetPinned("", false)
    "/key" => SaveKey("")
    // A word with no argument is *not* a level: the same rule the path commands follow below, so that
    // a truncated `"/think"` (or a reader asking what it means) gets the sentence rather than becoming
    // a prompt — or, worse here, a level that silently resolves to the default.
    "/think" => ReportThink
    "/think off" => Think("off")
    "/limits" => SetLimits("", "", "")
    _ =>
      if line.has_prefix("/model ") {
        Model(line[7:].trim().to_owned())
      } else if line == "/model" {
        ReportModel
      } else if line.has_prefix("/think ") {
        Think(line[7:].trim().to_owned())
      } else if line.has_prefix("/earlier ") {
        Earlier(line[9:].trim().to_owned())
      } else if line.has_prefix("/open ") {
        Open(line[6:].trim().to_owned())
      } else if line.has_prefix("/delete ") {
        Delete(line[8:].trim().to_owned())
      } else if line.has_prefix("/purge ") {
        Purge(line[7:].trim().to_owned())
      } else if line.has_prefix("/workspace-remove ") {
        // The path is the whole command, like `/new-in`: a directory called `my work` is an ordinary
        // thing to have.
        WorkspaceRemove(line[18:].to_owned())
      } else if line.has_prefix("/workspace-delete ") {
        WorkspaceDelete(line[18:].to_owned())
      } else if line.has_prefix("/mode ") {
        SetMode(line[6:].trim().to_owned())
      } else if line.has_prefix("/attach ") {
        // Not trimmed past the leading space: a path is a path, and one that begins or ends with a
        // space is a file somebody can have.
        Attach(line[8:].to_owned())
      } else if line.has_prefix("/attach-temp ") {
        // A path the host minted for one paste, and a word the shell can be trusted with: it deletes
        // the file once the bytes are in hand.
        AttachTemp(line[13:].to_owned())
      } else if line.has_prefix("/detach ") {
        Detach(line[8:].to_owned())
      } else if line.has_prefix("/pin ") {
        let rest = line[5:].trim()
        // Split at the *last* space: a path can contain one — and a store directory derived from a
        // directory called `my work` does — while the word after it is always `on` or `off`.
        match rest.rev_find(" ") {
          Some(at) =>
            SetPinned(rest[:at].trim().to_owned(), rest[at + 1:].trim() == "on")
          None => SetPinned("", false)
        }
      } else if line.has_prefix("/job-kill ") {
        KillJob(line[10:].trim().to_owned())
      } else if line.has_prefix("/new ") {
        // Not trimmed, for the reason `/new-in` gives below: a path is a path. Checked before that one
        // only for clarity — `/new-in` does not have `/new ` as a prefix, because the fifth character
        // is a hyphen rather than the space this looks for.
        NewSession(line[5:].to_owned())
      } else if line.has_prefix("/new-in ") {
        // Not trimmed: a path is a path, and one with a trailing space is a directory somebody can
        // have. The chooser's own trailing separator is the caller's business — `canonical_dir`
        // settles both forms into one path.
        NewIn(line[8:].to_owned())
      } else if line.has_prefix("/restore ") {
        Restore(line[9:].to_owned())
      } else if line.has_prefix("/rename ") {
        // `<path> <name>`, split at the first space after the path: the path cannot contain one in
        // this spelling, and the name is allowed to.
        let rest = line[8:]
        match rest.find(" ") {
          Some(at) => Rename(rest[:at].to_owned(), rest[at + 1:].to_owned())
          None => Rename(rest.to_owned(), "")
        }
      } else if line.has_prefix("/skill ") {
        ToggleSkill(line[7:].trim().to_owned())
      } else if line.has_prefix("/instructions ") {
        // Everything after the word, newlines included: this is a text a reader typed, and the
        // settings file is where its shape is kept.
        SetInstructions(line[14:].to_owned())
      } else if line == "/instructions" {
        SetInstructions("")
      } else if line.has_prefix("/limits ") {
        // Three fields, space separated, each of which may be empty — which is how the panel says
        // "no opinion" about one of them without moving the other two.
        set_limits_from(line[8:].to_owned())
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
/// The three limit fields out of one line of text.
///
/// Missing fields are empty strings, which is what the setter reads as "no opinion": a panel that
/// sends two of the three is telling the shell to clear the third, and that is a decision it can only
/// have made deliberately.
fn set_limits_from(text : String) -> Command {
  let parts = text.trim().split(" ").collect()
  let field = (index : Int) => {
    if index < parts.length() {
      parts[index].to_owned()
    } else {
      ""
    }
  }
  SetLimits(field(0), field(1), field(2))
}

///|
priv enum Command {
  Prompt(String)
  Abort
  Quit
  Model(String)
  ReportModel
  /// How much thinking the next turn asks for. A level name, settled against the session's model.
  Think(String)
  ReportThink
  ListSessions
  /// A new session in one project, named by the host. Empty means the project on screen.
  NewSession(String)
  /// The session on screen, copied into a file of its own. See `Shell::fork`.
  Fork
  /// A new session in a directory the host chose, **and that directory becomes a workspace**: the
  /// marker file is written and the status line says so. The word the folder chooser sends.
  NewIn(String)
  Open(String)
  /// The id of the oldest row the host has, so the page before it can be sent.
  Earlier(String)
  /// Out of the store, and aside on disk — recoverable with `/restore`.
  Delete(String)
  /// A workspace the sidebar should stop listing, with its conversations left on disk.
  WorkspaceRemove(String)
  /// The same, and the conversations go too. The checkbox in the dialog, on the wire.
  WorkspaceDelete(String)
  /// The same, with the file removed too. The one irreversible command here.
  Purge(String)
  ListSettings
  SaveKey(String)
  ClearKey
  SetMode(String)
  Attach(String)
  /// The same, for a file the host created and the shell should delete.
  AttachTemp(String)
  Detach(String)
  ClearAttachments
  ReportUsage
  /// Carry on the turn that is open in the log, using the prompt it was already asked.
  ContinueTurn
  /// Close that turn without resuming it.
  DismissTurn
  /// `<path> <name>`; an empty name clears it.
  Rename(String, String)
  /// `<path> <on>`; pinning or unpinning one session.
  SetPinned(String, Bool)
  /// A path a deleted session was renamed away from.
  Restore(String)
  ReportJobs
  KillJob(String)
  ToggleSkill(String)
  SetInstructions(String)
  SetLimits(String, String, String)
}

///|
/// Start a turn in one session, on its own task.
///
/// One place, because a turn is started from two: a prompt the reader typed, and the Continue button on
/// an interrupted one. What the two share is the part that is easy to get wrong by writing it twice —
/// the per-session lock is taken *inside* the spawned task (a command loop that blocks here is a command
/// loop that cannot answer `abort`), the switch that was asked for during the turn is carried out after
/// the lock is released, and the sidebar is rebuilt once the session has stopped being written to.
///
/// The lock is the session's own, so this being called twice for two sessions runs the two turns
/// genuinely in parallel. That is the feature: a conversation doing a long `exec` does not hold up the
/// reader's second question, and each has its own stop flag.
async fn[X] Shell::start_turn(
  self : Shell,
  group : @async.TaskGroup[X],
  open : Open,
  text : String,
  continuing? : Bool = false,
) -> Unit {
  // The wall goes here, before anything else happens: before the spinner, before the notice is taken
  // down, and before a request is built. A prompt that cannot be sent must leave no trace — a session
  // marked busy for a turn that never ran is a spinner with nothing behind it, and the log's own
  // interrupted-turn bookkeeping is about turns that were actually attempted. See `turn_refusal`.
  match turn_refusal(self.api_key()) {
    Some(reason) => {
      // About *this* session, and left as an error rather than a status: the status line is where the
      // host draws the standing wall with its way out of it, and overwriting that with "failed" would
      // take the door away at exactly the moment the reader needs it.
      self.say_error(reason, session=open.path)
      return
    }
    None => ()
  }
  // Set here as well as in `run_turn`, and the reason is the sidebar: `busy` is drawn as a spinner on
  // this session's row, and the list is only sent where something changes. A turn that set its own flag
  // and said nothing would leave the row looking idle for the whole of a ten-minute answer — found by
  // looking at the window while a turn ran, and it looked exactly like the feature not existing.
  open.busy = true
  self.say_sessions()
  // And the notice above this transcript goes with them. Starting a turn *is* the reader's answer to
  // that notice — a prompt typed while it is on screen is a decision to move on — and the host has to
  // hear it when it happens, or it draws a question that has already been answered, next to two
  // buttons that cannot be pressed while this session runs.
  //
  // About the session on screen by construction: `start_turn` is called from the command loop, which
  // is blocked on `self.shown()` — and the sender checks the same thing from its own side, so a future
  // caller cannot make the window jump by being wrong about it here.
  self.say_session(open)
  group.spawn_bg(
    () => {
      open.turns.acquire()
      defer open.turns.release()
      self.run_turn(open, text, continuing~)
      // After the lock, not inside the turn: the label of a session nobody has asked anything in yet
      // is written by its first entry, and the list is what says so — and the spinner this just put on
      // the row is taken off here.
      self.say_sessions()
    },
    no_wait=true,
  )
}

///|
/// Why a turn cannot be sent, or `None` when it can.
///
/// **Asked before the request, not after it.** With no key, a prompt used to go to the endpoint and
/// come back as `HTTP 401: Authentication Fails (auth header format should be Bearer sk-...)` — a
/// round trip, a log entry and a provider's protocol jargon, spent to learn something this process
/// already knew. Measured on a first run: that was the very first thing a reader who typed one
/// sentence saw.
///
/// The key is re-resolved per turn rather than cached (see `Shell::api_key`), so saving one in the
/// panel makes the next turn work without a restart — and this refusal is read in the same place, so
/// it stops applying at the same moment.
///
/// One sentence for every front end. It names the door that exists in the app and the web UI (both
/// have a settings panel) and says nothing about a terminal, which has no panel but also no wall: a
/// reader there has `DEEPSEEK_API_KEY` or the `/key` command, and either one is already in their hands
/// — a sentence about environment variables in a window is not.
fn turn_refusal(api_key : String) -> String? {
  if api_key == "" {
    Some("no API key — add one in Settings")
  } else {
    None
  }
}

///|
/// What a command needs before it may run, given the session on screen.
///
/// **A value rather than a predicate, and that is the whole of it.** This used to be
/// `Shell::idle() -> Bool`, which answered the question *and* said the refusal — so asking it had a
/// side effect, which is why its own doc comment had drifted: it claimed to guard "deleting it,
/// renaming it, opening a fresh one in its place", while three of those had since been un-gated on
/// purpose and each arm carried a paragraph explaining why. A rule expressed by the *absence* of a
/// call inside thirty-six match arms is a rule nobody can read, and one that had already been wrong
/// twice — which is what those paragraphs are.
///
/// So the rule is one table, and the caller says the sentence.
priv enum Gate {
  Allowed
  /// Refused, and this is the sentence that says which one thing would change it.
  Refused(String)
} derive(Eq, Debug)

///|
/// `Gate` and `Keep` are both derived `Eq`/`Debug` for `app_wbtest.mbt` alone, so `moon check`
/// reports those four impls as `unused_value`. That warning is wrong here: dropping the derives
/// breaks the whitebox build (eighteen `does not implement trait` errors). Leave them on.

///|
/// Which commands may run while the session on screen has a turn in flight.
///
/// One turn at a time *per session*, which is what the session's own lock is for: a turn owns its
/// file while it runs, so two turns in one conversation would fork it. What this decides is the
/// commands that would decide something *about* that turn.
///
/// **Exhaustive on purpose.** A new command has to be classified here before it compiles, which is
/// the point: the answer for the other thirty-four is `Allowed`, and the reason is one of three —
/// they name a target of their own (`Delete`, `Rename`, `WorkspaceDelete` all carry a path, so the
/// question "is the session on screen busy" is not the question they are asking); they disturb no
/// file (`Open`, `NewIn`, `NewSession`, `Fork`); or they are about the turn rather than about the
/// file (`Abort` is how a reader stops one, and `Prompt` queues behind the session's lock — a
/// command loop that blocked on a turn could not answer `abort`).
///
/// Deliberately keyed on the session on screen rather than on the whole process: another
/// conversation being busy is not a reason a reader cannot tidy this one up, and refusing there
/// would be the same dead end this shell already removed once from the switch.
fn gate(command : Command, busy : Bool) -> Gate {
  if !busy {
    // Nothing is running, so there is nothing to be refused.
    return Allowed
  }
  match command {
    ContinueTurn | DismissTurn =>
      Refused("a turn is running here — stop it first")
    Prompt(_)
    | Abort
    | Quit
    | Model(_)
    | ReportModel
    | Think(_)
    | ReportThink
    | ListSessions
    | NewSession(_)
    | Fork
    | NewIn(_)
    | Open(_)
    | Earlier(_)
    | Delete(_)
    | Purge(_)
    | WorkspaceRemove(_)
    | WorkspaceDelete(_)
    | ListSettings
    | SaveKey(_)
    | ClearKey
    | SetMode(_)
    | Rename(_, _)
    | SetPinned(_, _)
    | Restore(_)
    | ToggleSkill(_)
    | SetInstructions(_)
    | SetLimits(_, _, _)
    | Attach(_)
    | AttachTemp(_)
    | Detach(_)
    | ClearAttachments
    | ReportUsage
    | ReportJobs
    | KillJob(_) => Allowed
  }
}

///|
/// What handling one line decided about the loop itself.
///
/// `Quit` is the only thing a command can say to the loop. Everything else is a fact for the host,
/// and the loop has nothing to do with it — which is the point of the split: the loop is about the
/// process, and what a command means is not.
priv enum Keep {
  Going
  Quit
} derive(Eq, Debug)

///|
/// One line from the host, decided.
///
/// **The whole of what a command does, behind one call.** This was the body of `serve`'s loop, which
/// made every decision in it reachable only by typing at a running app: thirty-six arms, several of
/// which name a failure mode in their own comments, and none of them assertable. A test now hands in
/// a line and reads what came back — the gate's refusal, a status sentence, the five events switching
/// a model sends.
///
/// Ordered, and the order is the rule: the gate is asked *before* the command, so a refused command
/// leaves no trace other than the sentence saying why.
async fn[X] Shell::handle(
  self : Shell,
  group : @async.TaskGroup[X],
  line : String,
) -> Keep {
  let open = self.shown()
  let command = command_of(line)
  // **The one question asked before anything else**, and it is asked as a value so that the
  // answer and the sentence are not the same call. A refusal is the whole of what the reader
  // gets, so it is said here, once, rather than from inside a predicate that a match arm had to
  // wrap its body in.
  match gate(command, open.busy) {
    Refused(reason) => {
      self.say_error(reason)
      return Going
    }
    Allowed => ()
  }
  match command {
    Prompt(text) =>
      if @core.is_skill_list_command(text) {
        // A question about this machine rather than about the conversation: answered here, with
        // no turn and nothing spent. The alternative — sending `/skill` to the model — is what
        // this did before, and it reads as the model ignoring what was asked.
        self.list_skills(open)
      } else {
        self.start_turn(group, open, text)
      }
    Abort => {
      // Only the session on screen: stopping is something the reader does to the conversation
      // they are looking at, and a global flag would mean that stopping one stopped them all.
      open.aborting.val = true
      // **And the command it is running is stopped now, not at the next step.** The flag is checked
      // between steps and the step in progress is the tool, so with the flag alone a reader who
      // pressed Stop during a two-minute test suite watched it run to the end. Cancelling the task
      // the tool runs in is what reaches the child: the runtime escalates from `SIGTERM` to a kill,
      // and the driver's own cancellation path kills whatever the command had started by pid.
      //
      stop_running_tool(open)
      self.say_status(open.path, "stopping…")
    }
    // Both read the question back out of the log rather than taking one from the host: the
    // interrupted turn is the one that was already asked, and continuing it means asking the
    // same question with the work already done still in front of the model.
    ContinueTurn =>
      match open.session.in_flight_prompt() {
        Some(prompt) => self.start_turn(group, open, prompt, continuing=true)
        // Nothing open: said rather than silently doing nothing, because the host offers
        // this from a notice that its own copy of the session may be out of date about.
        // The snapshot goes out with the sentence so that the stale notice cannot outlive
        // the click: an error that leaves what it is about on the screen reads as a click
        // that did nothing.
        None => {
          self.say_error("nothing to continue: that turn has already ended")
          self.say_session(open)
        }
      }
    DismissTurn => self.dismiss_turn(open)
    ListSessions => self.say_sessions()
    // **Not gated on being idle**, and this is a fix rather than a loosening. The gate was written when
    // a new session replaced the one session the shell held, so starting another *was* destructive to a
    // turn in flight. Since the registry landed, a new session is added alongside the running one and the
    // turn keeps writing its own file — so refusing was a leftover, and the reader's complaint ("it says
    // I have to stop the session first") was the shell turning a safe action into a dead end.
    NewSession(dir) => self.create_in(dir)
    // **Not gated on being idle**, like the two lines around it: a fork writes a new file and
    // leaves the session it copied alone, so a turn running in this one is undisturbed.
    Fork => self.fork()
    // **Not gated on being idle either**, the same correction the line above carries and for the
    // same reason: adding a workspace opens a session alongside the running one rather than in
    // place of it. What the two share is `open_fresh`, and showing another session disturbs no
    // file — which is the whole of what the gate was ever protecting.
    NewIn(path) => self.new_in(path)
    // Not gated on being idle: showing another session disturbs no file, which is the
    // whole of what the gate was ever protecting.
    Open(path) => self.show(path)
    // Not gated on being idle, and not about the session on screen either: paging is a read of
    // the log the host is already drawing, it sends rows for *that* session, and refusing it
    // while a turn runs would mean a reader cannot scroll back through a conversation that is
    // still being written.
    Earlier(before) =>
      if before == "" {
        self.say_error("earlier: no row id")
      } else {
        self.say_earlier(open.path, open.session, before)
      }
    // **Not gated on `idle()`**, and this is the same correction `NewSession` above needed. `idle()`
    // asks about the session *on screen*, but this command names one explicitly — so gating it there
    // refused to delete a quiet conversation because an unrelated one was running, which is exactly
    // the case a reader hits after switching away from a long turn. What must not be deleted is the
    // session being named, and `discard` checks that itself (its turn, its jobs) before it touches
    // the file.
    Delete(path) => self.discard(path, purge=false)
    Purge(path) => self.discard(path, purge=true)
    // Ungated for the same reason, and with the same division of labour: `remove_project` asks
    // about the *project* — every session of it, not the one on screen — because that is the set
    // the row being removed stands for.
    WorkspaceRemove(cwd) => self.remove_project(cwd, delete=false)
    WorkspaceDelete(cwd) => self.remove_project(cwd, delete=true)
    ListSettings => self.say_settings()
    SaveKey(key) => self.save_key(key)
    ClearKey => self.save_key("")
    // Deliberately not gated on being idle: a mode is read when the next request is built, so
    // changing it mid-turn is a decision about the turn after this one — which is allowed, and
    // is exactly when a reader wants it.
    SetMode(name) => self.set_mode(name)
    Rename(path, name) => self.rename(path, name)
    SetPinned(path, pinned) => self.set_pinned(path, pinned)
    Restore(path) => self.restore(path)
    ToggleSkill(name) => self.toggle_skill(name)
    SetInstructions(text) => self.set_instructions(text)
    SetLimits(rounds, cost, seconds) => self.set_limits(rounds, cost, seconds)
    // Attachments are not gated on being idle: they belong to the prompt that has not been
    // sent yet, and a reader attaching a screenshot while a turn runs is doing the one thing
    // they can do while it runs.
    Attach(path) => self.attach(path)
    AttachTemp(path) => self.attach(path, temporary=true)
    Detach(path) => self.detach(path)
    ClearAttachments => self.clear_attachments()
    // Cheap, and the honest answer to "is anything still moving": the popover that shows the
    // figures asks when it opens rather than trusting a line the reader may have read a turn
    // ago.
    ReportUsage => self.say_usage(open)
    ReportJobs => self.say_jobs_now()
    KillJob(id) => self.kill_job(id)
    ReportModel => self.say_status(open.path, model_report(open))
    ReportThink => self.say_status(open.path, think_report(open))
    // Ungated for the reason `SetMode` is: the level is read when the next request is built, so
    // changing it mid-turn is a decision about the turn after this one.
    Think(level) => self.set_think_level(open, level)
    Model(id) => {
      let (_, known) = @core.model_spec_for(id)
      if known {
        retarget(open, id)
        self.say_status(
          open.path,
          "model: \{@core.model_spec_for(id).0.label_with_id()}",
        )
        // The picker fills its tick from this, and the pictures on the composer were judged
        // against the model that was in force when they were attached — so both are said again
        // for the new one.
        self.say_models(open)
        self.say_images(open)
        // And the thinking menu, whose items are this model's levels: a tick left from the old
        // model is a level the new one does not have.
        self.say_think(open)
      } else {
        // Refused rather than accepted, and the reason is what makes it worth a branch: a
        // model this build does not know has no pricing and no context window, so accepting
        // one would bill the turn at the default's rates and silently send the wrong prompt.
        self.say_error(
          "unknown model \{id} · available: \{@core.model_ids().join(", ")}",
          session=open.path,
        )
      }
    }
    Quit => {
      // Every session, not just the one on screen: this is the process shutting down, and a
      // turn left running in a conversation nobody was looking at would keep the runtime's
      // event loop alive after the window closed.
      for each in self.opens {
        each.aborting.val = true
      }
      return Quit
    }
  }
  Going
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
/// it is blocked behind the turn it is meant to stop. Two of them run at once for the same reason:
/// they belong to different sessions, and neither has anything to say about the other.
async fn Shell::serve(self : Shell) -> Unit {
  let choice = resolve_key(self.settings)
  let key_source = match choice {
    Some(c) =>
      match c.source {
        @core.Environment => "DEEPSEEK_API_KEY"
        @core.Saved => "saved"
      }
    None => "missing"
  }
  self.say_ready(self.shown(), key_source)
  // A session that was resumed — by `WEI_SESSION`, or by whatever ran last — has a transcript
  // already, and the host has never seen any of it. The same replay a switch gets, because it is the
  // same situation: a conversation the reader is looking at and the window is not. The call also
  // carries what it has spent, which model it runs on and whether one can be sent a picture — every
  // snapshot the composer's own two lines and its model picker are drawn from.
  self.say_open(self.shown())
  // The list goes out with the first breath rather than when the sidebar asks for it: the window is
  // drawn before this line arrives, and a sidebar that fills in a moment later is a sidebar the
  // reader watches arrive.
  self.say_sessions()
  // And the settings, for the same reason: the panel is drawn from facts, and a panel that has to
  // ask for them shows a spinner whenever the ask is lost — which is exactly what it did, because the
  // settings window builds its content before it is ever shown. Every one of these is a snapshot of
  // what is true now, so none of them should depend on somebody asking.
  self.say_settings()
  // **No sentence about a missing key here**, and that is a correction rather than a gap. There used
  // to be one — `no API key: set DEEPSEEK_API_KEY and reopen` — and it was the first thing a new
  // reader read: a shell telling them to reopen a window they had just opened, in a variable they do
  // not have, to fix something the app has a panel for. `ready` already carries `key: missing`, the
  // host already draws that as the wall under the composer with a way to Settings on it, and a
  // prompt with no key is refused before it costs a request (`turn_refusal`). Saying it three times
  // was saying it once too often.
  // Before the first line: a job recorded by a previous run whose process is gone is marked lost
  // here rather than being reported as running for two seconds.
  self.reconcile_jobs()
  self.say_jobs()
  @async.with_task_group(group => {
    // The process table, on a timer. One reading every two seconds is what makes a job that exits on
    // its own stop being listed as running, and it is also how the panel knows which pids are worth
    // showing — the same cadence and the same reasoning as the web UI's tick.
    ignore(
      group.spawn(() => {
        while true {
          @async.sleep(2000)
          self.observe_processes()
          self.say_jobs()
        }
      }),
    )
    // The one thing that is true of a session being *left*: the label of a conversation nobody has
    // asked anything in yet is written by its first entry, so the list has to be rebuilt after a turn
    // on a session the reader has since walked away from.
    //
    // `spawn_bg` without waiting rather than inside the turn's own task: two turns ending at once
    // would otherwise rebuild the list twice, and the second would be built from a store read while
    // the first one's entries were still being written.
    let mut quit = false
    while !quit {
      let line = take_command()
      if line != "" {
        // **One line in, one decision out.** The body of the loop is `Shell::handle`, so what a
        // command decides is a call a test can make. What stays here is what is genuinely about the
        // process: reading the inbox, waiting, and stopping when told to.
        match self.handle(group, line) {
          Quit => quit = true
          Going => ()
        }
      }
      @async.sleep(POLL_MS)
    }
  })
}

///|
fn model_report(open : Open) -> String {
  let (spec, known) = @core.model_spec_for(open.model_id)
  let current = if known {
    // The id comes along here, which is where it is an answer: this is the sentence a reader gets when
    // they ask the shell what it is about to call, and the string they would type is the answer.
    spec.label_with_id()
  } else {
    // The log names a model this build does not have. Said plainly, because the alternative is a
    // reader wondering why the cost figures look wrong for the model they thought they chose.
    "\{open.model_id} (unknown to this build; running on \{spec.id})"
  }
  "model: \{current} · available: \{@core.model_ids().join(", ")}"
}

///|
/// What thinking level this session is on, said as a sentence.
///
/// The word `/think` answers with, for the reason every other `/…` command exists: the menu next to
/// the composer is one way to ask, and a reader driving the shell by hand is another. It is also how
/// the level is checkable from a terminal — the menu's tick is a host control and says nothing about
/// what the shell would send — and the levels in force are named in the same answer, because the
/// levels are per model: "why can I not pick low here" is answered by the list.
fn think_report(open : Open) -> String {
  let levels = @core.model_spec_for(open.model_id).0.thinking_levels
  "thinking: \{open.think_level} · available: \{levels.offered().join(", ")}"
}

// ── the entry point ────────────────────────────────────────────────────────

///|
/// Start the shell, and say so if it could not start.
async fn start() -> Unit {
  // Before anything can run a command. The tools the agent spawns — `bash`, `script` — inherit this
  // process's environment, and started from Finder that environment is launchd's, which carries no
  // `PATH` beyond the system's: a reader's `moon` is invisible to the agent while working in their
  // terminal. `platform/environment.mbt` has what is asked to fix it and why it is asked rather
  // than guessed.
  @platform.install_login_path()
  let shell = Shell::open() catch {
    err => {
      // The one failure with nowhere to put a sink: this is the process not starting, and there is
      // no shell to hold one yet. The host still has to hear it — it is the only thing that says
      // why the window is empty — so this goes straight to the wire rather than through a shell.
      emit(error_event("", "could not start: \{@core.error_text(err)}"))
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
#export_name("wei_run")
pub fn run() -> Unit {
  @async.run_async_main(start)
}

// ── background jobs ────────────────────────────────────────────────────────
//
// Work that outlived the tool call that started it. The store is `core`'s — ids, pids, statuses, the
// persisted form — and what is here is the two things a host needs: the liveness of the recorded
// processes, and a line on the wire.

///|
/// Look at the process table once, and record what it says.
///
/// One reading serves both questions asked of it this tick: which pids the panel should show, and
/// whether a job whose pids are all gone has finished. Asking twice would be two answers that can
/// disagree — a process can exit between the two calls, and then the panel says "running" while the
/// settle says "exited", which is the shape of bug nobody can reproduce.
async fn Shell::observe_processes(self : Shell) -> Unit {
  let table = @platform.process_table()
  let live : Array[Int] = []
  for entry in table {
    live.push(entry.0)
  }
  self.live_pids = live
  let alive = (pid : Int) => {
    let mut found = false
    for live_pid in self.live_pids {
      if live_pid == pid {
        found = true
      }
    }
    found
  }
  let now = @env.now().reinterpret_as_int64()
  if self.jobs.settle_gone(alive, now~) {
    // Finished jobs are dropped after a while rather than kept: the record of a command that ended
    // ten minutes ago has nothing left to stop, and a store that only grows makes the panel slower
    // the longer the app is open. Ten minutes is long enough that a reader who looked away can still
    // see how something ended.
    ignore(self.jobs.forget_finished(older_than=600_000L, now~))
  }
  self.save_jobs()
}

///|
/// Write the store down, if it has changed.
///
/// Skipped when the bytes are the same, because this runs on a timer: a file rewritten every two
/// seconds is a file that never stops being dirty on disk, for a store that has not moved.
async fn Shell::save_jobs(self : Shell) -> Unit {
  let text = self.jobs.to_json().stringify()
  if text == self.saved_jobs {
    return
  }
  try @platform.save_jobs(self.home, self.jobs) catch {
    err =>
      self.say_error(
        "could not record background jobs: \{@core.error_text(err)}",
      )
  } noraise {
    _ => self.saved_jobs = text
  }
}

///|
/// Mark last run's jobs whose processes are gone, before anything reads the store.
///
/// A job that outlived the process that started it is the case the store exists for, and the
/// process might just as easily have been *this* one: a crash leaves a record of work that is
/// running, and a record of work that is not. Neither is knowable from the file, so the first thing
/// a start does is ask the process table.
async fn Shell::reconcile_jobs(self : Shell) -> Unit {
  let table = @platform.process_table()
  let live : Array[Int] = []
  for entry in table {
    live.push(entry.0)
  }
  self.live_pids = live
  let alive = (pid : Int) => {
    let mut found = false
    for live_pid in self.live_pids {
      if live_pid == pid {
        found = true
      }
    }
    found
  }
  let lost = self.jobs.reconcile(alive, @env.now().reinterpret_as_int64())
  if lost > 0 {
    self.say_status(
      self.current,
      "\{lost} background job(s) from a previous run are gone",
    )
  }
  self.save_jobs()
}

///|
/// Stop a job and everything it started.
///
/// Every pid ever recorded, not the newest: a backgrounded command's shell exits immediately while
/// the child that is the actual work stays, and killing only the last-known pid would leave that
/// child running with nothing pointing at it.
async fn Shell::kill_job(self : Shell, id : String) -> Unit {
  if id == "" {
    self.say_error("kill: no job id")
    self.say_jobs_now()
    return
  }
  let pids = self.jobs.request_stop(id)
  if pids.is_empty() {
    self.say_error("no running job \{id}")
  } else {
    let killed = @platform.kill_pids(pids)
    self.say_status(self.current, "stopped \{id} (\{killed} process(es))")
  }
  self.save_jobs()
  self.say_jobs_now()
}

///|
fn Shell::say_jobs_now(self : Shell) -> Unit {
  self.say_jobs()
}
