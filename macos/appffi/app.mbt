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
///
/// Two files were split out of this one when it passed three thousand lines: `events.mbt` holds the
/// lines the host is told, and `turn.mbt` one turn's worth of work. What is left here is the shell
/// itself — its state, how it starts, what a line from the host means, and the jobs it keeps alive.

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
  /// How heavy this session is, in bytes of the file it was read from — and the number the registry is
  /// bounded by.
  ///
  /// **A session held in memory costs a multiple of its file** (measured: about 2.4x for a real
  /// 2000-turn, 48MB conversation), so "how many sessions may be held" is not a count of sessions but a
  /// budget of bytes. A fresh session nobody has written yet is 0, and a fork is its parent's size.
  mut weight : Int64
  /// When this session was last put on screen, as a counter rather than a wall clock: the only question
  /// asked of it is which held session the reader has gone longest without looking at.
  mut shown_at : Int64
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
    weight: 0L,
    shown_at: 0L,
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
  /// A counter bumped every time a session is put on screen. What "least recently used" is measured in:
  /// a wall clock in here would be read only for comparisons, and a clock that can go backwards (or be
  /// equal twice) is a tie this has to invent an answer for.
  mut ticks : Int64
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
  ignore(self.hold(open))
  self.current = open.path
  self.trim_opens()
}

///|
/// Put a session in the registry **without** putting it on screen, and answer with the one that is now
/// held.
///
/// The distinction exists because two callers want different halves. A switch wants both; a rename of a
/// session the reader is *not* looking at wants only this one -- the log has to be held to be appended
/// to, and moving the window to it would be the sidebar taking the reader somewhere they did not ask to
/// go.
/// **A turn is the one thing an eviction must not cut through.** Every path that starts one sets `busy`
/// (and clears it on the way out), and this is the same flag the sidebar draws its spinner from — so
/// "may this be let go" is asked of the newest fact rather than of a copy taken when it was read in.
fn Shell::hold(self : Shell, open : Open) -> Open {
  self.ticks += 1L
  match self.open_of(open.path) {
    Some(held) => {
      held.shown_at = self.ticks
      held
    }
    None => {
      open.shown_at = self.ticks
      self.opens.push(open)
      open
    }
  }
}

///|
/// How much conversation this process may hold in memory at once.
///
/// **A budget in bytes rather than a count of sessions**, because it is the bytes that hurt: five real
/// 15MB conversations held at once measured **291MB of resident memory** (about 2.4x the files), while a
/// store of ten thousand *small* sessions costs about 3.7KB each. A count would evict the ten thousand
/// for nothing and keep the five that matter.
///
/// 64MB is one long conversation plus everything ordinary around it. The session on screen is never
/// evicted whatever it weighs, so a reader working in a 200MB conversation pays for it and only it --
/// the alternative, refusing to open it, is not a choice anyone asked for.
fn open_budget() -> Int64 {
  64L * 1024L * 1024L
}

