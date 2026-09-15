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
/// Read a file as UTF-8 text, or `None` when it is not valid UTF-8.
///
/// `read_text` raises on invalid bytes. That is right for a file whose format is text by
/// definition — a session log with a broken encoding is a real problem — but wrong for a tool
/// that walks a repository, where a binary is an ordinary thing to meet. A tool that cannot
/// tell the two apart turns "there is a `.png` under this directory" into a dead turn, so it
/// asks this instead and decides what a decode failure means in its own case.
pub async fn read_text_or_none(path : String) -> String? {
  Some(read_text(path)) catch {
    _ => None
  }
}

///|
/// The first `max_bytes` of a file, decoded lossily.
///
/// Used to describe a session without parsing it. A prefix can end mid-character
/// and mid-line; the lossy decode and the caller's tolerance of an unparsable last
/// line are what make a byte-bounded read usable for a line-oriented file.
pub async fn read_prefix(path : String, max_bytes : Int) -> String {
  // A missing file reads as empty rather than raising. Everything that calls this is
  // describing a file — a session's label, its workspace — and "there is nothing there"
  // is a description. Raising instead turned a session that had not been written yet
  // into a failure of whatever happened to be asking.
  if !path_exists(path) {
    return ""
  }
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
/// How many bytes a file holds, or zero when it is not there.
///
/// A file's size is the one thing about it that is true of the bytes rather than of their decoding:
/// a caller that has read a file as text and wants to resume from where it stopped needs this, not
/// the length of the text, which a lossy decode changes.
pub async fn file_size(path : String) -> Int64 {
  if !path_exists(path) {
    return 0L
  }
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly)
  defer file.close()
  file.size()
}

///|
/// A slice of a file, from a byte offset, bounded by a byte count.
///
/// Returns the text, how many bytes of the file it consumed, and the file's size — the last two so
/// a caller that is following a file as it grows can decide whether anything is left, and where to
/// start next, without another syscall.
///
/// The slice is cut on a character boundary. A caller of this is reading a file whose end is not
/// under its control — a running process's output — so a cut in the middle of a character is the
/// normal case rather than an error, and the next read would begin inside the same character, which
/// the lossy decode turns into a replacement character that was never written.
pub async fn read_slice(
  path : String,
  offset : Int,
  max_bytes : Int,
) -> (String, Int, Int64) {
  if !path_exists(path) {
    return ("", 0, 0L)
  }
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly)
  defer file.close()
  let size = file.size()
  if size <= offset.to_int64() || max_bytes <= 0 {
    return ("", 0, size)
  }
  let wanted = if size - offset.to_int64() < max_bytes.to_int64() {
    (size - offset.to_int64()).to_int()
  } else {
    max_bytes
  }
  let buffer = FixedArray::make(wanted, b'\x00')
  let read = file.read_at(buffer, position=offset.to_int64(), len=wanted)
  let exact = FixedArray::make(read, b'\x00')
  for i in 0..<read {
    exact[i] = buffer[i]
  }
  let bytes = Bytes::from_array(exact)
  let cut = utf8_cut(bytes, read)
  if cut != read {
    let shortened = FixedArray::make(cut, b'\x00')
    for i in 0..<cut {
      shortened[i] = exact[i]
    }
    return (@utf8.decode_lossy(Bytes::from_array(shortened)), cut, size)
  }
  (@utf8.decode_lossy(bytes), cut, size)
}

///|
/// How long the UTF-8 character that starts with `lead` is, in bytes.
///
/// A byte that starts with `10` is a continuation with nothing leading it, and one that would
/// encode a character past U+10FFFF is malformed; both are counted as one byte, which is what the
/// lossy decoder will make of them anyway.
fn utf8_width(lead : Int) -> Int {
  if lead < 0x80 {
    1
  } else if (lead & 0xE0) == 0xC0 {
    2
  } else if (lead & 0xF0) == 0xE0 {
    3
  } else if (lead & 0xF8) == 0xF0 {
    4
  } else {
    1
  }
}

