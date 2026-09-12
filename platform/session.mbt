///|
/// Session files on disk.
///
/// Appends are real appends. Rewriting the whole file instead would make every
/// entry a read-modify-write, which loses entries as soon as two writers overlap
/// (a browser tab and the CLI, or two tabs) and costs O(n²) over a session. A
/// single `write` of one line is what a reader can safely race with: it either
/// sees the line or it does not.

///|
/// Load a session from a file.
pub async fn load_session(path : String) -> @core.Session {
  @core.parse_session_file(read_text(path))
}

///|
/// Write a session header, creating the directory. Overwrites, so callers must
/// have chosen a fresh path.
pub async fn create_session(
  path : String,
  header : @core.SessionHeader,
) -> Unit {
  make_dirs(@core.parent_of(path))
  write_text(path, header.to_line())
}

///|
/// Make sure a session file exists, with its header.
///
/// Sessions are created empty and filled in later, so the file is written by
/// whoever appends the first entry. That keeps a store from filling up with
/// header-only files for sessions nobody ever used, which is what a picker would
/// otherwise have to show and a reader would have to scroll past.
pub async fn ensure_session(
  path : String,
  header : @core.SessionHeader,
) -> Unit {
  if !path_exists(path) {
    create_session(path, header)
  }
}

///|
/// Append one entry.
///
/// The entry's parent is expected to be the current leaf, which the caller
/// controls: the session is append-only and the driver decides where the leaf is.
pub async fn append_entry(path : String, entry : @core.Entry) -> Unit {
  append_text(path, entry.to_line())
}

///|
/// Append several entries in one write.
pub async fn append_entries(
  path : String,
  entries : Array[@core.Entry],
) -> Unit {
  if entries.is_empty() {
    return
  }
  let out = StringBuilder()
  for entry in entries {
    out.write_string(entry.to_line())
  }
  append_text(path, out.to_string())
}

///|
/// Delete the sessions in this directory that hold nothing.
///
/// A header-only file is what an opened-but-unused session looks like. They used to be
/// written on every start, and a picker full of them is worse than useless: it hides
/// the conversations that exist behind rows that lead nowhere.
///
/// Two guards keep this from touching anything real. Only files small enough to be a
/// header are considered, so a long conversation is never even read; and only files
/// older than `min_age_ms`, so a session another instance is creating right now is
/// left alone. Returns how many were removed.
pub async fn prune_empty_sessions(dir : String, min_age_ms : Int64) -> Int {
  if !path_exists(dir) {
    return 0
  }
  let now = @env.now().reinterpret_as_int64()
  let mut removed = 0
  for name in list_entries(dir) {
    if !name.has_suffix(".jsonl") {
      continue
    }
    let file = "\{dir}/\{name}"
    let prefix = read_prefix(file, 4096)
    // A file with any message in it is a conversation, whatever else it holds.
    let mut has_message = false
    for raw in prefix.split("\n") {
      let line = raw.trim()
      if line.contains("\"role\"") {
        has_message = true
        break
      }
    }
    if has_message {
      continue
    }
    let (seconds, nanos) = @fs.mtime(file)
    let modified = seconds * 1000L + nanos.to_int64() / 1000000L
    if now - modified < min_age_ms {
      continue
    }
    try @fs.remove(file) catch {
      _ => ()
    } noraise {
      _ => removed += 1
    }
  }
  removed
}

///|
/// A workspace that has been added, whether or not it has been used.
///
/// The store directory's name encodes the path lossily, so a directory with no sessions in it
/// cannot say where it points. This is the small file that can — and it is where a reader's own
/// name for the workspace lives, since the path is rarely what they call it.
///
/// Kept inside the workspace's own store directory rather than in one registry file: deleting a
/// directory then forgets the workspace, and there is no second place that can disagree with
/// what is on disk.
pub(all) struct WorkspaceRecord {
  cwd : String
  title : String?
} derive(Eq, Debug)

///|
pub fn workspace_marker(dir : String) -> String {
  "\{dir}/workspace.json"
}

///|
pub async fn read_workspace(dir : String) -> WorkspaceRecord? {
  let path = workspace_marker(dir)
  if !path_exists(path) {
    return None
  }
  let parsed = try @json.parse(read_prefix(path, 8192)) catch {
    // A marker nobody can read is not a workspace description; the sessions are still usable, so
    // this degrades to "no marker" rather than failing the listing.
    _ => return None
  } noraise {
    json => json
  }
  match parsed {
    Object(fields) =>
      match fields.get("cwd") {
        Some(String(cwd)) if cwd != "" => {
          let title = match fields.get("title") {
            Some(String(title)) if title != "" => Some(title)
            _ => None
          }
          Some({ cwd, title, })
        }
        _ => None
      }
    _ => None
  }
}

///|
pub async fn write_workspace(dir : String, record : WorkspaceRecord) -> Unit {
  make_dirs(dir)
  let fields : Array[(String, Json?)] = [
    ("cwd", Some(Json::string(record.cwd))),
    (
      "title",
      match record.title {
        Some(title) => Some(Json::string(title))
        None => None
      },
    ),
  ]
  write_text(workspace_marker(dir), Json::object(obj_pairs(fields)).stringify())
}

///|
/// Drop the entries whose value is absent, since a JSON object cannot hold an explicit null here
/// without changing what a reader of the file would see.
fn obj_pairs(fields : Array[(String, Json?)]) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for entry in fields {
    let (key, value) = entry
    match value {
      Some(value) => out.set(key, value)
      None => ()
    }
  }
  out
}