///|
/// Let go of sessions the reader is not looking at, until the held ones fit the budget.
///
/// **What this protects is the process, not the disk.** Every session this process has *ever* shown used
/// to stay in `opens` for the life of the window, so a reader who flipped through five long
/// conversations by mistake paid for all five until they quit. Nothing here is lost: the file is the
/// conversation, and switching back re-reads it (a 48MB session: ~350ms, then the same rows).
///
/// Two sessions are never dropped, and both exceptions are about correctness rather than speed:
///
/// - **the one on screen**, which `shown` panics without -- it is the registry's one invariant;
/// - **any session with a turn in flight**, because the turn holds this `Open` and is appending to the
///   log through it. A turn is exactly the thing that must not have its session taken away.
fn Shell::trim_opens(self : Shell) -> Unit {
  let mut total = 0L
  for open in self.opens {
    total += open.weight
  }
  if total <= open_budget() {
    return
  }
  // Oldest first, so the session the reader has gone longest without seeing is the first to go.
  let oldest_first = self.opens.copy()
  oldest_first.sort_by((a, b) => if a.shown_at < b.shown_at { -1 } else { 1 })
  for open in oldest_first {
    if total <= open_budget() {
      break
    }
    if open.path == self.current || open.busy {
      continue
    }
    ignore(self.opens.extract_if(mine => mine.path == open.path))
    total -= open.weight
  }
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
) -> (@core.Session, String, Int64) {
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
      // The bytes it was read from, which is what the registry's budget is spent in. Read here because
      // this is a moment that already read the whole file, and one more stat costs nothing.
      (session, path, @platform.file_size(path))
    }
    _ => {
      // A session nobody has written yet weighs nothing, which is the honest answer: there is nothing
      // in memory either.
      let (session, path) = fresh_session(shell_root, cwd)
      (session, path, 0L)
    }
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
  /// The size of that session's file, or 0 for one that has not been written yet. What the opening
  /// session takes out of the registry's budget (`open_budget`).
  session_bytes : Int64
  /// Where a per-turn diagnostic line goes, when somebody asked for one.
  ///
  /// Read here with the other environment facts, for the reason the whole `World`/`Shell` split
  /// exists: one place reads the world, and everything else is pure. Empty means no line is written,
  /// which is the ordinary case.
  debug_log : String
  /// What a previous run learned about the sessions in this store, or nothing on a first run.
  ///
  /// Read here rather than inside the shell for the reason above — it is a file — and passed on
  /// whole so that `Shell::of` stays a pure function of a value. This is the one field of the world
  /// that is a *cache*: every fact in it can be derived again by reading the session it is about, so
  /// an empty one is a slow launch and never a wrong one.
  facts : Array[@core.SessionFacts]
}

///|
/// Read the world: the environment, the store, the session to open.
///
/// The only part of starting that touches anything, and it is `async` because reading a session is.
/// Everything it returns is a value, so all of starting is: gather, then assemble.
async fn gather() -> World {
  let home = match @platform.home_dir() {
    Some(value) => value
    None => raise Failure::Failure("HOME is not set")
  }
  let cwd = @platform.current_dir()
  let settings = @platform.load_settings(home)
  let root = store_root(home)
  // What a session's directory is when nothing else says: `start_dir` above, with the store's own
  // answer to "where was I".
  let start = start_dir(cwd, last_workspace(root), home)
  let (session, path, session_bytes) = open_session(root, start)
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
    session_bytes,
    // The same variable `WeiKit.WireLog` writes the host's side of the wire to, and read here so
    // that one `WEI_DEBUG` turns on both halves. Off unless asked for, because a log beside the app
    // that fills up unasked is a surprise.
    debug_log: match @env.get_env_var("WEI_DEBUG") {
      Some(value) if value != "" => value
      _ => ""
    },
    // Before the shell exists, because reading it is a file. It costs one bounded read whatever the
    // store looks like, which is the difference between this and reading the store itself.
    facts: @platform.load_facts(home),
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
  opening.weight = world.session_bytes
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
    ticks: 0L,
    labels: Labels::of(world.facts),
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
    // **The rename search the first `sessions` deferred, run where nobody is waiting for it.**
    //
    // It is spawned here rather than awaited because of what it costs and what it is for: proving that
    // a log holds no rename means seeing every byte of it, so a first launch over a large store is
    // minutes of reading — and the window it would be blocking is one that only ever *draws* the first
    // question of each session, which is a 16 KiB read apiece. The list goes out immediately without
    // the names, and the names arrive as this finds them.
    //
    // Before the command loop, so the loop is not competing with it for the one thing both need: the
    // store's directories. `spawn_bg` so the sweep does not hold the task group open — a store that is
    // already known owes nothing, and this returns without touching the disk.
    if self.labels.deferred {
      group.spawn_bg(() => self.sweep_deferred(), no_wait=true)
    }
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
