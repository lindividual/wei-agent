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