///|
/// A session file on disk, with when it was last written.
pub(all) struct StoredSession {
  path : String
  /// Milliseconds since the epoch.
  modified : Int64
} derive(Eq, Debug)

///|
/// Session files directly inside a directory, newest first.
///
/// `dir` is one working directory's slice of the store — `session_dir_for(root,
/// cwd)` — not the store root: what a picker offers is the sessions for the
/// directory the agent works in, and nothing else.
///
/// Sorted by modification time rather than by name: the name carries the session's
/// *start* time, so a session resumed today would sort behind one that merely
/// started later and was abandoned. A missing directory is an empty list — a fresh
/// install has no sessions, which is not a failure.
pub async fn list_sessions(dir : String) -> Array[StoredSession] {
  sessions_in(dir)
}

///|
/// The same listing, without the "missing directory is fine" framing.
async fn sessions_in(dir : String) -> Array[StoredSession] {
  if !path_exists(dir) {
    return []
  }
  let out : Array[StoredSession] = []
  for name in list_entries(dir) {
    if !name.has_suffix(".jsonl") {
      continue
    }
    let file = "\{dir}/\{name}"
    // Checked rather than assumed: a directory can carry a `.jsonl` name, and an
    // entry that cannot be read is worse than one that is not listed.
    if is_directory(file) {
      continue
    }
    let (seconds, nanos) = @fs.mtime(file)
    out.push({
      path: file,
      modified: seconds * 1000L + nanos.to_int64() / 1000000L,
    })
  }
  if out.length() > 1 {
    out.sort_by((a, b) => {
      if a.modified != b.modified {
        // Newest first, and ties broken by path so the order is deterministic.
        if a.modified > b.modified {
          -1
        } else {
          1
        }
      } else if a.path > b.path {
        -1
      } else {
        1
      }
    })
  }
  out
}

///|
/// A working directory with saved sessions.
pub(all) struct StoredWorkspace {
  /// The store directory holding them.
  dir : String
  /// Where the agent works, as a canonical path.
  cwd : String
  /// What to call it, when the reader has said. `None` means "use the last path component".
  title : String?
  /// Newest first, capped by the caller.
  sessions : Array[StoredSession]
  /// How many sessions the workspace holds, including the ones not listed.
  total : Int
  /// Last write across the workspace, for ordering the list.
  modified : Int64
} derive(Eq, Debug)

///|
/// Every workspace in the store that has at least one session, most recently used
/// first.
///
/// The cwd comes from the newest session's header rather than from the directory
/// name, which cannot be decoded back (see `cwd_of_session_file`). Only that one
/// session is read: every session in a directory is there because it shares that
/// cwd.
///
/// A directory whose newest session has an unreadable header is skipped rather than
/// guessed at — listing it under the wrong directory would offer to move the agent
/// somewhere it has never been.
pub async fn list_workspaces(
  root : String,
  max_sessions : Int,
) -> Array[StoredWorkspace] {
  let out : Array[StoredWorkspace] = []
  if !path_exists(root) {
    return out
  }
  for name in list_entries(root) {
    let dir = "\{root}/\{name}"
    if !is_directory(dir) {
      continue
    }
    let sessions = sessions_in(dir)
    // A workspace that has been added but not used yet has no sessions and no headers to read
    // its path from; the marker it was added with is what makes it a workspace.
    let marker = read_workspace(dir)
    let cwd = match marker {
      Some(record) => Some(record.cwd)
      None =>
        if sessions.is_empty() {
          None
        } else {
          @core.cwd_of_session_file(read_prefix(sessions[0].path, 8192))
        }
    }
    let cwd = match cwd {
      Some(cwd) => cwd
      // Nothing to attribute this directory to. Skipped rather than guessed at: listing it under
      // the wrong path would offer to move the agent somewhere it has never been.
      None => continue
    }
    let title = match marker {
      Some(record) => record.title
      None => None
    }
    let shown = if sessions.length() > max_sessions {
      sessions[:max_sessions].to_owned()
    } else {
      sessions
    }
    let modified = if sessions.is_empty() {
      // An empty workspace sorts by when it was added.
      match @fs.mtime(dir) {
        (seconds, nanos) => seconds * 1000L + nanos.to_int64() / 1000000L
      }
    } else {
      sessions[0].modified
    }
    out.push({
      dir,
      cwd,
      title,
      sessions: shown,
      total: sessions.length(),
      modified,
    })
  }
  if out.length() > 1 {
    out.sort_by((a, b) => {
      if a.modified != b.modified {
        if a.modified > b.modified {
          -1
        } else {
          1
        }
      } else if a.cwd > b.cwd {
        -1
      } else {
        1
      }
    })
  }
  out
}

///|
/// The session file whose name carries this id, anywhere in the store.
///
/// Across workspaces rather than only the starting directory: the store holds every
/// directory the agent has worked in, and an id is enough to identify one — which is
/// also what makes `--resume <id>` agree with what the sidebar offers.
pub async fn find_session(root : String, id : String) -> String? {
  if id == "" || !path_exists(root) {
    return None
  }
  for name in list_entries(root) {
    let dir = "\{root}/\{name}"
    if !is_directory(dir) {
      continue
    }
    for file in list_entries(dir) {
      if file.has_suffix("_\{id}.jsonl") {
        return Some("\{dir}/\{file}")
      }
    }
  }
  None
}

///|
/// The newest session file for one working directory, which is what
/// `--continue` means.
pub async fn newest_session(root : String, cwd : String) -> String? {
  let sessions = list_sessions(@core.session_dir_for(root, cwd))
  if sessions.is_empty() {
    None
  } else {
    Some(sessions[0].path)
  }
}