///|
/// The largest count at most `limit` that ends where a character ends.
///
/// Walks back to the start of the character the last byte belongs to and keeps it only if all of
/// it was read. At most three steps back, because no character is longer than four bytes.
fn utf8_cut(bytes : Bytes, limit : Int) -> Int {
  if limit <= 0 {
    return 0
  }
  let mut start = limit - 1
  let mut steps = 0
  while start > 0 && steps < 3 && (bytes[start].to_int() & 0xC0) == 0x80 {
    start -= 1
    steps += 1
  }
  if start + utf8_width(bytes[start].to_int()) <= limit {
    limit
  } else {
    start
  }
}

///|
pub async fn path_exists(path : String) -> Bool {
  @fs.exists(path)
}

///|
/// The first `max_bytes` of a file as raw bytes, or `None` when it cannot be read.
///
/// No decoding and no loss: this is for callers that need the actual bytes, which in practice
/// means an image on its way to base64. `read_prefix` decodes, which is right for describing a
/// text file and wrong for carrying a picture, where every byte matters and "mostly right" is a
/// corrupt image.
pub async fn read_bytes_prefix(path : String, max_bytes : Int) -> Bytes? {
  if !path_exists(path) {
    return None
  }
  let file = try @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    _ => return None
  } noraise {
    file => file
  }
  defer file.close()
  let size = file.size()
  let wanted = if size < max_bytes.to_int64() {
    size.to_int()
  } else {
    max_bytes
  }
  if wanted <= 0 {
    return Some(b"")
  }
  let buffer = FixedArray::make(wanted, b'\x00')
  let read = file.read_at(buffer, position=0L, len=wanted)
  let exact = FixedArray::make(read, b'\x00')
  for i in 0..<read {
    exact[i] = buffer[i]
  }
  Some(Bytes::from_array(exact))
}

///|
/// The size of a file in bytes, or `None` when it cannot be read.
pub async fn size_of(path : String) -> Int64? {
  if !path_exists(path) {
    return None
  }
  let file = try @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    _ => return None
  } noraise {
    file => file
  }
  defer file.close()
  Some(file.size())
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
/// Whether the path is a regular file.
///
/// The counterpart of `is_directory`, and here for the same reason: `open` on a directory can
/// succeed, so "it is not a directory" is not the same question as "it is a file". A path that is
/// neither — a socket, a broken symlink — is not a file either, which is what a caller wanting to
/// read something out of a directory means by asking.
pub async fn is_file(path : String) -> Bool {
  if !path_exists(path) || is_directory(path) {
    return false
  }
  try {
    let file = @fs.open(path, mode=@fs.Mode::ReadOnly)
    file.close()
    true
  } catch {
    _ => false
  } noraise {
    result => result
  }
}

///|
/// The canonical path of an existing directory, or `None` when the path does not name one.
///
/// Canonical rather than as typed: workspaces are identified by where they are, and `~/src/app`
/// and `/Users/x/src/app` have to be the same workspace or the sidebar lists the same project
/// twice. `None` rather than an error because "not a directory" is something to tell the reader,
/// not a failure to propagate.
pub async fn canonical_dir(path : String) -> String? {
  if path == "" || !is_directory(path) {
    return None
  }
  try @fs.realpath(path) catch {
    // A path that cannot be resolved is still a directory; the typed form is good enough.
    _ => Some(path)
  } noraise {
    resolved => Some(resolved)
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

///|
/// Remove a file, silently.
///
/// Silent because every caller is cleaning up after itself: a file it minted, a path it was told was
/// temporary, or the output of a job it has already read. "It was already gone" is the outcome they
/// wanted either way, and a cleanup that can fail a turn is worse than a file left behind.
///
/// Only for files. A directory needs `rmdir` and a recursive walk, and nothing here has a reason to
/// do either — a caller that does is a caller that should be telling the reader what it is deleting.
pub async fn delete_file(path : String) -> Unit {
  try @fs.remove(path) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}
