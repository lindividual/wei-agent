///|
/// Session files on disk.
///
/// Appends rewrite the whole file rather than opening it in append mode. A
/// session is small enough that the difference does not matter, and rewriting
/// means a reader never observes a half-written line.

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
  let existing = if path_exists(path) { read_text(path) } else { "" }
  write_text(path, existing + entry.to_line())
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
  let existing = if path_exists(path) { read_text(path) } else { "" }
  out.write_string(existing)
  for entry in entries {
    out.write_string(entry.to_line())
  }
  write_text(path, out.to_string())
}

///|
/// The most recently modified session file under a directory, or `None` when
/// there is none.
pub async fn newest_session(dir : String) -> String? {
  if !path_exists(dir) {
    return None
  }
  let names = list_entries(dir)
  let mut best : String? = None
  for name in names {
    if !name.has_suffix(".jsonl") {
      continue
    }
    // Names are `<timestamp>_<id>.jsonl`, so lexical order is time order and the
    // last one wins without touching any file's metadata.
    best = match best {
      Some(current) => if name > current { Some(name) } else { Some(current) }
      None => Some(name)
    }
  }
  match best {
    Some(name) => Some("\{dir}/\{name}")
    None => None
  }
}
