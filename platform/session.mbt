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
  /// Newest first, every session the workspace holds.
  ///
  /// Not capped here. A list is a *display* limit — one workspace showing its ten newest is a
  /// decision about a column, not about a store — and the caller that draws the column is the one
  /// that also knows when the reader asked to see past it.
  sessions : Array[StoredSession]
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
///
/// Every session of every workspace is listed, however many there are. That is a
/// readdir and a stat per file — both of which the ordering already needs — and what
/// it costs is bounded by the store rather than by the page. What is *not* done here
/// is reading the sessions themselves: a description is read per session the caller
/// decides to show, so "how much of this does the page replay" stays the caller's
/// question.
pub async fn list_workspaces(root : String) -> Array[StoredWorkspace] {
  let out : Array[StoredWorkspace] = []
  if !path_exists(root) {
    return out
  }
  for name in list_entries(root) {
    // A workspace that has been removed is still a directory on disk — that is what makes the removal
    // recoverable — and its name is the whole of what keeps it out of this listing. See
    // `remove_workspace`.
    if name.has_suffix(removed_suffix()) {
      continue
    }
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
    let modified = if sessions.is_empty() {
      // An empty workspace sorts by when it was added.
      match @fs.mtime(dir) {
        (seconds, nanos) => seconds * 1000L + nanos.to_int64() / 1000000L
      }
    } else {
      sessions[0].modified
    }
    out.push({ dir, cwd, title, sessions, modified, })
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
    // Including a removed workspace's sessions would make `--resume` reach into a project the sidebar
    // has been told to forget.
    if name.has_suffix(removed_suffix()) {
      continue
    }
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

///|
/// What a deleted session's name carries, so it is out of every listing but still on disk.
///
/// `sessions_in` filters by `.jsonl`, so moving the name out of that suffix is the entire
/// mechanism: nothing else has to learn a rule about trash, and the bytes stay where they were.
/// That second part is what makes a mis-click recoverable by hand, in a shell, after the page that
/// offered to undo it is long gone. A conversation log is the thing this program makes; an
/// accidental click should not be able to destroy one.
pub fn deleted_suffix() -> String {
  ".deleted"
}

///|
/// Take a session out of the store by renaming it aside.
///
/// A rename rather than a removal, for the reason above. Failing is silent by design: the reader
/// asked for it to be out of the list, and afterwards it is out of the list — a file that was
/// already gone, or a directory that cannot be written, is not something they can act on. The
/// caller checks whether it was there if it needs to say so.
pub async fn delete_session(path : String) -> Unit {
  try @fs.rename(path, path + deleted_suffix()) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Put a deleted session back where it was. The inverse of `delete_session`, and a no-op when there
/// is nothing to put back — a stale Undo button in an old tab, or a second click.
pub async fn restore_session(path : String) -> Unit {
  try @fs.rename(path + deleted_suffix(), path) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Take a session out of the store **and off the disk**.
///
/// The one destructive operation this program has, and it exists because a store with no way to empty
/// it grows forever: a delete that only renames leaves a file per `Delete` click, and the only way to
/// reclaim them is to find the directory in a shell. What that costs is stated where the reader makes
/// the choice — the dialog says so, and the checkbox is off by default.
///
/// **The rename happens first, and the removal is of the renamed file.** That is not two ways to do
/// one thing: a rename is atomic and a removal is not, so going through the aside-copy means the
/// window never sees a half-deleted session — either it is in the store or it is in the trash, and the
/// trash is emptied afterwards. A removal that fails leaves the file in exactly the state a plain
/// delete leaves it, which is the recoverable one.
pub async fn purge_session(path : String) -> Unit {
  delete_session(path)
  delete_file(path + deleted_suffix())
}

///|
/// What a removed workspace's directory is renamed to, so it is out of every listing but still on
/// disk.
///
/// The same mechanism as `deleted_suffix`, one level up: `list_workspaces` filters by this suffix, so
/// renaming the directory is the whole of what "removed" means. The sessions inside keep their own
/// names, because they are not deleted — they are in a project the sidebar has been told to forget.
///
/// **A directory rather than a marker file, and this is the one place the two kinds of forgetting
/// differ.** A session is one file, so a rename is the whole of it. A workspace *is* its directory, and
/// a marker saying "ignore me" would leave the reader with two things to undo and no way to tell from
/// the store which of them was in force.
fn removed_suffix() -> String {
  ".removed"
}

///|
/// Take a workspace out of the sidebar, keeping its conversations, and say where it went.
///
/// The directory is renamed aside rather than removed, for the reason `delete_session` renames a file:
/// an accidental click should not be able to destroy a conversation, and here it would take all of
/// them. What is left behind is `--Users-me-src--.removed` under the store root, with every session
/// exactly where it was — and that path is the return value, because it is the only way back: the
/// listing no longer knows this workspace, so nothing else can find it again.
///
/// `None` means nothing moved: a workspace the store does not list (which includes one already
/// removed), or a rename that failed.
///
/// The cwd alone is not enough to find it: the directory name is derived from the path (see
/// `session_dir_name`) and `list_workspaces` reads the real path out of the sessions' headers. So this
/// resolves the directory from the listing first — the same listing the sidebar was drawn from —
/// rather than renaming a name it guessed at.
pub async fn remove_workspace(root : String, cwd : String) -> String? {
  let dir = match workspace_dir_for(root, cwd) {
    Some(dir) => dir
    None => return None
  }
  let aside = dir + removed_suffix()
  try @fs.rename(dir, aside) catch {
    _ => return None
  } noraise {
    _ => ()
  }
  Some(aside)
}

///|
/// Empty a workspace that `remove_workspace` renamed aside, taking every conversation with it.
///
/// **Handed the path `remove_workspace` returned, not a working directory**, and that is the whole of
/// the division of labour between the two: a rename is atomic and a recursive removal is not, so the
/// removal is of the aside-copy. Done in one step instead, a failure could leave a project that is
/// half emptied *and still listed*; done in this order a failure leaves the state the reader could
/// have chosen anyway — out of the list, conversations on disk.
///
/// Returns whether the directory is gone. The caller reports which of the two it got, because this is
/// the only irreversible operation in the program.
pub async fn purge_workspace(aside : String) -> Bool {
  try @fs.rmdir(aside, recursive=true) catch {
    _ => return false
  } noraise {
    _ => ()
  }
  true
}

///|
/// Where a working directory's slice of the store is, as the listing sees it.
///
/// By resolved path rather than by the directory name, for the reason the listing itself gives: the
/// name encodes the path, and decoding it back is ambiguous (`--a-b--` is both `a/b` and the one
/// directory `a-b`). A removed workspace is deliberately not found here — it is no longer in the
/// store's list.
async fn workspace_dir_for(root : String, cwd : String) -> String? {
  for stored in list_workspaces(root) {
    if stored.cwd == cwd {
      return Some(stored.dir)
    }
  }
  None
}
