///|
/// The session list, switching between sessions, and replaying one into the transcript.
///
/// The web UI's sidebar with the page taken out. What is kept is the part that was never about a
/// document — which sessions exist, what to call them, and what it costs to describe one — and what
/// is dropped is the browser's: folding, the display cap, "load earlier", the undo offer. Each of
/// those is a decision about a page, and the page is the host's now.
///
/// Switching is why half of this exists. The host builds its transcript out of events, and a session
/// it did not watch happen has no events to have received — so the whole of one is sent in a single
/// line, as rows it can draw, and the host never has to know the file format.

///|
/// The id part of a session file name: `…_ab12cd34.jsonl` becomes `ab12cd34`.
///
/// The same string the web UI puts in a sidebar row, and deliberately the same one: a store is read
/// by both front ends, and two ids for one session would be two ways to refer to it.
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
/// The last path component, which is what a reader recognises a project by.
fn workspace_name(cwd : String) -> String {
  let mut name = cwd
  for part in cwd.split("/") {
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
/// What to call a workspace: the name the reader gave it, else the directory it is.
fn workspace_label(stored : @platform.StoredWorkspace) -> String {
  match stored.title {
    Some(title) => title
    None => workspace_name(stored.cwd)
  }
}

///|
/// Facts about a session file that cost a read: what to call it, and what its reader called it.
///
/// Cached by modification time, for the reason the web UI caches them: the list is rebuilt every
/// time a turn ends, and reading every session's head to redraw it made that cost grow with the
/// store.
priv struct Labels {
  entries : Map[String, (Int64, String, String?)]
}

///|
fn Labels::new() -> Labels {
  { entries: Map([]), }
}

///|
/// One session's cached facts, read if the file has changed since they were.
///
/// An empty label is a real answer — a session whose first turn has not been written yet has
/// nothing to call itself — and is cached like any other, because it will change exactly when the
/// file does.
async fn Labels::facts(
  self : Labels,
  path : String,
  modified : Int64,
) -> (String, String?) {
  match self.entries.get(path) {
    Some((at, label, name)) => if at == modified { return (label, name) }
    None => ()
  }
  // Empty for a file that is not there: a session is created before it is written — the first
  // prompt is what puts a line in it — and asking what to call it in that window is asking about a
  // conversation with nothing in it, which is a description rather than a failure.
  let text = @platform.read_text_or_none(path).unwrap_or("")
  let facts : (String, String?) = (
    // The first question is near the top of the file, so the label only needs the beginning.
    @core.session_label(prefix_of(text, 16 * 1024)),
    // The name, on the other hand, only exists if the log holds a rename, and finding that out by
    // parsing the whole file is most of what describing a store costs. A log with no rename has no
    // name to find, so the parse is skipped; `false` is a definite answer.
    if @core.log_has_name_entry(text) {
      session_name_of(text)
    } else {
      None
    },
  )
  self.entries.set(path, (modified, facts.0, facts.1))
  facts
}

///|
/// Forget what was cached about one path.
///
/// The cache is keyed by path and has no other way to learn that the file it describes is somewhere
/// else now, which is what deleting a session does — the file is renamed aside, not removed.
fn Labels::forget(self : Labels, path : String) -> Unit {
  self.entries.remove(path)
}

///|
/// When the cache last saw this path, or 0 when it has not.
///
/// The modification time is otherwise only known to whoever listed the store — the sidebar's own
/// listing, one refresh ago. The offer that says *which* conversation was deleted has a path and
/// nothing else, and a row that is gone cannot be asked for its modification time; asking the cache
/// is what keeps the notice naming the session the way the row that was clicked on did.
fn Labels::modified_of(self : Labels, path : String) -> Int64 {
  match self.entries.get(path) {
    Some((modified, _, _)) => modified
    None => 0L
  }
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
/// The name lives at the end of a log, so finding it means reading the whole file — once per change,
/// since the result is cached. The parse goes through the same entry decoder as everything else, so a
/// name written by upstream is read here too; pattern-matching the JSON would stop working the day a field
/// moves.
fn session_name_of(text : String) -> String? {
  let session = try @core.parse_session_file(text) catch {
    // A file being written while it is read may not parse. `None` is the right answer, and the next
    // refresh asks again.
    _ => return None
  } noraise {
    parsed => parsed
  }
  session.name()
}

///|
/// What a session is called: the reader's own name for it, else the first question, else the id.
///
/// The same rule the web UI's sidebar applies, in the same order, so both front ends name a session
/// the same way — with "New Session" for one that is not on disk at all, which is a session nobody
/// has seen anything of yet.
async fn Shell::label_of(
  self : Shell,
  path : String,
  modified : Int64,
) -> String {
  let (label, name) = self.labels.facts(path, modified)
  match name {
    Some(value) => value
    None =>
      if label != "" {
        label
      } else if @platform.path_exists(path) {
        short_id(path)
      } else {
        "New Session"
      }
  }
}

// ── the list ───────────────────────────────────────────────────────────────

///|
/// One session, as the sidebar draws it.
///
/// `modified` goes over as an integer rather than a date: the host already has a formatter, and one
/// that decides for itself how long ago a session was used is the only one that can be right about
/// it as time passes.
fn session_row(
  path : String,
  label : String,
  modified : Int64,
  current : Bool,
  running : Bool,
) -> Json {
  Json::object(
    Map([
      ("path", Json::string(path)),
      ("id", Json::string(short_id(path))),
      ("label", Json::string(label)),
      (
        "modified",
        Json::number(modified.to_double(), repr=modified.to_string()),
      ),
      ("current", Json::boolean(current)),
      // Read from the registry rather than inferred from "is this the session on screen and is there a
      // turn somewhere": with more than one turn possible, the only truthful source is the session
      // itself, and a row that showed a spinner because *a* turn was running would point at the wrong
      // conversation.
      ("running", Json::boolean(running)),
    ]),
  )
}

///|
/// The `sessions` event, from the groups the store was read into.
///
/// Pure, so the host's decoder can be pinned against the shape without a store on disk — the same
/// reason the other events are functions of their fields rather than of the shell.
fn sessions_event(groups : Array[(String, String, Bool, Array[Json])]) -> Json {
  let workspaces : Array[Json] = []
  for group in groups {
    let (cwd, label, current, rows) = group
    workspaces.push(
      Json::object(
        Map([
          ("cwd", Json::string(cwd)),
          ("label", Json::string(label)),
          ("current", Json::boolean(current)),
          ("sessions", Json::array(rows)),
        ]),
      ),
    )
  }
  event("sessions", [("workspaces", Json::array(workspaces))])
}

///|
/// The store, as the sidebar sees it.
///
/// The session that is open is included even when it is not in the store yet, under the workspace it
/// belongs to — a session that has not been written is a session nothing knows about, and a reader
/// who opened one should still see where they are. In the store's own order, because that is the
/// store's answer to "which one did I use last".
async fn Shell::say_sessions(self : Shell) -> Unit {
  let shown = self.shown()
  let groups : Array[(String, String, Bool, Array[Json])] = []
  let mut listed = false
  for stored in @platform.list_workspaces(self.root) {
    let rows : Array[Json] = []
    for session in stored.sessions {
      let current = session.path == self.current
      if current {
        listed = true
      }
      // Read from the registry, not from the store: a session with a turn in flight is running whether
      // or not it is the one on screen, and that spinner is the only thing on the sidebar that tells a
      // reader a background conversation is still going.
      let running = match self.open_of(session.path) {
        Some(open) => open.busy
        None => false
      }
      rows.push(
        session_row(
          session.path,
          self.label_of(session.path, session.modified),
          session.modified,
          current,
          running,
        ),
      )
    }
    groups.push(
      (stored.cwd, workspace_label(stored), stored.cwd == shown.cwd, rows),
    )
  }
  if !listed {
    // The session on screen was created in this process and has not been written yet, so it has no
    // modification time of its own. Now is the honest stand-in: it was created now, and a reader
    // seeing "just now" is being told the right thing about it.
    let row = session_row(
      shown.path,
      self.label_of(shown.path, 0L),
      @env.now().reinterpret_as_int64(),
      true,
      shown.busy,
    )
    let mut placed = false
    for i in 0..<groups.length() {
      // Only to find the group: `rows` is a reference, so inserting into it has already changed the
      // tuple's own array and no write-back is needed.
      let (cwd, _, _, rows) = groups[i]
      if cwd == shown.cwd {
        rows.insert(0, row)
        placed = true
        break
      }
    }
    if !placed {
      groups.insert(0, (shown.cwd, workspace_name(shown.cwd), true, [row]))
    }
  }
  emit(sessions_event(groups))
}

// ── switching ──────────────────────────────────────────────────────────────

///|
/// Bring a session to the window: open it in the registry if this process is not holding it yet, and
/// display it.
///
/// This works **while a turn runs elsewhere**, and that is what the registry is for. A turn writes its
/// own session, so showing another one only changes what is drawn — no file is disturbed by it. The
/// version before this refused a mid-turn switch; then it held the click until the turn ended. Both
/// were workarounds for a shell that had exactly one session's state, and neither is needed now.
///
/// Opening is lazy: a session is read the first time the window shows it. A registry that read every
/// session in the store would pay for conversations nobody asked for — the same cost the sidebar
/// avoids by describing them rather than reading them.
async fn Shell::show(self : Shell, path : String) -> Unit {
  if path == "" {
    say_error("open: no session path")
    self.say_sessions()
    return
  }
  if path == self.current {
    self.say_sessions()
    return
  }
  match self.open_of(path) {
    Some(open) => {
      // Already held: showing it is a change of what is drawn and nothing else. In particular no
      // history, because the host's copy of this transcript is the live one — a turn may have written
      // rows to it that are not in the session this process is holding, and replaying the log would
      // replace them with less than the reader has already seen.
      self.display(open)
      self.say_show(open)
      self.say_sessions()
    }
    None => {
      if !@platform.path_exists(path) {
        say_error("no session at \{path}")
        self.say_sessions()
        return
      }
      // The same repair a resumed session gets, from the same place: a turn that died leaves a
      // transcript a provider will not take, and what "will not take" means — a call with no answer,
      // or an answer that is not next to its call — is one rule with one implementation.
      let loaded = @agent.repair_session(
        @platform.load_session(path),
        path,
        @env.now().reinterpret_as_int64(),
      )
      let open = Open::new(
        path,
        loaded.header.cwd,
        session_model(loaded),
        loaded,
      )
      self.display(open)
      self.say_open(open)
      self.say_sessions()
    }
  }
}

///|
/// The session that is now open: which file, where its tools run, and which model it runs on.
///
/// Sent on its own so that the host can stop showing one transcript before the next arrives. The two
/// events are a pair, and the state between them — a window with no session on screen — is a state
/// the host should be able to draw rather than avoid.
/// Whether the reader is being asked to decide about a turn that never finished.
///
/// This predicate is the whole of the notice the host draws above a transcript, and it has **two**
/// halves. The first is the log: a turn whose opening entry has no outcome is one that was left
/// behind — the process died, or it failed, or it was stopped and never resumed. The second is this
/// process: `turn_in_flight` is true for the whole time a turn *runs*, because the opening entry is
/// written before any of the work happens, so the log half alone described a healthy turn as an
/// interrupted one. That is a notice offering to continue a conversation that is being continued,
/// with two buttons that cannot be pressed while it runs — drawn for the reader who switched away
/// and came back to watch the turn they left behind working.
///
/// Named rather than written inline because it answers one question — *may the reader choose?* — and
/// the host cannot answer it: the host has no log.
fn interrupted_turn(open : Open) -> Bool {
  open.session.turn_in_flight() && !open.busy
}

///|
/// The session that is now open and what a reader needs to know about it: where its tools run, which
/// model it calls, and whether there is a turn waiting on a decision.
///
/// Sent whenever that changes — a switch, a turn starting, a turn ending, a turn failing — because the
/// host draws from this snapshot and has no other way to hear that it is out of date: a notice left on
/// screen describes a decision that may already have been made.
fn say_session(open : Open) -> Unit {
  let interrupted = interrupted_turn(open)
  // The question that turn was asked, read back from the log rather than retyped: continuing means
  // carrying on with the same question, and the reader should be shown which one they are being
  // offered. Empty when there is nothing to offer, so the pair cannot be read as "here is a choice,
  // and here is what it is about" when there is no choice.
  let prompt = if interrupted {
    match open.session.in_flight_prompt() {
      Some(question) => question
      None => ""
    }
  } else {
    ""
  }
  emit(
    session_event(open.path, "session", [
      ("cwd", Json::string(open.cwd)),
      ("model", Json::string(@core.model_spec_for(open.model_id).0.label())),
      ("interrupted", Json::boolean(interrupted)),
      ("interrupted_prompt", Json::string(prompt)),
    ]),
  )
}

///|
/// Put a session on screen for a host that has never seen it: the whole of what is in it, then which
/// one it is.
///
/// The history is the part that is only ever sent once. A host keeps a transcript per session, so a
/// session it has already been told about — or has been watching deltas of — needs no replay: sending
/// one would *replace* a transcript that is more up to date than the log, because a running turn's rows
/// are on the host and not yet in the session it is holding. That is not a hypothetical: it is what a
/// reader would see as "the answer I was watching disappeared when I came back".
///
/// **The rows go first, and the order is load-bearing.** The host swaps which transcript it is showing
/// when it hears *which session* is on screen, not when the rows arrive — so a host told "session C"
/// before it has anything for C swaps to an **empty** transcript and draws that until the rows land.
/// Measured on this machine, opening a 30MB session that way is a blank column for about 150ms (54ms
/// parsing, 16ms encoding, then a 3.7MB line and 51ms of decoding it on the host's main thread), which
/// is what a reader reported as "it goes white and I have to scroll". Sending the rows first makes the
/// same swap land on a transcript that already has them: what the host does with rows for a session it
/// is not showing is file them under that session, so the switch brings them in with it. One render
/// instead of two.
async fn Shell::say_open(self : Shell, open : Open) -> Unit {
  say_history(open.path, open.session)
  self.say_show(open)
}

///|
/// Put a session on screen: which one it is, and the snapshots that belong to it.
///
/// Everything but the history, which is what a re-show wants. The figures come along because a switch
/// changes which session's numbers are on screen, the model it runs on, and therefore whether a picture
/// can be attached to it at all — none of which the host can work out from the rows alone.
async fn Shell::say_show(self : Shell, open : Open) -> Unit {
  say_session(open)
  self.say_usage(open)
  say_models(open)
  say_images(open)
}

// ── paging the history ─────────────────────────────────────────────────────
//
// A session's transcript is replayed in **pages**, newest first, and the reader gets more by scrolling
// up. The reason is measured rather than aesthetic: one 19-turn session on this machine is 2.06MB of
// rows, and a single `history` event carrying all of it cost the host 17ms of decoding on the main
// thread and — much more — built a **32,000-point** scroll document, which is what makes landing at the
// end of it take ~240ms (measured; the same rows with short text and a 4,300-point document cost 88ms,
// so it is the height, not the count). A page keeps both numbers small, and the shell does not have to
// read or parse less: it still holds the whole session so a turn can continue from it.
//
// The cursor is an **id**, not an offset: the host says "I have these rows, the oldest is `h-N`" and
// the shell answers with the page that ends just before it. Ids are already unique within a session
// (`h-N`, counted per session) and every row carries one, so a cursor needs no new fact — and it cannot
// drift the way a count would if a turn appended rows while a page was in flight.

///|
/// The most turns one page holds.
///
/// Six, from the sizes measured on a real 19-turn session: the newest 6 turns were 320KB of 2.06MB
/// (15%), and the newest 5 were 247KB. Together with `page_max_bytes` this keeps the first page around
/// a tenth of a long session — and for the short sessions most people open, it is *everything*, so the
/// feature does not engage at all.
fn page_max_turns() -> Int {
  6
}

///|
/// How many bytes of rows one page may hold.
///
/// 256KB is the size that matters for the two costs above: at roughly 4KB of JSON per point of laid-out
/// text for these sessions, a page of this size builds a document in the low thousands of points rather
/// than the tens of thousands.
fn page_max_bytes() -> Int {
  262144
}

///|
/// One page of a session's rows, and what the host needs to ask for the next one.
///
/// A pure function of rows and a cursor, so the rule can be asserted without a session, a window or an
/// emit: `before` is the id of the oldest row the host already has (empty for the first page, which is
/// the newest), and the answer is the rows that end just before it.
///
/// The budget is spent **newest first and never below one turn**, and a turn is a unit because that is
/// what a reader scrolled to: a page that stopped mid-turn would leave the host holding half a
/// conversation whose other half is one request away, which is a state the transcript's own grouping
/// (`WeiModel.turns(of:)`) has no way to describe.
pub fn page_of(
  rows : Array[Json],
  before : String,
  max_turns : Int,
  max_bytes : Int,
) -> (Array[Json], String, Bool) {
  // Where the host's oldest row is. An unknown cursor (empty, or an id this session does not have —
  // a stale request, or a session that was rewritten under it) is answered with the newest page
  // rather than with nothing: the host replaces what it has in that case, so the worst outcome is the
  // reader's scroll position resetting, and the alternative is a window that never fills.
  let end = if before == "" {
    rows.length()
  } else {
    match index_of_id(rows, before) {
      Some(index) => index
      None => rows.length()
    }
  }
  if end <= 0 {
    return ([], "", false)
  }
  let mut start = end
  let mut turns = 0
  let mut bytes = 0
  while start > 0 {
    // **Work in turns, and the boundary falls on a question.** Walking row by row and stopping when
    // the budget runs out puts the boundary wherever the last row happened to be — which is how the
    // first version of this pulled a reply into a page whose own question was above the boundary, and
    // left the host a page starting on an answer.
    //
    // A turn is `[its question .. the row before the next question)`. So the turn that ends at `start`
    // begins at the nearest `user` row below it, and index 0 when there is none — a transcript whose
    // head has no question in it (a resumed session, or one that was compacted) is still a boundary.
    let mut open = start
    while open > 0 && row_kind(rows[open - 1]) != "user" {
      open -= 1
    }
    // The walk stopped one *past* the question — at the row after it, or at 0 when the transcript's
    // head has no question in it (a resumed session, or a compacted one). Either way that is the
    // boundary, and it is where a page is allowed to begin.
    if open > 0 {
      open -= 1
    }
    let mut size = 0
    for index in open..<start {
      size += rows[index].stringify().length() + 1
    }
    // The first turn is always taken — a page of no turns is not a page — and after that both budgets
    // apply. Both are stated as "does this turn fit", never as "stop mid-turn".
    if turns >= max_turns {
      break
    }
    if turns > 0 && bytes + size > max_bytes {
      break
    }
    start = open
    bytes += size
    turns += 1
  }
  let page : Array[Json] = []
  for index in start..<end {
    page.push(rows[index])
  }
  let oldest = if page.length() == 0 { "" } else { page_row_id(page[0]) }
  (page, oldest, start > 0)
}

///|
/// The id of a page row, or the empty string for a row that is not an object with one.
///
/// Named apart from `app.mbt`'s `row_id(kind, turn, seq)` deliberately: that one *makes* a live row's
/// name and this one *reads* a page row's, and the two are different questions that happen to collide
/// on a word.
fn page_row_id(row : Json) -> String {
  match row {
    Json::Object(fields) =>
      match fields.get("id") {
        Some(Json::String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// The kind of a page row, or the empty string.
fn row_kind(row : Json) -> String {
  match row {
    Json::Object(fields) =>
      match fields.get("kind") {
        Some(Json::String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// Where a row with this id is.
fn index_of_id(rows : Array[Json], id : String) -> Int? {
  for i in 0..<rows.length() {
    if page_row_id(rows[i]) == id {
      return Some(i)
    }
  }
  None
}

///|
/// The fields both `history` and `earlier` carry: the rows, the id the next page starts before, and
/// whether there is one.
fn page_fields(page : (Array[Json], String, Bool)) -> Array[(String, Json)] {
  let (rows, oldest, more) = page
  [
    ("rows", Json::array(rows)),
    // Named for what it is rather than for what it does: the *oldest row in this page*, which is the
    // id the host sends back to ask for what comes before it.
    ("oldest", Json::string(oldest)),
    ("has_more", Json::boolean(more)),
  ]
}

///|
/// The conversation of a session, as rows the host can draw — the newest page of it.
///
/// One place, because two situations need it and they are the same situation: a switch, where the host
/// is looking at the wrong session, and a startup on a resumed session, where it is looking at none.
fn say_history(path : String, session : @core.Session) -> Unit {
  emit(
    session_event(
      path,
      "history",
      page_fields(
        page_of(history_rows(session), "", page_max_turns(), page_max_bytes()),
      ),
    ),
  )
}

///|
/// The page before one the host already has.
///
/// A separate event from `history` because the host treats them differently — `history` *replaces* the
/// transcript it names, and this one **prepends** to it. Sending `history` again would throw away live
/// rows the shell has not written down yet, which is the same reason a re-show sends no history at all.
fn say_earlier(path : String, session : @core.Session, before : String) -> Unit {
  emit(
    session_event(
      path,
      "earlier",
      page_fields(
        page_of(
          history_rows(session),
          before,
          page_max_turns(),
          page_max_bytes(),
        ),
      ),
    ),
  )
}

///|
/// The model a session was last run on, or the build's default for one that never ran.
///
/// The log has the first word, and the reason is a resumed session: it was last run on whatever it
/// recorded, and starting it on the build's default instead would quietly answer its old questions on
/// a different model, at that model's prices.
fn session_model(session : @core.Session) -> String {
  match session.context().model {
    Some(entry) => entry.model_id
    None => @core.default_model_id()
  }
}

///|
/// Start a session in one project, and show it.
///
/// `dir` is the project the host asked for — the one the reader is looking at, named by the control
/// they clicked. The web UI has always worked this way (its row carries `data-new="<cwd>"`); what
/// this fixes is the macOS window, whose middle column lists *one* project while the shell only knew
/// the project of the session on screen. "New Session" under project B therefore landed in project
/// A, which is the mistake the row's own tooltip (`New session in this project`) was promising not
/// to make.
///
/// Empty means "the same directory as the session on screen". That is the honest answer for a host
/// with no project to name — an empty store, where nothing lists the open session yet, and a
/// hand-typed `wei-cli` line — and it is the fallback rather than the rule.
///
/// **Deliberately not `new_in`.** That one means "add a workspace": it writes the marker file and
/// says `workspace added: …` on the status line. This one only opens a session, which is what a
/// reader clicking "New Session" under a project that is *already* in the sidebar asked for. Writing
/// a marker here would be a second copy of a fact the store already holds, and a sentence about a
/// workspace that did not change.
///
/// The path is canonicalised for the reason `new_in` does it: `/new` typed by hand is a path a
/// reader thinks in, and the store has to see one spelling per directory.
///
/// The file is not written here, and that is deliberate rather than lazy: a session with nothing in
/// it is a header-only file nobody asked for, and the first prompt is what writes the first line. The
/// store therefore does not list it yet — `say_sessions` carries it anyway.
async fn Shell::create_in(self : Shell, dir : String) -> Unit {
  if dir == "" {
    self.open_fresh(self.shown().cwd)
    return
  }
  match @platform.canonical_dir(dir) {
    Some(cwd) => self.open_fresh(cwd)
    // Possible rather than theoretical: the directory can be gone between the list that named it and
    // this line. Said rather than silently leaving the reader where they were, because a click on
    // "New Session" that produced nothing is a click that did not work.
    None => say_error("not a directory: \{dir}")
  }
}

///|
/// Start a session in a directory the reader chose, rather than in the one they are already in.
///
/// The path comes from a folder chooser, so it is checked and **resolved** before anything else
/// happens to it. Resolution is not tidiness: `getcwd` hands back a path with symlinks already
/// resolved (`/private/tmp/...`), while a chooser hands back the path the reader thinks in
/// (`/tmp/...`). Storing the second would put one directory in the store twice — two groups in the
/// sidebar for one folder, each holding half the sessions — and it would look like the app had lost
/// them. `platform/picker.mbt` guards the same edge on the web side (a chooser's trailing separator
/// is the other half of it).
async fn Shell::new_in(self : Shell, path : String) -> Unit {
  if path == "" {
    say_error("no folder chosen")
    return
  }
  let cwd = match @platform.canonical_dir(path) {
    Some(cwd) => cwd
    // Possible rather than theoretical: a chooser hands back a path, and something can remove the
    // directory between the dialog closing and this line.
    None => {
      say_error("not a directory: \{path}")
      return
    }
  }
  // Recorded before the session exists, so a workspace whose session fails to open is still a
  // workspace — the row is what makes the directory reachable again. The existing title is kept:
  // this file is the only place a workspace's name lives, and overwriting it would erase a name the
  // reader had given a folder every time they started a session in it.
  let dir = @core.session_dir_for(self.root, cwd)
  let title = match @platform.read_workspace(dir) {
    Some(record) => record.title
    None => None
  }
  @platform.write_workspace(dir, { cwd, title, })
  self.open_fresh(cwd)
  say_status(self.shown().path, "workspace added: \{cwd}")
}

///|
/// The same three steps every new session takes, wherever the directory came from.
///
/// One place because the state that has to be let go of is not obvious: the attachments belong to the
/// message that was being written, and the last turn's figures belong to the session being left. Miss
/// either and the new session opens wearing the old one's clothes.
async fn Shell::open_fresh(self : Shell, cwd : String) -> Unit {
  let (session, path) = fresh_session(self.root, cwd)
  // A brand-new session, so there is nothing to carry over: the attachments belonged to the question
  // that was being written somewhere else, and the last turn's figures belonged to the conversation
  // being left. Both live per session now, which is why this does not have to clear them.
  let open = Open::new(path, cwd, self.shown().model_id, session)
  self.display(open)
  // The model is the log's answer for a session that has one, and a session nobody has run has no
  // log to answer — so it stays whatever was in force, which is what the reader last chose.
  self.say_open(open)
  self.say_sessions()
}

// ── attachments ────────────────────────────────────────────────────────────

///|
/// Put a picture on the next prompt.
///
/// Read here rather than when the turn starts, so that the answer to "can this be sent" arrives
/// while the reader is still looking at the file they picked. What comes back is either the picture
/// on the composer or a sentence saying why not — never a silent failure, which is the one outcome a
/// file picker cannot explain.
/// `temporary` is the pasted-image case: the host had no file, so it minted one, and this is the
/// side that can delete it safely. Deleting from the host would race the read — the bytes are loaded
/// here, on the agent's thread, a moment after the command is written — so the file is the shell's to
/// consume, and it says so by taking it away once it has.
async fn Shell::attach(
  self : Shell,
  path : String,
  temporary? : Bool = false,
) -> Unit {
  if path == "" {
    say_error("attach: no path")
    return
  }
  // The session on screen: a picture is part of the message being written, and the message being
  // written is the one whose composer the reader just clicked in.
  let open = self.shown()
  // A `Result` rather than a raised error, because "this file is not a picture" is an answer the
  // reader asked for by picking it — not an exception in the shell's own work.
  let image = match @platform.load_image(path) {
    Ok(image) => image
    Err(reason) => {
      say_error("cannot attach: \{reason}")
      return
    }
  }
  open.attached = with_attachment(open.attached, path, image)
  if temporary {
    @platform.delete_file(path)
  }
  say_images(open)
  if !@core.model_sees_images(open.model_id) {
    // Said now rather than after the send: the request would go out with a placeholder in place of
    // the picture, and the reader is the only one who can do something about it — another model, or
    // no picture.
    say_error(
      "\{@core.model_spec_for(open.model_id).0.label()} cannot be shown images — switch model first",
      session=open.path,
    )
  }
}

///|
/// The list with a picture on the end of it, and the same file attached twice counting once.
///
/// Two identical images in one message is a reader clicking twice, not a reader asking for the
/// picture twice — and the reader's mental model of a list is a set of pictures, so a second click on
/// one already there should leave the list saying what it said.
fn with_attachment(
  attached : Array[Attachment],
  path : String,
  image : @platform.LoadedImage,
) -> Array[Attachment] {
  let kept = without_attachment(attached, path)
  kept.push({ path, mime_type: image.mime_type, data: image.data, })
  kept
}

///|
/// The list without the picture that was attached from `path`.
///
/// By the path rather than by an index or an id: the composer drew a row per path, so the path is the
/// only name the reader — and therefore the host — has for the thing to take back. Removing one that
/// is not there is a no-op, because the host can ask twice and a list that changed on a click that
/// removed nothing would be a list the reader did not predict.
fn without_attachment(
  attached : Array[Attachment],
  path : String,
) -> Array[Attachment] {
  let kept : Array[Attachment] = []
  for existing in attached {
    if existing.path != path {
      kept.push(existing)
    }
  }
  kept
}

///|
/// Take one picture back off the next prompt.
fn Shell::detach(self : Shell, path : String) -> Unit {
  let open = self.shown()
  open.attached = without_attachment(open.attached, path)
  say_images(open)
}

///|
/// Forget all of them, without waiting for the session to change.
fn Shell::clear_attachments(self : Shell) -> Unit {
  let open = self.shown()
  open.attached = []
  say_images(open)
}

// ── deleting ───────────────────────────────────────────────────────────────

///|
/// The conversation that was just deleted, so the host can offer it back.
///
/// Pure, so the shape can be pinned from the writing side without a store on disk — the same
/// arrangement as `sessions_event` and `models_event`.
///
/// The path is the routing field *and* a payload field, and that is not redundant: the routing says
/// which session this is about — and it is about one that is no longer in the list — while the payload
/// is what `restore` takes. One is the wire's envelope, the other is the shell's own command line
/// (`/restore <path>`), and they are the same string for the same reason: a session is its file.
///
/// `restorable` is what decides whether the host draws a way back at all, and the shell is the side
/// that knows: a delete renames the file aside and a *purge* removes it, and no amount of looking at
/// the click tells the two apart. An offer drawn from the click is an Undo button on a conversation
/// that is gone — which is where this whole line of the wire began (see `macos/README.md`).
fn deleted_event(path : String, label : String, restorable : Bool) -> Json {
  session_event(path, "deleted", [
    ("path", Json::string(path)),
    ("label", Json::string(label)),
    ("restorable", Json::boolean(restorable)),
  ])
}

///|
/// Say which conversation just went, and whether there is a way back.
///
/// The label is what the host draws its line with, read by the caller because the moment this is said
/// is the last moment the file is there to be described.
fn say_deleted(path : String, label : String, restorable : Bool) -> Unit {
  emit(deleted_event(path, label, restorable))
}

///|
/// Take a session out of the store: out of the list, and — when the reader asked for it — off the disk.
///
/// **The session on screen is replaced rather than refused.** It used to be refused — "cannot delete
/// the session that is open" — and the cost of that was a rule the reader has to learn for no benefit:
/// they clicked Delete on the row they were looking at, and the answer was that they should look
/// somewhere else first. What the refusal was standing in for is real, though, and stays: the window
/// cannot be left showing a file that is no longer in the list, and `Shell::shown` panics when nothing
/// is. So the replacement is decided and **installed** before the file moves — between those two lines
/// "there is always something on screen" is true at every point, which is the whole of what the order
/// buys.
///
/// Three refusals stay, and none of them is about the file: a turn appending to it (that file is being
/// written *now* — reachable since more than one conversation can run at once, so a reader can switch
/// away from a long turn and then clear it out of the list), a background job it started, and nothing
/// there to delete at all.
///
/// The order is the web UI's (`ui/requests.mbt`): the states, then the file. A turn is asked about
/// before the file is, because the two can disagree for a moment — a turn that has *just* started is
/// running already, and its session may not have written its first line yet — and it is the running turn
/// that must not be deleted out from under, file or no file.
///
/// **`purge` is the one irreversible thing in this program.** It comes from a checkbox the reader has
/// to tick (off by default), and it is the difference between renaming the file aside and removing it:
/// what the host is told afterwards is the same event, because both are "that conversation is gone from
/// the list" — the `restorable` field is the one part that differs, and it is what keeps an Undo button
/// off a file that is not there to put back.
async fn Shell::discard(self : Shell, path : String, purge~ : Bool) -> Unit {
  if path == "" {
    say_error("delete: no session path")
    self.say_sessions()
    return
  }
  if self.open_of(path) is Some(open) && open.busy {
    say_error("cannot delete a session with a turn running — stop it first")
    self.say_sessions()
    return
  }
  if self.jobs.live_count(path) > 0 {
    // The other state that outlives the file: a job the conversation started would keep running with
    // no row to find it on, and no way to stop it from the window.
    say_error("cannot delete a session with a background job still running")
    self.say_sessions()
    return
  }
  if !@platform.path_exists(path) {
    say_error("that session is already gone")
    self.say_sessions()
    return
  }
  // Read before the file moves, and while the cache still knows what it looked like: the offer the
  // host draws says *which* conversation went, and a row that is gone cannot be asked.
  let label = self.label_of(path, self.labels.modified_of(path))
  // Decided before the file moves, and that is not tidiness: the successor is found by asking the store
  // what is in this project, and the doomed session is still the newest file in it — nothing in a
  // listing tells "the one being deleted" apart from "the one to show instead".
  let successor = if path == self.current {
    Some(self.successor_after(path))
  } else {
    None
  }
  if purge {
    @platform.purge_session(path)
  } else {
    @platform.delete_session(path)
  }
  self.labels.forget(path)
  // The registry is "the sessions this process may have a turn running in", and one that has left the
  // store is not: left there it would keep a file the reader can no longer see, and `say_sessions`
  // would go on reading a `busy` flag off a conversation nothing lists. This is the only path on which
  // the registry shrinks.
  ignore(self.opens.extract_if(open => open.path == path))
  // Said before the window moves: the offer names the conversation that went, and the host is about to
  // be handed a different one. `restorable` is the checkbox: a purged file is not waiting to be put
  // back, and the host is told which of the two happened rather than left to assume.
  say_deleted(path, label, !purge)
  match successor {
    Some(open) => {
      // Displayed by hand rather than through `show`, and the difference is the whole of a bug this
      // would otherwise have: `show` refuses a path that is not on disk — which is the right answer for
      // a reader asking for a file that is not there, and the wrong one here, where the successor can
      // legitimately be a session nobody has written yet. Refusing it would leave `current` pointing at
      // a session that has just left the registry, and `shown` panics on that.
      //
      // Whether the host has seen this one is what decides between the two halves of the pair, and the
      // registry is the side that knows: a session this process holds has been shown, so the host has
      // its rows and a replay would replace them with less. `display` before the question would answer
      // it "yes" every time.
      let held = self.open_of(open.path) is Some(_)
      self.display(open)
      if held {
        self.say_show(open)
      } else {
        self.say_open(open)
      }
    }
    None => ()
  }
  self.say_sessions()
}

///|
/// Something to look at once the session on screen is gone.
///
/// Three answers in order of cost, and the same three the web UI gives (`ui/requests.mbt`'s
/// `next_session_after`): another session this process already holds in that project, the newest one
/// saved there, and finally a brand-new one. The last is not a fallback for a bug — a store with one
/// session in it has one session, and the window still has to show something.
///
/// An `Open` rather than a path, because the caller has to be able to *install* it without asking the
/// disk a second time: the newest session in a project is not on disk in the fresh case, and by the time
/// the caller has moved the file, the listing that produced this answer is out of date.
async fn Shell::successor_after(self : Shell, path : String) -> Open {
  let shown = self.shown()
  for open in self.opens {
    if open.path != path && open.cwd == shown.cwd {
      return open
    }
  }
  for
    stored in @platform.list_sessions(
      @core.session_dir_for(self.root, shown.cwd),
    ) {
    if stored.path == path {
      continue
    }
    match self.open_of(stored.path) {
      Some(open) => return open
      None =>
        if @platform.path_exists(stored.path) {
          // Read the way a switch reads one, repair included: a log written by a process that died holds
          // a tool call with no answer, and a window opened on it that could not send would be a dead end
          // the reader got to by deleting something else.
          let loaded = @agent.repair_session(
            @platform.load_session(stored.path),
            stored.path,
            @env.now().reinterpret_as_int64(),
          )
          return Open::new(
            stored.path,
            loaded.header.cwd,
            session_model(loaded),
            loaded,
          )
        }
    }
  }
  // A session nobody has written yet: created here and shown, and the first prompt is what puts a line
  // in the store. It is what "there is no other session" looks like as something to look at — and its
  // model is the one in force, the same rule a new session follows everywhere else.
  let (session, created) = fresh_session(self.root, shown.cwd)
  Open::new(created, shown.cwd, shown.model_id, session)
}

// ── the projects ───────────────────────────────────────────────────────────

///|
/// Whether this project may leave the list yet.
///
/// The same two states that keep a session from being deleted, asked of the whole project: a turn
/// running in any of its sessions is appending to a log this is about to move out from under the
/// sidebar, and a job it started is a process whose output nobody can reach any more.
fn Shell::project_idle(self : Shell, cwd : String) -> Bool {
  for open in self.opens {
    if open.cwd != cwd {
      continue
    }
    if open.busy {
      say_error("a turn is running in this project — stop it first")
      return false
    }
    if self.jobs.live_count(open.path) > 0 {
      say_error("a background job is still running in this project")
      return false
    }
  }
  true
}

///|
/// Take a project out of the sidebar: the row, the sessions under it, and — with the checkbox — the
/// conversations themselves.
///
/// **Not the folder.** The working directory is the reader's; what moves is the store's own slice of
/// it, `~/.wei/sessions/--Users-me-src--`, which is why the dialog can say the project is untouched
/// and mean it. Without the checkbox that is a rename, and every session is still on disk under a
/// `.removed` name; with it the directory is emptied. Both halves live in `platform/session.mbt`.
///
/// The window cannot go on showing a session whose project has left, so the session on screen is
/// re-homed first — before the directory moves, while the candidate is still a session the registry
/// can be asked about (`rehome_after`).
///
/// Addressed by working directory rather than by store directory, like every other project command:
/// the path is what the host has, and the store's name for it cannot be decoded back into a path.
async fn Shell::remove_project(
  self : Shell,
  cwd : String,
  delete~ : Bool,
) -> Unit {
  if cwd == "" {
    say_error("remove: no project path")
    self.say_sessions()
    return
  }
  if !self.project_idle(cwd) {
    self.say_sessions()
    return
  }
  // The listing has the last word: it is what the reader is looking at, and it is where the label and
  // the session count come from. A project it does not list is a project already gone — refused rather
  // than removed again, because "there is nothing there" and "that is not this project" are the same
  // answer to the store.
  let mut found : @platform.StoredWorkspace? = None
  for stored in @platform.list_workspaces(self.root) {
    if stored.cwd == cwd {
      found = Some(stored)
      break
    }
  }
  let stored = match found {
    Some(stored) => stored
    None => {
      say_error("that project is not in the list")
      self.say_sessions()
      return
    }
  }
  let label = workspace_label(stored)
  let sessions = stored.sessions.length()
  let leaving = self.shown().cwd == cwd
  let successor = if leaving { Some(self.rehome_after(cwd)) } else { None }
  // The rename is the removal: everything after this is about a project that is already out of the
  // list, which is why the failure branch below returns before touching anything else.
  let aside = match @platform.remove_workspace(self.root, cwd) {
    Some(aside) => aside
    None => {
      // Nothing moved — the store does not list this project, or the rename failed. Said plainly: a
      // click that appears to do nothing is the one outcome the reader cannot act on.
      say_error("could not remove \{label}")
      self.say_sessions()
      return
    }
  }
  // And the emptying is of the aside-copy, after the rename. A failure here is reported with the path,
  // because that is where the conversations are: the reader asked for them gone and has to be able to
  // go and finish the job. This is the only irreversible act in the program.
  if delete && !@platform.purge_workspace(aside) {
    say_error(
      "\{label} removed, but its \{sessions} sessions could not be deleted — they are at \{aside}",
    )
    self.say_sessions()
    return
  }
  // The registry is "the sessions this process may have a turn running in", and a session whose
  // project has left the list is not one the reader can reach — left there it would keep a file
  // nothing lists, and `say_sessions` would go on reading a `busy` flag off it. Labels go with them:
  // the cache is keyed by path, and a path under the name the directory had is a path that is gone.
  for open in self.opens {
    if open.cwd == cwd {
      self.labels.forget(open.path)
    }
  }
  ignore(self.opens.extract_if(open => open.cwd == cwd))
  match successor {
    Some(open) => {
      // The same pair the two session paths send, and the same reason for choosing between them: a
      // session this process already holds has been shown, so the host has its rows and a replay would
      // replace them with less.
      let held = self.open_of(open.path) is Some(_)
      self.display(open)
      if held {
        self.say_show(open)
      } else {
        self.say_open(open)
      }
    }
    None => ()
  }
  let what = if delete {
    // The `sessions == 0` case is a project with nothing in it: there was no checkbox, and there was
    // nothing for one to have deleted.
    if sessions == 0 {
      "project removed: \{label}"
    } else {
      "project and \{sessions} sessions removed: \{label}"
    }
  } else if sessions == 0 {
    "project removed: \{label}"
  } else {
    "project removed: \{label} · \{sessions} sessions kept"
  }
  // Said on the session now on screen, which is why the re-homing above comes first: the status line is
  // the only thing that reports a project whose row is no longer there to look at.
  say_status(self.current, what)
  self.say_sessions()
}

///|
/// Where the window goes when the project it was in leaves the list.
///
/// **Another project's session, in the order the sidebar would put them**, because that is the one thing
/// the reader can predict: the window goes where they would have clicked. Three answers, the same three
/// `successor_after` gives and for the same reason — the cheapest first:
///
/// 1. a session this process already holds, and it must be in a *different* project: everything the
///    registry has in the one being removed is about to be dropped from it, and a window left on a session
///    the store no longer lists would put the removed project straight back on the sidebar (`say_sessions`
///    always lists the session on screen, under the project it belongs to);
/// 2. failing that (every session open is in this project) the *top* of the store — the newest session of
///    the most recently used other project, which is the first row the sidebar will draw. Costing one file
///    read, on the one path where the alternative is an empty window;
/// 3. and failing that a brand-new session in the home directory, which is the place `working_dir` already
///    names for "the process has nowhere in particular to work". A fresh session in the doomed project
///    would make an empty row that persists for exactly as long as the reader leaves it unused, and one of
///    the project's own *saved* sessions would have the same problem as an open one.
///
/// The model is the one in force, the same rule a new session follows everywhere else.
async fn Shell::rehome_after(self : Shell, cwd : String) -> Open {
  for open in self.opens {
    if open.cwd != cwd {
      return open
    }
  }
  // Read before the directory moves, which is why this is here rather than after the removal: once the
  // store directory is renamed aside the listing no longer holds this project, and the rule below — "the
  // topmost project that is not this one" — would then be free to pick the very sessions being removed.
  for stored in @platform.list_workspaces(self.root) {
    if stored.cwd == cwd || stored.sessions.is_empty() {
      continue
    }
    let newest = stored.sessions[0]
    if self.open_of(newest.path) is Some(open) {
      return open
    }
    // Read the way a switch reads one, repair included: a log written by a process that died holds a
    // tool call with no answer, and a window opened on one that could not send would be a dead end the
    // reader got to by removing something else.
    let loaded = @agent.repair_session(
      @platform.load_session(newest.path),
      newest.path,
      @env.now().reinterpret_as_int64(),
    )
    return Open::new(
      newest.path,
      loaded.header.cwd,
      session_model(loaded),
      loaded,
    )
  }
  let (session, path) = fresh_session(self.root, self.home)
  Open::new(path, self.home, self.shown().model_id, session)
}

// ── history ────────────────────────────────────────────────────────────────

///|
/// A row while it is being built.
///
/// Tools make this more than a list of strings: a result arrives in a later message than the call it
/// answers, so the row is created by the call and filled in by the result. Which is why the tools'
/// content is looked up by call id at the end rather than carried on the row.
priv struct Draft {
  kind : String
  id : String
  text : String
  name : String
  detail : String
  /// Tools only: the call this row answers.
  call_id : String
  /// A **question's** pictures, already as wire pairs. Empty for every other kind of row.
  ///
  /// On the draft rather than looked up at the end, which is how a tool's output has to be done: a
  /// result arrives in a later message than the call it answers, while these are in the very message
  /// the words are in.
  images : Array[(String, String)]
}

///|
/// Whether the host draws a row of this kind as markdown.
///
/// **One answer, because two sides have to agree about it.** The host reads `row.blocks` in exactly
/// one place — `RootView`'s `case .reply` — and draws every other kind from its own fields: a question
/// is `Text(row.text)`, reasoning is a three-line peek of `row.text`, a tool is its output, a note is a
/// line. A parse sent for those rows is a parse nobody reads.
///
/// That is not a micro-optimisation, it was measured on a real 30MB session: the reasoning alone was
/// **1.6MB of the 4.05MB `history` event** (68% of the rows by bytes), and parsing it cost the shell
/// 29ms per session opened. It also made the host's decode of that event slower and, with it, the time
/// a switch spends with nothing on screen.
///
/// The rule is stated as a function rather than as a comparison at each call site so that a row kind
/// added later has one place to be considered — and the failure if it is forgotten is a parse the host
/// ignores, not a row that does not render.
fn draws_markdown(kind : String) -> Bool {
  kind == "reply"
}

///|
/// One block of text as the host draws it: parsed markdown, or null when there is nothing to parse —
/// or when the row is one the host draws from its text alone (`draws_markdown`).
///
/// Null rather than an empty array, because "this row has no markdown" and "this row's markdown is
/// empty" are the same fact, and the host's rule is the simple one: parsed blocks or the text.
fn blocks_of(kind : String, text : String) -> Json {
  if text == "" || !draws_markdown(kind) {
    Json::null()
  } else {
    @md.blocks_json(text)
  }
}

///|
/// A note: text that stands in for something that is not in the conversation any more.
///
/// Its own constructor rather than `text_draft` plus a field assignment, because a note that is not
/// labelled is a paragraph the reader will read as an answer — the label is not decoration, it is
/// what makes the row say what it is.
fn note_draft(id : String, text : String, label : String) -> Draft {
  { kind: "note", id, text, name: label, detail: "", call_id: "", images: [], }
}

///|
fn text_draft(
  kind : String,
  id : String,
  text : String,
  images? : Array[(String, String)] = [],
) -> Draft {
  { kind, id, text, name: "", detail: "", call_id: "", images, }
}

///|
/// Add a text row, or extend the one before it.
///
/// A model writes one answer as several blocks, and a tool call between two of them separates them.
/// Two blocks with nothing in between are one paragraph of one answer, which is one row — the same
/// rule the host's streaming append follows, so a replayed transcript and a live one look alike.
fn append_text(
  drafts : Array[Draft],
  kind : String,
  id : String,
  text : String,
) -> Unit {
  let last = drafts.length() - 1
  if last >= 0 && drafts[last].kind == kind {
    let previous = drafts[last]
    drafts[last] = { ..previous, text: previous.text + text, }
  } else {
    drafts.push(text_draft(kind, id, text))
  }
}

///|
/// The text of a message, joined across its parts.
///
/// Images are named rather than dropped: a host that cannot draw an attachment should still be told
/// there was one, or a turn reads as if it had been asked something else.
fn content_text(content : Array[@core.Content]) -> String {
  let out = StringBuilder()
  for block in content {
    match block {
      @core.Text(text) => {
        if out.to_string() != "" {
          out.write_string("\n")
        }
        out.write_string(text)
      }
      @core.Image(..) => {
        if out.to_string() != "" {
          out.write_string("\n")
        }
        out.write_string("(image attachment)")
      }
      _ => ()
    }
  }
  out.to_string()
}

///|
/// The text of a **question**, with its pictures left out.
///
/// `content_text` beside it keeps the `(image attachment)` line for every other reader of the same
/// text: a tool result for a model that read a file, and the answer text a text-only model is shown.
/// What differs is who draws it. The host draws a question's pictures as pictures now, so a bubble
/// underneath saying a picture is there describes one thing twice.
///
/// A question that is **only** a picture therefore comes out as an empty string, which is the point:
/// that is what makes it draw as a picture with no caption rather than as a caption with no picture.
fn user_text(content : Array[@core.Content]) -> String {
  let out = StringBuilder()
  for block in content {
    match block {
      @core.Text(text) => {
        if out.to_string() != "" {
          out.write_string("\n")
        }
        out.write_string(text)
      }
      // The one difference from `content_text`: a picture contributes no words here.
      _ => ()
    }
  }
  out.to_string()
}

///|
/// One picture as the host decodes it — `RowImage`'s two fields, and nothing else.
///
/// **Deliberately not the shape `images_event` builds** for the composer's attach list. That one is
/// about a *file* the reader picked, so it carries a `path`: the path is the row's identity and what a
/// remove names. This is about a picture inside a message, where the identity is the message it is in
/// and a path would be a fact about the sender's disk that the reader of the transcript cannot use.
/// Two questions, two shapes.
fn image_row(mime_type : String, data : String) -> Json {
  Json::object(
    Map([("mime", Json::string(mime_type)), ("data", Json::string(data))]),
  )
}

///|
/// The pictures in a message, in the order they were sent.
///
/// Paired rather than turned into `Json` here, so that this is useful to both spellings the wire has:
/// `say_user` takes the pairs and `history_rows` turns them into rows with `image_row`.
fn content_images(content : Array[@core.Content]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for block in content {
    match block {
      @core.Image(data~, mime_type~) => out.push((mime_type, data))
      _ => ()
    }
  }
  out
}

///|
/// The same, from the composer's attachments.
///
/// Two functions rather than one because the two lists are two different things: `Attachment` is a
/// file the reader attached (it has a path, and lives on `Open` until the turn sends it), while
/// `@core.Content` is a block of a message that has already gone. `say_user` is handed the first and
/// the history is read for the second.
fn attached_images(items : Array[Attachment]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for attachment in items {
    out.push((attachment.mime_type, attachment.data))
  }
  out
}

///|
/// Rows rather than events, because a history has no timing to it: every block in it is finished,
/// every tool has its output, and replaying it as a stream of deltas would be inventing an afternoon
/// of arrivals that all happened at once.
///
/// The ids are prefixed `h-` so that a row from a history cannot collide with one from a stream — the
/// live ids are `reply-1`, `tool-2` and so on, and a transcript that mixed the two namings would
/// append a delta to the wrong block.
fn history_rows(session : @core.Session) -> Array[Json] {
  let drafts : Array[Draft] = []
  // Keyed by the model's call id rather than by index, so nothing here has to know where in the list
  // a row ended up.
  let claimed : Map[String, Unit] = Map([])
  let results : Map[String, (String, Bool)] = Map([])
  let mut seq = 0
  let next_id = () => {
    seq += 1
    "h-\{seq}"
  }
  for message in session.context().messages {
    match message {
      @core.User(user) => {
        let text = user_text(user.content)
        let images = content_images(user.content)
        // A question with no words is still a question, which is the sharper half of this: an
        // image-only prompt has no text at all, and a row skipped for having none would drop the
        // message — and the turn that answered it — from the transcript entirely.
        if text != "" || images.length() > 0 {
          drafts.push(text_draft("user", next_id(), text, images~))
        }
      }
      @core.Assistant(assistant) =>
        for block in assistant.content {
          match block {
            @core.Text(text) =>
              if text != "" {
                append_text(drafts, "reply", next_id(), text)
              }
            @core.Thinking(thinking~, ..) =>
              if thinking != "" {
                append_text(drafts, "thinking", next_id(), thinking)
              }
            @core.ToolCall(id~, name~, arguments~) => {
              claimed.set(id, ())
              drafts.push({
                kind: "tool",
                id: next_id(),
                text: "",
                name,
                detail: @core.tool_summary(arguments),
                call_id: id,
                images: [],
              })
            }
            _ => ()
          }
        }
      @core.ToolResult(result) => {
        if claimed.get(result.tool_call_id) is None {
          // A result whose call is not on this path: a session that was branched away from, or a
          // repair that closed a call the reader never saw run. Shown rather than dropped, because a
          // transcript with a hole in it is worse than one with a stray row.
          claimed.set(result.tool_call_id, ())
          drafts.push({
            kind: "tool",
            id: next_id(),
            text: "",
            name: result.tool_name,
            detail: "",
            call_id: result.tool_call_id,
            images: [],
          })
        }
        results.set(
          result.tool_call_id,
          (content_text(result.content), result.is_error),
        )
      }
      // Both stand in for history the log no longer holds in full, and both are what the reader has
      // to see in its place: the summary is the only record of what it replaced.
      //
      // Labelled rather than left bare. A summary drawn as an unlabelled paragraph is a wall of text
      // where an answer should be, and the one thing a reader needs to know about it — that the
      // conversation above was replaced by it — is exactly what a bare note does not say.
      @core.CompactionSummary(summary~, ..) =>
        drafts.push(note_draft(next_id(), summary, "context compacted"))
      @core.BranchSummary(summary~, ..) =>
        drafts.push(note_draft(next_id(), summary, "branched from here"))
      _ => ()
    }
  }
  let rows : Array[Json] = []
  for draft in drafts {
    let (output, is_error) = match results.get(draft.call_id) {
      Some(answer) => answer
      None =>
        // A tool the turn never got an answer from — the process died, or the turn was stopped
        // between the call and its result. The row is left without one rather than given an excuse.
        ("", false)
    }
    let pictures : Array[Json] = []
    for (mime_type, data) in draft.images {
      pictures.push(image_row(mime_type, data))
    }
    rows.push(
      Json::object(
        Map([
          ("kind", Json::string(draft.kind)),
          ("id", Json::string(draft.id)),
          ("text", Json::string(draft.text)),
          // Everything in a history is over: nothing here is still arriving. That is what lets the
          // row's markdown be parsed once, here, rather than on every delta — the cost the web UI
          // learned about with 40KB of reasoning in 64-character frames.
          ("complete", Json::boolean(true)),
          // And the parse, which is the part that cannot be produced by the host: a SwiftUI `Text`
          // has no markdown parse of its own, and `AttributedString(markdown:)` — what the app used
          // before this — never sees a table and drops a fenced block's language. `null` for a row
          // with no text, so the host has one rule: blocks if they are there, plain text otherwise.
          ("blocks", blocks_of(draft.kind, draft.text)),
          ("name", Json::string(draft.name)),
          ("detail", Json::string(draft.detail)),
          ("output", Json::string(output)),
          ("error", Json::boolean(is_error)),
          // Last, and on **every** row, empty for most of them: a field that appeared and disappeared
          // would be one more shape for the host to decode, and its default is the empty list either
          // way. The same reasoning the live stream follows in `say_user`.
          ("images", Json::array(pictures)),
        ]),
      ),
    )
  }
  rows
}

///|
/// Give a session a name of its own, or take one away.
///
/// Written as a `session_info` entry in the log rather than into some side table, because that is
/// where upstream keeps it and a name has to survive being read back by another front end. It also means
/// the rename is part of the conversation's own file, so a session carried to another machine keeps
/// the name its reader gave it.
///
/// An empty name clears it. That is a deliberate request rather than something a field does by
/// accident, which is why the host only sends one from its own Clear button.
///
/// The session on screen can be renamed; another one cannot. Naming a file this process is not
/// holding would mean reading it, appending to it and writing it back — three steps that a turn
/// running somewhere else could interleave with, and the log is the one file in this program that
/// must never be forked.
async fn Shell::rename(self : Shell, path : String, name : String) -> Unit {
  if path == "" {
    say_error("rename: no session path")
    self.say_sessions()
    return
  }
  let open = match self.open_of(path) {
    Some(open) => open
    None => {
      say_error("cannot rename a session that is not open")
      self.say_sessions()
      return
    }
  }
  let now = @env.now().reinterpret_as_int64()
  let entry = @core.session_name_entry(
    if name == "" {
      None
    } else {
      Some(name)
    },
    open.session.leaf_id,
    now,
  )
  @platform.ensure_session(open.path, open.session.header)
  @platform.append_entry(open.path, entry)
  // The in-memory copy moves with the file, so the next turn's parent is this entry rather than the
  // one before it — a session whose parents disagree with the file is a session whose next request
  // is built from a log nobody wrote.
  open.session = open.session.add_entries([entry])
  say_status(
    open.path,
    if name == "" {
      "name cleared"
    } else {
      "named '\{name}'"
    },
  )
  // Only if the renamed session is the one on screen: renaming a conversation the reader is not
  // looking at must not replace what they are looking at.
  if path == self.current {
    self.say_show(open)
  }
  // The label cache is keyed by path *and* modification time, so appending invalidates it on its
  // own — but only once the file's mtime has moved. Re-read here rather than assumed, because a
  // list that keeps showing the old name is a rename that looks like it failed.
  self.labels.forget(path)
  self.say_sessions()
}

///|
/// Put a deleted session back where it was.
///
/// The inverse of `discard`, from the same place as the web UI's Undo: the file was renamed aside
/// rather than removed, and this is that rename reversed. It is a convenience and not the only way
/// back — the bytes are still on disk under a predictable name.
async fn Shell::restore(self : Shell, path : String) -> Unit {
  if path == "" {
    say_error("nothing to restore")
    self.say_sessions()
    return
  }
  if @platform.path_exists(path) {
    say_error("that session is already back")
    self.say_sessions()
    return
  }
  @platform.restore_session(path)
  self.labels.forget(path)
  say_status(self.current, "restored")
  self.say_sessions()
}

///|
/// Close an interrupted turn without resuming it: what "Start fresh" means to the log.
///
/// Writing an outcome rather than doing nothing is the whole point. A turn that is open in the log
/// is announced again by every later reader, so deciding not to continue it has to be *recorded* to
/// actually be a decision — otherwise the notice comes back, and the same question is asked a third
/// time.
async fn Shell::dismiss_turn(self : Shell, open : Open) -> Unit {
  if !open.session.turn_in_flight() {
    // A status line rather than an error, because the reader asked for the turn not to be resumed and
    // it is not: there is nothing left to resume. What was wrong is the *host's* copy, one event
    // behind — so the snapshot is re-sent, or the click would leave on screen the very notice it was
    // about. No history: nothing was appended, so it is the snapshot that can be stale and not the rows.
    say_status(open.path, "nothing to dismiss: that turn has already ended")
    self.say_show(open)
    return
  }
  let now = @env.now().reinterpret_as_int64()
  let entry = @core.turn_outcome_entry(
    @core.Abandoned,
    0,
    0.0,
    open.session.leaf_id,
    now,
  )
  @platform.ensure_session(open.path, open.session.header)
  @platform.append_entry(open.path, entry)
  open.session = open.session.add_entries([entry])
  say_status(open.path, "closed the interrupted turn")
  self.say_open(open)
}
