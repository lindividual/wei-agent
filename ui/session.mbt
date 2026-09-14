///|
/// The state of the UI: what is open, and what each session is doing.
///
/// The two types here are the centre of the package. `Runner` is one open session — its log, its
/// working directory, its model, and the turn in flight — and `App` is everything shared: the
/// store, the hub, the reader's settings, the registry of open sessions.
///
/// Their accessors live here rather than beside their callers, because these are the questions the
/// whole package asks (`app.shown()`, `runner.is_running()`), and a reader looking for "what does
/// this session think it is doing" should find the answer in one place rather than in whichever
/// feature file happens to call it.
///
/// Nothing here renders and nothing here writes to a socket. The one stream it does write is a
/// session's own log, in `Runner::dismiss`, because a state change that has to survive a restart has
/// to be written down. What a reader sees of these decisions is `panels.mbt`, and what a request does
/// about them is `requests.mbt`.

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
  /// Add this directory as a workspace, start a session in it, and display that.
  ///
  /// A job of its own rather than "`New` plus a write at the call site": adding a workspace also
  /// writes to the store, and doing the whole thing inside the queue is what keeps two adds — one
  /// typed, one picked from a dialog — in the order they were made.
  Workspace(String)
} derive(Eq, Debug)

///|
/// What a display change is called in the log.
///
/// On the enum rather than in the worker, so the worker logs and applies without matching twice —
/// and so a job added later cannot be applied without something to print for it.
fn Job::label(self : Job) -> String {
  match self {
    Switch(path) => "switch   \{path}"
    New(dir) => "new      \{dir}"
    Workspace(dir) => "workspace \{dir}"
  }
}

