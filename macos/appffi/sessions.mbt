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
/// name written by pi is read here too; pattern-matching the JSON would stop working the day a field
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
      say_show(open)
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
      say_open(open)
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
fn say_session(open : Open) -> Unit {
  // A turn that is in the log without an outcome is one that was interrupted — the process died, or
  // it was stopped and never resumed. The host draws it as a notice with two ways out, and this is
  // where it learns that the state exists at all: nothing else on the wire says it.
  let interrupted = open.session.turn_in_flight()
  emit(
    session_event(open.path, "session", [
      ("cwd", Json::string(open.cwd)),
      ("model", Json::string(@core.model_spec_for(open.model_id).0.label())),
      ("interrupted", Json::boolean(interrupted)),
      // The question the interrupted turn was asked, read back from the log rather than retyped:
      // continuing means carrying on with the same question, and the reader should be shown which
      // one they are being offered.
      (
        "interrupted_prompt",
        Json::string(
          match open.session.in_flight_prompt() {
            Some(prompt) => prompt
            None => ""
          },
        ),
      ),
    ]),
  )
}

///|
/// Put a session on screen for a host that has never seen it: which one it is, and the whole of what is
/// in it.
///
/// The history is the part that is only ever sent once. A host keeps a transcript per session, so a
/// session it has already been told about — or has been watching deltas of — needs no replay: sending
/// one would *replace* a transcript that is more up to date than the log, because a running turn's rows
/// are on the host and not yet in the session it is holding. That is not a hypothetical: it is what a
/// reader would see as "the answer I was watching disappeared when I came back".
fn say_open(open : Open) -> Unit {
  say_show(open)
  say_history(open.path, open.session)
}

///|
/// Put a session on screen: which one it is, and the snapshots that belong to it.
///
/// Everything but the history, which is what a re-show wants. The figures come along because a switch
/// changes which session's numbers are on screen, the model it runs on, and therefore whether a picture
/// can be attached to it at all — none of which the host can work out from the rows alone.
fn say_show(open : Open) -> Unit {
  say_session(open)
  say_usage(open)
  say_models(open)
  say_images(open)
}

///|
/// The conversation of a session, as rows the host can draw.
///
/// One place, because two situations need it and they are the same situation: a switch, where the host
/// is looking at the wrong session, and a startup on a resumed session, where it is looking at none.
fn say_history(path : String, session : @core.Session) -> Unit {
  emit(
    session_event(path, "history", [
      ("rows", Json::array(history_rows(session))),
    ]),
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
/// Start a session in the same directory, and show it.
///
/// The file is not written here, and that is deliberate rather than lazy: a session with nothing in
/// it is a header-only file nobody asked for, and the first prompt is what writes the first line. The
/// store therefore does not list it yet — `say_sessions` carries it anyway.
async fn Shell::create(self : Shell) -> Unit {
  self.open_fresh(self.shown().cwd)
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
  say_open(open)
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

///|
/// Take a session out of the store, by renaming it aside.
///
/// Not the one that is open, which is a request that cannot be carried out and would leave the window
/// showing a file that is no longer in the list. Refused rather than done quietly.
async fn Shell::discard(self : Shell, path : String) -> Unit {
  if path == "" {
    say_error("delete: no session path")
    self.say_sessions()
    return
  }
  if path == self.current {
    say_error("cannot delete the session that is open")
  } else if !@platform.path_exists(path) {
    say_error("that session is already gone")
  } else if self.open_of(path) is Some(open) && open.busy {
    // The one case where deleting would lose work rather than tidy up: a turn is appending to this file
    // right now. Reachable since more than one conversation can run at once — the reader can switch away
    // from a long turn and then clear it out of the sidebar while it is still writing.
    say_error("cannot delete a session with a turn running — stop it first")
  } else {
    @platform.delete_session(path)
    self.labels.forget(path)
  }
  self.say_sessions()
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
}

///|
/// One block of text as the host draws it: parsed markdown, or null when there is nothing to parse.
///
/// Null rather than an empty array, because "this row has no markdown" and "this row's markdown is
/// empty" are the same fact, and the host's rule is the simple one: parsed blocks or the text.
fn blocks_of(text : String) -> Json {
  if text == "" {
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
  { kind: "note", id, text, name: label, detail: "", call_id: "", }
}

///|
fn text_draft(kind : String, id : String, text : String) -> Draft {
  { kind, id, text, name: "", detail: "", call_id: "", }
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
/// The conversation so far, as the rows the host would have built from the events.
///
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
        let text = content_text(user.content)
        if text != "" {
          drafts.push(text_draft("user", next_id(), text))
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
          ("blocks", blocks_of(draft.text)),
          ("name", Json::string(draft.name)),
          ("detail", Json::string(draft.detail)),
          ("output", Json::string(output)),
          ("error", Json::boolean(is_error)),
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
/// where pi keeps it and a name has to survive being read back by another front end. It also means
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
    say_show(open)
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
async fn dismiss_turn(open : Open) -> Unit {
  if !open.session.turn_in_flight() {
    say_error(
      "nothing to dismiss: that turn has already ended",
      session=open.path,
    )
    say_open(open)
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
  say_open(open)
}
