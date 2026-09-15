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
  let groups : Array[(String, String, Bool, Array[Json])] = []
  let mut listed = false
  for stored in @platform.list_workspaces(self.root) {
    let rows : Array[Json] = []
    for session in stored.sessions {
      let current = session.path == self.path
      if current {
        listed = true
      }
      rows.push(
        session_row(
          session.path,
          self.label_of(session.path, session.modified),
          session.modified,
          current,
          current && self.busy,
        ),
      )
    }
    groups.push(
      (stored.cwd, workspace_label(stored), stored.cwd == self.cwd, rows),
    )
  }
  if !listed {
    // Created in this process and never written, so it has no modification time of its own. Now is
    // the honest stand-in: it was created now, and a reader seeing "just now" is being told the
    // right thing about it.
    let row = session_row(
      self.path,
      self.label_of(self.path, 0L),
      @env.now().reinterpret_as_int64(),
      true,
      self.busy,
    )
    let mut placed = false
    for i in 0..<groups.length() {
      // Only to find the group: `rows` is a reference, so inserting into it has already changed the
      // tuple's own array and no write-back is needed.
      let (cwd, _, _, rows) = groups[i]
      if cwd == self.cwd {
        rows.insert(0, row)
        placed = true
        break
      }
    }
    if !placed {
      groups.insert(0, (self.cwd, workspace_name(self.cwd), true, [row]))
    }
  }
  emit(sessions_event(groups))
}

// ── switching ──────────────────────────────────────────────────────────────

///|
/// The session that is now open: which file, where its tools run, and which model it runs on.
///
/// Sent on its own so that the host can stop showing one transcript before the next arrives. The two
/// events are a pair, and the state between them — a window with no session on screen — is a state
/// the host should be able to draw rather than avoid.
fn say_session(shell : Shell) -> Unit {
  emit(
    event("session", [
      ("path", Json::string(shell.path)),
      ("cwd", Json::string(shell.cwd)),
      ("model", Json::string(@core.model_spec_for(shell.model_id).0.label())),
    ]),
  )
}

///|
/// Everything the host needs to draw a session it did not watch: which one it is, and what is in it.
fn say_open(shell : Shell) -> Unit {
  say_session(shell)
  say_history(shell.session)
}

///|
/// The conversation of a session, as rows the host can draw.
///
/// One place, because two situations need it and they are the same situation: a switch, where the host
/// is looking at the wrong session, and a startup on a resumed session, where it is looking at none.
fn say_history(session : @core.Session) -> Unit {
  emit(event("history", [("rows", Json::array(history_rows(session)))]))
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
/// Show a session that is already on disk.
///
/// Refused while a turn runs, by the caller: a turn owns the session it is working on — it appends
/// to the file and writes the session back at every commit — so pointing the window somewhere else
/// mid-turn would leave the reader looking at a transcript that is not the one still being written.
async fn Shell::show(self : Shell, path : String) -> Unit {
  if path == self.path {
    return
  }
  if !@platform.path_exists(path) {
    say_error("no session at \{path}")
    self.say_sessions()
    return
  }
  let session = @platform.load_session(path)
  // The same repair a resumed session gets: a turn that died leaves tool calls the provider would
  // reject, and the closers go into the log rather than only into memory.
  let entries = session.repair_entries(@env.now().reinterpret_as_int64())
  let loaded = if entries.length() > 0 {
    @platform.append_entries(path, entries)
    session.add_entries(entries)
  } else {
    session
  }
  self.session = loaded
  self.path = path
  self.cwd = loaded.header.cwd
  self.model_id = session_model(loaded)
  say_open(self)
  self.say_sessions()
}

///|
/// Start a session in the same directory, and show it.
///
/// The file is not written here, and that is deliberate rather than lazy: a session with nothing in
/// it is a header-only file nobody asked for, and the first prompt is what writes the first line. The
/// store therefore does not list it yet — `say_sessions` carries it anyway.
async fn Shell::create(self : Shell) -> Unit {
  let (session, path) = fresh_session(self.root, self.cwd)
  self.session = session
  self.path = path
  say_open(self)
  self.say_sessions()
}

///|
/// Take a session out of the store, by renaming it aside.
///
/// Not the one that is open, which is a request that cannot be carried out and would leave the window
/// showing a file that is no longer in the list. Refused rather than done quietly.
async fn Shell::discard(self : Shell, path : String) -> Unit {
  if path == self.path {
    say_error("cannot delete the session that is open")
  } else if !@platform.path_exists(path) {
    say_error("that session is already gone")
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
      @core.CompactionSummary(summary~, ..) =>
        append_text(drafts, "note", next_id(), summary)
      @core.BranchSummary(summary~, ..) =>
        append_text(drafts, "note", next_id(), summary)
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
          // Everything in a history is over: nothing here is still arriving, which is what lets the
          // host render its markdown.
          ("complete", Json::boolean(true)),
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
