///|
/// Filesystem access for the tools.
///
/// Everything here is a thin wrapper: the point is to keep `core/` free of IO so
/// its logic compiles and tests everywhere, not to abstract the filesystem into
/// something richer.

///|
pub async fn read_text(path : String) -> String {
  @fs.read_file(path).text()
}

///|
pub async fn write_text(path : String, content : String) -> Unit {
  @fs.write_file(path, content)
}

///|
/// Add to the end of a file, creating it if needed.
///
/// A real `O_APPEND` write rather than read-then-rewrite: a session log is
/// appended to from more than one place over its life, and rewriting the whole
/// file to add one line loses whatever another writer added in between. The
/// kernel appends the whole write, so a reader sees a line or nothing, never half
/// of two.
pub async fn append_text(path : String, content : String) -> Unit {
  @fs.write_file(
    path,
    content,
    append=true,
    create_mode=@fs.CreateMode::OpenOrCreate,
  )
}

///|
/// The first `max_bytes` of a file, decoded lossily.
///
/// Used to describe a session without parsing it. A prefix can end mid-character
/// and mid-line; the lossy decode and the caller's tolerance of an unparsable last
/// line are what make a byte-bounded read usable for a line-oriented file.
pub async fn read_prefix(path : String, max_bytes : Int) -> String {
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly)
  defer file.close()
  let size = file.size()
  let wanted = if size < max_bytes.to_int64() {
    size.to_int()
  } else {
    max_bytes
  }
  if wanted <= 0 {
    return ""
  }
  let buffer = FixedArray::make(wanted, b'\x00')
  let read = file.read_at(buffer, position=0L, len=wanted)
  let exact = FixedArray::make(read, b'\x00')
  for i in 0..<read {
    exact[i] = buffer[i]
  }
  @utf8.decode_lossy(Bytes::from_array(exact))
}

///|
pub async fn path_exists(path : String) -> Bool {
  @fs.exists(path)
}

///|
/// Whether the path is a directory.
///
/// Opening it is the only reliable test, and opening a file fails — so a failure
/// is the answer, not an error. Raising here would make every caller handle a
/// question it only asked to get a boolean back.
pub async fn is_directory(path : String) -> Bool {
  try {
    let dir = @fs.opendir(path)
    dir.close()
    true
  } catch {
    _ => false
  } noraise {
    result => result
  }
}

///|
/// Create a directory and any missing parents.
///
/// Failing because the directory already appeared is not a failure: concurrent
/// callers can both find it missing and both try to create it. Only a directory
/// that still does not exist afterwards is an error.
///
/// That retry is not paranoia. A recursive create is not atomic: it walks up to
/// the first missing parent, creates it, and comes back down — and a second task
/// that created a sibling in the meantime leaves the walk with a parent that is
/// suddenly already there, which fails the whole call even though its own target
/// is untouched. On the second attempt the parent exists, so only the last
/// component has to be created, which does tolerate it.
pub async fn make_dirs(path : String) -> Unit {
  if path == "" || path == "/" || @fs.exists(path) {
    return
  }
  for _ in 0..<2 {
    try @fs.mkdir(path, recursive=true) catch {
      _ => ()
    } noraise {
      _ => ()
    }
    if @fs.exists(path) {
      return
    }
  }
  raise Failure::Failure("could not create directory: \{path}")
}

///|
/// Entry names in a directory, unsorted.
pub async fn list_entries(path : String) -> Array[String] {
  @fs.readdir(path)
}

///|
/// Directories and files under a root, as paths relative to it.
///
/// Walks in a single task so the order is deterministic: a tool result that
/// reorders itself between runs is impossible to test.
pub async fn walk_paths(root : String, max_entries : Int) -> Array[String] {
  let out : Array[String] = []
  let dirs : Array[String] = [root]
  while !dirs.is_empty() && out.length() < max_entries {
    let dir = dirs.remove(0)
    let names = @fs.readdir(dir)
    for name in names {
      if out.length() >= max_entries {
        break
      }
      let full = if dir == "/" || dir == "" {
        "\{dir}\{name}"
      } else {
        "\{dir}/\{name}"
      }
      if is_directory(full) {
        dirs.push(full)
      } else {
        out.push(full)
      }
    }
  }
  out
}

///|
/// The platform's environment, as a map for the process layer.
pub fn current_dir() -> String {
  match @env.current_dir() {
    Some(dir) => dir
    None => "/"
  }
}
