///|
/// The session list: the labels it shows, and where they come from.
///
/// The sidebar is a picker over every workspace the store knows about, which makes it the one part
/// of the page whose cost grows with the store. Two things deal with that: `LabelCache` remembers
/// the facts derived from a session file (its label, its name) keyed by modification time, so
/// redrawing the list does not re-read every session; and the label is read from a bounded prefix,
/// because describing a file should not cost as much as replaying it.
///
/// Folding is the browser's job — each workspace is a native `<details>` — so nothing here holds
/// state that the reader can see.

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
/// Forget what was cached about one path.
///
/// Called when the file moves — deleted or restored — because the cache is keyed by path and has no
/// other way to learn that the thing it describes is somewhere else now. Without this, a restored
/// session keeps whatever was cached at the moment it was deleted, and the row can show a label for
/// a file that is no longer there.
pub fn LabelCache::forget(self : LabelCache, path : String) -> Unit {
  self.entries.remove(path)
}

///|
/// When the cache last saw this path, or 0 when it has not.
///
/// The modification time is otherwise only known to whoever listed the store; the notice that says
/// what was deleted has a path and nothing else, so it asks the cache for the fact that goes with
/// it.
pub fn LabelCache::modified_of(self : LabelCache, path : String) -> Int64 {
  match self.entries.get(path) {
    Some((modified, _)) => modified
    None => 0L
  }
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
  // Empty for a file that is not there. A session is created before it is written — the first
  // prompt is what puts a line in it — and something asking what to call it in that window is
  // asking about a conversation with nothing in it yet, which is a description and not a failure.
  let text = @platform.read_text_or_none(path).unwrap_or("")
  let facts : SessionFacts = {
    // The first user message is near the top of the file, so the label only needs the beginning.
    label: @core.session_label(prefix_of(text, 16 * 1024)),
    // The name, on the other hand, only exists if the log holds a rename — and finding out by
    // parsing the whole file was, measured, most of what building the sidebar cost. A log with no
    // rename has no name to find, so the parse is skipped; one that has any pays for it as before.
    // `false` is a definite answer, and `true` only means "look properly".
    name: if @core.log_has_name_entry(text) {
      session_name_of(text)
    } else {
      None
    },
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
/// The label decision the sidebar makes, in one place.
///
/// Called by the row renderer and by the notice that says what was deleted, so the notice names the
/// session the way the reader last saw it — a name they gave, else the first question, else the id.
/// Two copies of this would drift, and the one that drifted would be the confirmation.
async fn App::session_label(
  self : App,
  path : String,
  modified : Int64,
) -> String {
  let facts = self.labels.label(path, modified)
  match facts.name {
    Some(name) => name
    None =>
      // Failing a name, the first question — except for a session whose first turn is still
      // running, where the file has no label yet and "empty session" would be wrong for the five
      // minutes a long turn takes. The running turn is what we do know.
      if facts.label == "" {
        match self.runner(path) {
          Some(runner) => @html.clip_label(runner.prompt)
          None => short_id(path)
        }
      } else {
        facts.label
      }
  }
}

///|
/// The sidebar's view of the store: every workspace that has sessions, newest first,
/// each described from the top of its newest file.
///
/// Bounded per file and per workspace on purpose. Describing a workspace means reading
/// one header, and a sidebar that read every session in full would make opening the UI
/// cost as much as replaying all of them. The cap is applied *here* rather than in the
/// store because it is a decision about a column — and because the reader can lift it
/// for one workspace at a time, which only this side knows.
async fn workspace_items(
  app : App,
  shown : Runner,
) -> Array[@html.WorkspaceItem] {
  let out : Array[@html.WorkspaceItem] = []
  for stored in @platform.list_workspaces(app.root) {
    let cap = if app.expanded.get(stored.cwd).unwrap_or(false) {
      stored.sessions.length()
    } else {
      sidebar_sessions()
    }
    let listed = if stored.sessions.length() > cap {
      stored.sessions[:cap]
    } else {
      stored.sessions
    }
    let sessions : Array[@html.SessionItem] = []
    for session in listed {
      sessions.push({
        path: session.path,
        label: app.session_label(session.path, session.modified),
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
      hidden: stored.sessions.length() - sessions.length(),
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
/// How many sessions a workspace shows before it offers the rest.
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
/// The sidebar as HTML, for the session being displayed.
async fn workspace_items_and_render(app : App, shown : Runner) -> String {
  let now = @env.now().reinterpret_as_int64()
  let items = workspace_items(app, shown)
  @html.render_sessions(items, now, app.can_pick, notice=app.deleted).render()
}