///|
/// A session, and whatever it is doing.
///
/// The turn slot lives here rather than behind one global queue: sessions are independent
/// of each other, and only turns *within* a session have to be ordered.
struct Runner {
  /// The session as it stands. Replaced after each turn with the driver's copy, which
  /// is the one that has the new entries in it.
  ///
  /// During a turn this is deliberately the copy from *before* it: the transcript is rendered from
  /// here, and a transcript that already contained the running turn would draw it twice — once from
  /// the log and once from the live blocks the browser is still writing into. `in_flight_session`
  /// is the other copy, for the readers that want the log as it now stands.
  mut session : @core.Session
  /// The log including the turn that is running, as the last commit left it.
  ///
  /// Set by the driver as the turn writes, and cleared when it ends. The figures under the composer
  /// are
  /// read from here, because each model call's tokens and cache reads are known the moment it
  /// returns and waiting for the turn to end would hide the whole of a twenty-round turn. It is
  /// also the newest copy of the log, which is what a failed turn has to be rendered from — the
  /// driver commits as it goes, so `session` is behind the file by however far the turn got.
  mut in_flight_session : @core.Session?
  /// How many of the newest turns this session's transcript renders.
  ///
  /// Per session, not global: asking to see the start of one long conversation is not asking for
  /// every other one to be re-rendered from its beginning. It also means the window survives
  /// switching away and back, which is what a reader who opened it expects.
  mut depth : Int
  path : String
  /// Which directory this session's tools run in. A property of the session, not of the
  /// process: opening a session moved the agent to where that session lived.
  cwd : String
  /// Which model this session calls. Per session rather than per process, because two sessions
  /// side by side are the reason to want it: a cheap model for the one that is exploring and an
  /// expensive one for the one that matters.
  ///
  /// Mutable, and written through to the session's log as a `model_change` entry, so a restart
  /// finds the same model. Seeded from the log when one is opened (`Runner::new`) — pi derives
  /// this from the session rather than from configuration, and a session that did not record it
  /// would silently come back on whatever the process defaults to.
  mut model_id : String
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
fn Runner::new(
  session : @core.Session,
  path : String,
  fallback_model_id : String,
) -> Runner {
  let cwd = session.header.cwd
  // A session that was last stopped by a guard — or left open by a crash — says so when it is
  // opened again. The transcript alone cannot tell the reader why the writing stopped, and after a
  // restart the status line is the only place left that knows.
  let ending : String? = if session.turn_in_flight() {
    // Stronger than a recorded ending: the turn never wrote one, so the process died inside it.
    // The prompt is the most useful thing to report, because it says what was in flight.
    match session.in_flight_prompt() {
      Some(prompt) if prompt != "" =>
        Some(
          "the last turn was interrupted while working on: \{@html.clip_label(prompt, limit=60)}",
        )
      _ => Some("the last turn was interrupted")
    }
  } else {
    match session.last_turn_ending() {
      Some(ending) =>
        if ending.is_interruption() {
          Some(
            match ending {
              @core.CostLimit => "the last turn stopped at the cost limit"
              @core.TimeLimit => "the last turn stopped at the time limit"
              @core.RoundLimit => "the last turn stopped at the call limit"
              @core.Truncated =>
                "the last reply was cut off at the output limit"
              @core.Stopped => "the last turn was stopped"
              // Abandoned and Completed are both "nothing to warn about": one is a turn the reader
              // chose to leave behind, the other is a turn that finished.
              @core.Abandoned => ""
              @core.Completed => ""
            },
          )
        } else {
          None
        }
      None => None
    }
  }
  // The working directory is not repeated here. It is on the workspace row the reader just clicked,
  // and a temp path with a hash in the middle was most of the line while the part worth reading —
  // how much was opened — was a couple of words at the front.
  let status = match ending {
    Some(why) =>
      if session.entries.length() == 0 {
        "new session"
      } else {
        "opened \{session.context().messages.length()} messages · \{why}"
      }
    None =>
      if session.entries.length() == 0 {
        "new session"
      } else {
        "opened \{session.context().messages.length()} messages"
      }
  }
  // The log has the first word: a session resumed from a file was last run on whatever model it
  // recorded, and starting it on the process default instead would quietly answer its old
  // questions on a different model.
  let recorded = session.context().model.map(recorded => recorded.model_id)
  // A session that recorded nothing is new, and a new session starts on whatever the process was
  // pointed at — `--model`, or the catalog default. The two are different questions (`fallback` is
  // the reader's flag, the catalog default is the build's) and answering them here keeps the
  // precedence in one place.
  {
    depth: transcript_window(),
    session,
    in_flight_session: None,
    path,
    cwd,
    model_id: recorded.unwrap_or(fallback_model_id),
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
/// The newest copy of the log this process holds: the running turn's commits when there are any,
/// the committed session otherwise.
///
/// One function because "which copy" is the thing that is easy to get wrong, and every reader that
/// wants the log as it now stands has to give the same answer: the figures under the composer while
/// a turn runs, and the rendering of a turn that failed half way through.
fn Runner::latest_log(self : Runner) -> @core.Session {
  match self.in_flight_session {
    Some(in_flight) => in_flight
    None => self.session
  }
}

///|
/// Whether this session has work in flight.
fn Runner::is_running(self : Runner) -> Bool {
  self.busy || self.waiting > 0
}

///|
/// Close this session's interrupted turn without running it.
///
/// Through the log rather than only in memory: the notice is derived from what is written down, so
/// a dismissal kept in memory would bring the notice straight back after a restart — which is the
/// one moment it matters.
async fn Runner::dismiss(self : Runner) -> Unit {
  let entry = @core.turn_outcome_entry(
    @core.Abandoned,
    0,
    0.0,
    self.session.leaf_id,
    @env.now().reinterpret_as_int64(),
  )
  @platform.ensure_session(self.path, self.session.header)
  @platform.append_entry(self.path, entry)
  self.session = self.session.add_entries([entry])
  self.status = "closed the interrupted turn"
}

///|
/// The skills discovered for one working directory, or none if they have not been looked for.
///
/// The raw scan, with switched-off skills still in it: the panel has to list what it can turn
/// back on, and filtering at this level would make the file it is describing disappear from the
/// only place that can undo the switch.
fn App::discovered_skills(self : App, cwd : String) -> Array[@core.Skill] {
  match self.skills_by_cwd.get(cwd) {
    Some(skills) => skills
    None => []
  }
}

///|
/// The skills that reach the model for this working directory.
///
/// Filtered at read time rather than at scan time, so switching a skill off takes effect on the
/// next turn without a rescan and a switch back on does not need the file to be found again.
fn App::skills_for(self : App, cwd : String) -> Array[@core.Skill] {
  @core.enabled_skills(
    self.discovered_skills(cwd),
    self.settings.disabled_skills,
  )
}

///|
/// Discover this directory's skills once, and remember them.
///
/// Called before a turn rather than at startup because the roots are cwd-sensitive: a session
/// opened in another repository must see that repository's skills. The cache is what keeps it
/// from being a per-turn walk, and a failure to scan is not an error — a machine with no skill
/// directories still runs turns, it just has no skills.
async fn App::load_skills(self : App, cwd : String) -> Unit {
  match self.skills_by_cwd.get(cwd) {
    Some(_) => ()
    None =>
      self.skills_by_cwd.set(cwd, @platform.discover_skills(cwd, self.home))
  }
}

///|
/// The system prompt a turn in this session will send.
///
/// One function because two places need it and they must agree: the turn that sends it, and the
/// context figure that has to include its size. Building it twice is how the chip would end up
/// describing a prompt that is not the one being sent — and a catalog that changed between the
/// two would make the pressure figure wrong by exactly the change.
///
/// Async because the workspace's `AGENTS.md` is read rather than cached: a reader editing it while
/// the agent works expects the next turn to be the one that picks the edit up. The two callers
/// await the same function, so they still cannot disagree.
///
/// It is read more often than once per turn now that the context figure under the composer is
/// refreshed on every commit of a running turn, which is a handful of stats and one small read —
/// the price of the figure meaning what it says at the moment it is read.
///
/// The instructions come before the catalog, which is the order of specificity: how this workspace
/// wants to work, then what can be asked of it.
async fn App::system_prompt(self : App, runner : Runner) -> String {
  @core.build_system_prompt(runner.cwd, self.tools, sections=[
    self.instructions(runner.cwd).text,
    @core.skill_catalog_prompt(self.skills_for(runner.cwd)),
  ])
}

///|
/// The instructions this workspace will carry, and where they came from.
///
/// One function for the reason the system prompt is one function: the turn that sends the text and
/// the panel that reports where it came from have to be describing the same decision, so both ask
/// it here rather than resolving the two sources separately.
///
/// The file is read on every call, which is once per turn and once per panel render. That is a
/// stat and, when there is something there, one small read — the price of an edit to `AGENTS.md`
/// taking effect on the next turn instead of at the next restart. The saved text comes from memory.
async fn App::instructions(self : App, cwd : String) -> @core.Instructions {
  @core.choose_instructions(self.settings, @platform.workspace_agents_md(cwd))
}

///|
/// What one request costs outside the conversation, in tokens.
///
/// Takes the prompt rather than building it, because the two callers are already async for other
/// reasons and a second read of `AGENTS.md` could see a different file than the one that is sent.
fn App::overhead_tokens(self : App, prompt : String) -> Int {
  @core.request_overhead_tokens(prompt, self.tools)
}

///|
/// Everything the requests need, in one place.
struct App {
  root : String
  /// What a *new* session starts on, from `--model`. Not what a session is using: that is the
  /// session's own choice, in its log, changeable from the picker by the composer.
  default_model_id : String
  base_url : String
  /// The key a turn will send. Mutable because the settings panel can replace it, and a turn
  /// reads it from here rather than from the environment so that "save a key" means the next
  /// turn uses it without a restart.
  mut api_key : String
  /// Where that key came from: what the panel reports, and the difference between "I saved a
  /// key" and "a variable is overruling it".
  mut key_source : String
  /// A fingerprint of the key, never the key itself, for the panel to show.
  mut key_hint : String
  /// `DEEPSEEK_API_KEY` as the process found it at startup, or empty.
  ///
  /// Kept here rather than read per turn, so the precedence — environment, then saved, then pi —
  /// is a pure function of the process's own state and can be tested without an environment.
  env_key : String
  /// pi's credential, read once at startup. The last resort when nothing else is set.
  pi_key : String?
  /// Whether the environment provided a key. Separate from `env_key` only for the panel, which
  /// says so: otherwise "I saved a key and nothing changed" reads as a bug rather than as a
  /// variable that is doing what it says.
  env_key_set : Bool
  /// What the reader has changed: a saved key, and the skills switched off. Kept in memory as
  /// the source the panel renders and written through to `~/.pi-mb/settings.json`.
  mut settings : @core.AppSettings
  /// One writer of the settings file at a time. Two panels open in two tabs is a normal thing to
  /// do, and read-modify-write of one file from two tasks is how the second edit disappears.
  settings_lock : @async.Mutex
  /// The address the page is served on, for the panel to report.
  address : String
  tools : Array[@core.ToolDef]
  /// The limits this process was launched with: `--max-cost` and `--max-rounds`, each `None`
  /// when the flag was not given. Kept as the flags rather than as resolved numbers so that
  /// changing the saved setting re-derives from them, and a flag keeps its precedence.
  flag_max_cost : Double?
  flag_max_rounds : Int?
  /// Longest one turn may take, resolved once at startup. Not part of `Limits` because it has no
  /// saved counterpart: it is a backstop for a hang, not a spending policy, so there is nothing for
  /// the panel to edit and nothing to re-derive when the panel saves.
  max_seconds : Int
  /// The limits a turn will actually run under, and where each came from.
  ///
  /// Mutable because the panel can change the saved value, and read at the top of every turn —
  /// which is what makes "raise the limit" work on the turn after the one it just stopped.
  mut limits : @core.Limits
  hub : @server.Hub
  /// Open sessions, in the order they were opened.
  ///
  /// Mutable because deleting a session takes it out of here: the registry is "what is open", and a
  /// session that is no longer in the store is not open whatever the process remembers about it.
  mut registry : Array[Runner]
  /// Background work, across every session. One store rather than one per session: the question
  /// "what is still running" is asked about the process, and a reader should not have to open
  /// five sessions to answer it.
  jobs : @core.JobStore
  /// Labels already read, so redrawing the sidebar does not re-read every session head.
  labels : LabelCache
  /// The home directory, so skill roots can be resolved without reading the environment
  /// again on every turn.
  home : String
  /// Skills discovered per working directory. Keyed by cwd rather than held once because the
  /// project-local roots depend on it: a session opened in another repository must see that
  /// repository's skills, not the ones found where the server started. Filled on first use and
  /// kept, because a scan reads files and a turn should not pay for it twice.
  skills_by_cwd : Map[String, Array[@core.Skill]]
  /// Pids that existed at the last look, so the job panel can show the processes that are still
  /// there instead of every pid a command was ever seen with. Refreshed with the panel, not inside
  /// it: rendering is pure.
  mut live_pids : Array[Int]
  /// The last job store written to disk, serialized. Compared against before writing, so the
  /// supervisor's periodic check does not rewrite an unchanged file every few seconds — and so
  /// "has anything happened?" is answered by the same comparison that decides the write.
  mut saved_jobs : String
  /// The path of the session being displayed. Shared by every browser: there is one
  /// document, so there is one answer to "what is on screen".
  mut displayed : String
  /// The most recently deleted session, so the sidebar can offer it back.
  ///
  /// One rather than a list. The offer is for the click that just happened, and a stack of them
  /// would be a trash can this sidebar has no other reason to have. It is not persisted either: a
  /// restart is the end of the undo window, because the file is only renamed and a reader who
  /// wants it back days later has the name.
  mut deleted : @html.DeletedNotice?
  /// Workspaces whose session list the reader asked to see past the cap, by working directory.
  ///
  /// One flag per workspace rather than one global toggle: the cap exists so that describing a
  /// store costs a bounded read, and a reader who wants to see everything in one project has not
  /// asked for that in the other nineteen. Kept for the life of the process — there is no gesture
  /// here that means "close this workspace" the way there is in a client that keeps a real tree,
  /// and a list that folds itself back under the reader is worse than one that stays open.
  expanded : Map[String, Bool]
  /// Whether this host can open its folder chooser, decided once at startup.
  ///
  /// On `App` rather than asked per render because it is the same answer for the life of the
  /// process, and because both the sidebar and the chooser route have to give the same one: a
  /// button that is drawn must be a button that works.
  can_pick : Bool
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
  } else if label == "" {
    // A turn that finished normally has nothing to say, so the note about the other session has to
    // stand on its own rather than trailing a separator with nothing in front of it.
    "\{others} other session(s) running"
  } else {
    "\{label} · \{others} other session(s) running"
  }
}

///|
/// The status line the page shows.
fn App::status_line(self : App, shown : Runner) -> String {
  self.label_for(shown, shown.status)
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

///|
/// How many of the newest turns a transcript renders by default.
///
/// Chosen so that an ordinary conversation is not affected at all: the control only appears once a
/// session is longer than this. Measured on a real 14-turn session, the newest six are about a third
/// of the bytes and a third of the nodes — and those two are most of what switching to a session
/// costs. Large enough that a reader working in a session rarely has to press it.
fn transcript_window() -> Int {
  6
}

///|
/// How much one press of "earlier turns" adds.
///
/// Equal to the window, so the sequence is predictable: 6, 12, 18 — each press doubling what was
/// there rather than adding an amount the reader has to add up.
fn transcript_window_step() -> Int {
  6
}

///|
/// The window this session's transcript should render inside.
fn App::depth_of(self : App, runner : Runner) -> Int {
  let _ = self
  runner.depth
}
