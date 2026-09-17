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
}

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
/// A session that has just been opened in this process, with nothing in it yet.
fn Open::new(
  path : String,
  cwd : String,
  model_id : String,
  session : @core.Session,
) -> Open {
  {
    session,
    path,
    cwd,
    model_id,
    turn: 0,
    busy: false,
    turns: @async.Mutex(),
    aborting: { val: false, },
    attached: [],
    last_turn: no_last_turn(),
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
  /// Where sessions live. Kept on the shell rather than looked up per use, because the list, a new
  /// session and the switch that reads one all have to agree about it.
  root : String
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
async fn Shell::open() -> Shell {
  let home = match @env.get_env_var("HOME") {
    Some(value) if value != "" => value
    _ => raise Failure::Failure("HOME is not set")
  }
  let cwd = @platform.current_dir()
  let settings = @platform.load_settings(home)
  let root = store_root(home)
  let (session, path) = open_session(root, working_dir(cwd, home))
  // A resumed session brings its own directory with it: `WEI_SESSION` can name a file written
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
  let opening = Open::new(path, working, session_model(session), session)
  {
    base_url,
    // Read back from the previous run rather than started empty. A job is a *process*, and the whole
    // reason the panel exists is work that outlived the thing that started it — including this
    // program. A store that began empty every launch would forget a `sleep 3600` it left running,
    // with no way to stop it from here.
    jobs: @platform.load_jobs(home),
    settings,
    home,
    root,
    // One session to begin with. The others are opened by switching, and none of them is opened
    // eagerly: a registry that read every session in the store would pay for conversations nobody
    // asked for, which is the same cost the sidebar avoids by describing them instead of reading
    // them.
    opens: [opening],
    current: path,
    labels: Labels::new(),
    live_pids: [],
    saved_jobs: "",
    sent_jobs: "",
    skills: Map([]),
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
fn say_ready(open : Open, key_source : String) -> Unit {
  emit(
    session_event(open.path, "ready", [
      ("model", Json::string(@core.model_spec_for(open.model_id).0.label())),
      ("cwd", Json::string(open.cwd)),
      // Named rather than implied: an empty key is a thing the host has to say out loud, and
      // "where did the key come from" is the question the first failure always raises.
      ("key", Json::string(key_source)),
    ]),
  )
}

///|
/// The prompt, echoed so the host can put it in the conversation without having kept its own
/// copy of what it sent.
fn say_user(path : String, text : String, continued? : Bool = false) -> Unit {
  emit(
    session_event(path, "user", [
      ("text", Json::string(text)),
      // A continued turn carries a prompt the host has already seen: it is the last user message in
      // the log, and appending it again would put the question on screen twice. The flag is what
      // lets the host start a new turn — with a new set of row names — without drawing a second
      // question.
      ("continued", Json::boolean(continued)),
    ]),
  )
}

///|
/// A block of the answer, or of the reasoning, as it streams.
///
/// Deltas under one `id` rather than one string per frame: that is what makes the host's append
/// cheap, and it is the same decision the web UI made when a replacement-per-delta turned out to
/// be quadratic.
fn say_piece(path : String, kind : String, id : String, delta : String) -> Unit {
  emit(
    session_event(path, kind, [
      ("id", Json::string(id)),
      ("delta", Json::string(delta)),
    ]),
  )
}

///|
/// A block that has stopped growing, and how to draw it.
///
/// The parse is sent when the block is over rather than with every delta, and the reason is the one
/// the web UI paid for first: re-parsing a growing block on each frame is quadratic, and 40KB of
/// reasoning arriving 64 characters at a time is the measurement. A row that is still arriving is
/// plain text on the host, which is cheap and always right; this is what it becomes when it stops.
///
/// The shell does the parsing because the host cannot: `AttributedString(markdown:)` takes the source
/// rather than a parse, so a table arrives as its own punctuation and a fenced block loses its
/// language. `md/` is cmark — the same engine the web UI renders with — so both front ends have the
/// same opinion about the same answer, which is the whole reason it is a shared package.
fn say_blocks(path : String, id : String, text : String) -> Unit {
  if id == "" || text == "" {
    return
  }
  emit(
    session_event(path, "blocks", [
      ("id", Json::string(id)),
      ("blocks", @md.blocks_json(text)),
    ]),
  )
}

///|
/// A tool, running or finished, always under the same id so the finished row replaces the running
/// one instead of leaving it behind.
fn say_tool(
  path : String,
  id : String,
  name : String,
  detail : String,
  done : Bool,
  output : String,
  is_error : Bool,
) -> Unit {
  emit(
    session_event(path, "tool", [
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
fn say_status(path : String, text : String) -> Unit {
  emit(session_event(path, "status", [("text", Json::string(text))]))
}

///|
/// A turn is over. `text` is empty when it finished normally — the answer is the report — and
/// otherwise says which guard stopped it, which is the one thing the figures cannot say.
fn say_end(
  path : String,
  text : String,
  calls : Int,
  tools : Int,
  cost : Double,
) -> Unit {
  emit(
    session_event(path, "end", [
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
/// Something went wrong, and which session it went wrong in.
///
/// Defaulted to the session on screen because that is what almost every failure is about: a path the
/// reader picked, a model id they chose, a turn they asked for. The exception is a turn failing, and
/// it passes its own path — a background conversation breaking must not stop the one being watched
/// from being able to send.
fn say_error(text : String, session? : String = "") -> Unit {
  emit(session_event(session, "error", [("text", Json::string(text))]))
}

///|
/// Every model this build can call, and which of them the session is on.
///
/// Sent because the picker is a host control and the catalog is compiled into the shell: a list the
/// host kept of its own would be a second place for the two to disagree about what can be called, and
/// the shell is the one that refuses an id it does not know. The `vision` flag comes along so the
/// picker can say which models can be shown a picture — the reader is the one who has to decide
/// between the model and the screenshot they just attached.
fn say_models(open : Open) -> Unit {
  emit(models_event(open.path, open.model_id))
}

///|
/// The same event, built from the model in force rather than from the shell.
///
/// Split out so the field names can be asserted without a session on disk, the same way the sessions
/// and the usage events are.
fn models_event(path : String, current : String) -> Json {
  let items : Array[Json] = []
  for spec in @core.model_catalog() {
    items.push(
      Json::object(
        Map([
          ("id", Json::string(spec.id)),
          ("label", Json::string(spec.label())),
          ("vision", Json::boolean(spec.vision)),
        ]),
      ),
    )
  }
  session_event(path, "models", [
    ("items", Json::array(items)),
    // The session's own model, which is the log's answer rather than the picker's: a resumed session
    // runs on whatever it recorded, and the picker has to show that rather than the default.
    ("current", Json::string(current)),
  ])
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
fn say_jobs(shell : Shell) -> Unit {
  let json = jobs_event(
    shell.jobs.list(),
    shell.live_pids,
    @env.now().reinterpret_as_int64(),
  )
  // Sent when it changed, and only then. The tick is every two seconds and most of the time nothing
  // is running, so an unconditional send would put thirty identical empty events a minute on the
  // wire and wake the host just as often for a panel that is not on screen. A running job always
  // changes — its age moves — so the update still arrives while there is something to show.
  let text = json.stringify()
  if text == shell.sent_jobs {
    return
  }
  shell.sent_jobs = text
  emit(json)
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
fn say_note(path : String, text : String, label : String) -> Unit {
  emit(
    session_event(path, "note", [
      ("text", Json::string(text)),
      ("name", Json::string(label)),
    ]),
  )
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
fn say_images(open : Open) -> Unit {
  emit(
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
fn say_usage(open : Open) -> Unit {
  emit(
    usage_event(
      open.path,
      open.session.usage(),
      open.session.last_prompt_tokens(),
      @core.model_spec_for(open.model_id).0.context_window,
      open.last_turn,
    ),
  )
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
  window : Int,
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
    ("prompt", Json::number(prompt.to_double(), repr=prompt.to_string())),
    ("window", Json::number(window.to_double(), repr=window.to_string())),
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
  say_user(path, sent, continued=continuing)
  say_status(path, "thinking…")
  // The pictures go with the prompt and are taken off the composer here, before the first `await`:
  // they are part of the question being asked, and a reader who sends while the request is going out
  // must not send the same screenshot twice.
  let images : Array[@core.Content] = []
  for attachment in open.attached {
    images.push(
      @core.Content::Image(data=attachment.data, mime_type=attachment.mime_type),
    )
  }
  open.attached = []
  say_images(open)
  let mode = self.settings.tool_mode
  // The session's model, not the process's: this is the one line that makes a resumed session's
  // recorded choice mean anything. Its pricing and window come from the same catalog entry, so a
  // turn cannot be billed at one model's rates while calling another.
  let spec = @core.model_spec_for(open.model_id).0
  let tools = @core.tools_for_mode(mode)
  let instructions = @core.choose_instructions(
    self.settings,
    @platform.workspace_agents_md(open.cwd),
  )
  let context = @agent.AgentContext::new(
    session=open.session,
    session_path=path,
    cwd=open.cwd,
    api_key=self.api_key(),
    system_prompt=@core.build_system_prompt(open.cwd, tools, mode~, sections=[
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
  // The open block is over: send its parse, and start the next one empty. Called where a block stops
  // being the newest thing that happened — a tool, the other kind of text, or the end of the turn —
  // which are exactly the moments the host stops appending to that row.
  let close_piece = () => {
    say_blocks(path, piece_id, piece_text.to_string())
    piece_text.reset()
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
    piece_id
  }
  let on_delta : async (@core.StreamEvent) -> Unit = delta => {
    let (kind, text) = match delta {
      @core.Text(delta~) => ("reply", delta)
      @core.Thinking(delta~) => ("thinking", delta)
    }
    let id = if piece_kind == kind { piece_id } else { new_piece(kind) }
    piece_text.write_string(text)
    say_piece(path, kind, id, text)
  }
  let on_tool_process : async (@agent.ToolHandle?) -> Unit = handle => {
    match handle {
      Some(running) => {
        tool_seq += 1
        let id = row_id("tool", turn, tool_seq)
        open_tool = Some(id)
        // The next text belongs to a new block. This is the moment the previous one stopped being
        // the newest thing that happened, so this is where its parse goes out.
        close_piece()
        say_tool(path, id, running.name, running.detail, false, "", false)
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
    say_tool(path, id, report.name, "", true, report.output, report.is_error)
  }
  // The counts are the cheapest possible "still alive" signal, and the one a reader watches when a
  // turn is taking minutes — a turn can run nineteen model calls and twenty-five tool calls, and
  // silence for that long reads as a hang.
  let on_progress : async (Int, Int) -> Unit = (calls, tools_done) => {
    say_status(
      path,
      "working… \{calls} model call(s), \{tools_done} tool call(s)",
    )
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
      say_note(path, summary, "context compacted")
    }
  }
  let limits = @core.choose_limits(None, None, None, self.settings)
  let started = @env.now().reinterpret_as_int64()
  let finished = @agent.run_turn(
    context,
    sent,
    started,
    thinking_level="high",
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
    prompt_images=images,
    on_delta~,
    should_stop=() => open.aborting.val,
    on_tool~,
    on_tool_process~,
    on_progress~,
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
      say_error("the turn failed: \{err}", session=path)
      say_status(path, "failed")
      // The spend still moved — a request that was refused, or a stream that died halfway, was paid
      // for — so the totals are re-sent. `last_turn` is deliberately not updated: a turn that did not
      // finish has no figures of its own to report, and describing half a turn as the last one would
      // be the one place this line lies.
      say_usage(open)
      return
    }
  }
  open.session = finished.session
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
  say_end(
    path,
    ending_text(finished, open.aborting.val),
    finished.model_calls,
    finished.tool_calls,
    finished.usage.cost.total,
  )
  say_usage(open)
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
    say_status(
      open.path,
      "no skills here — a skill is a directory with SKILL.md in ~/.wei/skills or .wei/skills",
    )
    return
  }
  say_note(open.path, skill_list_text(skills), "skills")
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
    "/new" => NewSession
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
    "/delete" => Delete("")
    "/attach" => Attach("")
    "/attach-temp" => AttachTemp("")
    "/job-kill" => KillJob("")
    "/detach" => Detach("")
    "/new-in" => NewIn("")
    "/restore" => Restore("")
    "/rename" => Rename("", "")
    "/key" => SaveKey("")
    "/limits" => SetLimits("", "", "")
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
      } else if line.has_prefix("/job-kill ") {
        KillJob(line[10:].trim().to_owned())
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
  ListSessions
  NewSession
  /// A new session in a directory the host chose.
  NewIn(String)
  Open(String)
  Delete(String)
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
  // Set here as well as in `run_turn`, and the reason is the sidebar: `busy` is drawn as a spinner on
  // this session's row, and the list is only sent where something changes. A turn that set its own flag
  // and said nothing would leave the row looking idle for the whole of a ten-minute answer — found by
  // looking at the window while a turn ran, and it looked exactly like the feature not existing.
  open.busy = true
  self.say_sessions()
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
/// Whether the session on screen can be left, replaced or removed, having said so if it cannot.
///
/// One turn at a time *per session*, which is what the lock is for: a turn owns its file while it runs,
/// so two turns in one conversation would fork it. What this guards is the commands that would disturb
/// *that* session — deleting it, renaming it, opening a fresh one in its place.
///
/// Deliberately keyed on the session on screen rather than on the whole process: another conversation
/// being busy is not a reason a reader cannot tidy this one up, and refusing there would be the same
/// dead end this shell already removed once from the switch.
fn Shell::idle(self : Shell) -> Bool {
  if self.shown().busy {
    say_error("a turn is running here — stop it first")
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
  say_ready(self.shown(), key_source)
  // A session that was resumed — by `WEI_SESSION`, or by whatever ran last — has a transcript
  // already, and the host has never seen any of it. The same replay a switch gets, because it is the
  // same situation: a conversation the reader is looking at and the window is not. The call also
  // carries what it has spent, which model it runs on and whether one can be sent a picture — every
  // snapshot the composer's own two lines and its model picker are drawn from.
  say_open(self.shown())
  // The list goes out with the first breath rather than when the sidebar asks for it: the window is
  // drawn before this line arrives, and a sidebar that fills in a moment later is a sidebar the
  // reader watches arrive.
  self.say_sessions()
  // And the settings, for the same reason: the panel is drawn from facts, and a panel that has to
  // ask for them shows a spinner whenever the ask is lost — which is exactly what it did, because the
  // settings window builds its content before it is ever shown. Every one of these is a snapshot of
  // what is true now, so none of them should depend on somebody asking.
  self.say_settings()
  if choice is None {
    say_error("no API key: set DEEPSEEK_API_KEY and reopen")
  }
  // Before the first line: a job recorded by a previous run whose process is gone is marked lost
  // here rather than being reported as running for two seconds.
  self.reconcile_jobs()
  say_jobs(self)
  @async.with_task_group(group => {
    // The process table, on a timer. One reading every two seconds is what makes a job that exits on
    // its own stop being listed as running, and it is also how the panel knows which pids are worth
    // showing — the same cadence and the same reasoning as the web UI's tick.
    ignore(
      group.spawn(() => {
        while true {
          @async.sleep(2000)
          self.observe_processes()
          say_jobs(self)
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
        let open = self.shown()
        match command_of(line) {
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
            say_status(open.path, "stopping…")
          }
          // Both read the question back out of the log rather than taking one from the host: the
          // interrupted turn is the one that was already asked, and continuing it means asking the
          // same question with the work already done still in front of the model.
          ContinueTurn =>
            if self.idle() {
              match open.session.in_flight_prompt() {
                Some(prompt) =>
                  self.start_turn(group, open, prompt, continuing=true)
                // Nothing open: said rather than silently doing nothing, because the host offers
                // this from a notice that its own copy of the session may be out of date about.
                None =>
                  say_error("nothing to continue: that turn has already ended")
              }
            }
          DismissTurn => if self.idle() { dismiss_turn(open) }
          ListSessions => self.say_sessions()
          // **Not gated on being idle**, and this is a fix rather than a loosening. The gate was written when
          // `create` replaced the one session the shell held, so starting another *was* destructive to a turn
          // in flight. Since the registry landed, a new session is added alongside the running one and the
          // turn keeps writing its own file — so refusing was a leftover, and the reader's complaint ("it says
          // I have to stop the session first") was the shell turning a safe action into a dead end.
          NewSession => self.create()
          NewIn(path) => if self.idle() { self.new_in(path) }
          // Not gated on being idle: showing another session disturbs no file, which is the
          // whole of what the gate was ever protecting.
          Open(path) => self.show(path)
          Delete(path) => if self.idle() { self.discard(path) }
          ListSettings => self.say_settings()
          SaveKey(key) => self.save_key(key)
          ClearKey => self.save_key("")
          // Deliberately not gated on being idle: a mode is read when the next request is built, so
          // changing it mid-turn is a decision about the turn after this one — which is allowed, and
          // is exactly when a reader wants it.
          SetMode(name) => self.set_mode(name)
          Rename(path, name) => self.rename(path, name)
          Restore(path) => self.restore(path)
          ToggleSkill(name) => self.toggle_skill(name)
          SetInstructions(text) => self.set_instructions(text)
          SetLimits(rounds, cost, seconds) =>
            self.set_limits(rounds, cost, seconds)
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
          ReportUsage => say_usage(open)
          ReportJobs => self.say_jobs_now()
          KillJob(id) => self.kill_job(id)
          ReportModel => say_status(open.path, model_report(open))
          Model(id) => {
            let (_, known) = @core.model_spec_for(id)
            if known {
              open.model_id = id
              say_status(
                open.path,
                "model: \{@core.model_spec_for(id).0.label()}",
              )
              // The picker fills its tick from this, and the pictures on the composer were judged
              // against the model that was in force when they were attached — so both are said again
              // for the new one.
              say_models(open)
              say_images(open)
            } else {
              // Refused rather than accepted, and the reason is what makes it worth a branch: a
              // model this build does not know has no pricing and no context window, so accepting
              // one would bill the turn at the default's rates and silently send the wrong prompt.
              say_error(
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
            quit = true
          }
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
    spec.label()
  } else {
    // The log names a model this build does not have. Said plainly, because the alternative is a
    // reader wondering why the cost figures look wrong for the model they thought they chose.
    "\{open.model_id} (unknown to this build; running on \{spec.id})"
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
    err => say_error("could not record background jobs: \{err}")
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
    say_status(
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
    say_error("kill: no job id")
    self.say_jobs_now()
    return
  }
  let pids = self.jobs.request_stop(id)
  if pids.is_empty() {
    say_error("no running job \{id}")
  } else {
    let killed = @platform.kill_pids(pids)
    say_status(self.current, "stopped \{id} (\{killed} process(es))")
  }
  self.save_jobs()
  self.say_jobs_now()
}

///|
fn Shell::say_jobs_now(self : Shell) -> Unit {
  say_jobs(self)
}
