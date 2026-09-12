///|
/// Reading and writing the session file format.
///
/// Pure text handling lives here; the platform layer owns the filesystem. Both
/// halves are needed to keep `core/` portable — the parser has to be testable
/// without a disk.

///|
/// Parse a whole session file. The first line is the header, every other line is
/// an entry, and a blank line is skipped rather than treated as an error.
pub fn parse_session_file(text : String) -> Session raise DecodeError {
  let mut header : SessionHeader? = None
  let entries : Array[Entry] = []
  let mut line_number = 0
  for raw in text.split("\n") {
    let line = raw.trim()
    line_number += 1
    if line.is_empty() {
      continue
    }
    // Folding the parse failure into DecodeError keeps one error type and lets
    // the message name the offending line.
    let parsed = try @json.parse(line) catch {
      _ => raise Malformed("line \{line_number}: invalid JSON")
    } noraise {
      j => j
    }
    if header is None {
      // The header must come first; a file that starts with an entry is
      // malformed rather than header-less.
      header = Some(SessionHeader::from_json(parsed))
      continue
    }
    entries.push(Entry::from_json(parsed))
  }
  match header {
    None => raise Malformed("session file has no header")
    Some(h) => Session::new(h, entries)
  }
}

///|
/// One JSONL line. Records are LF-terminated, and nothing else is treated as a
/// separator, so a payload containing U+2028 survives the round trip.
pub fn Entry::to_line(self : Entry) -> String {
  self.to_json().stringify() + "\n"
}

///|
pub fn SessionHeader::to_line(self : SessionHeader) -> String {
  self.to_json().stringify() + "\n"
}

///|
/// The directory name pi derives from a working directory: the leading separator
/// is dropped, path separators and colons become dashes, and the result is
/// wrapped in double dashes so it cannot collide with a real directory name.
pub fn session_dir_name(cwd : String) -> String {
  let start = if cwd.has_prefix("/") || cwd.has_prefix("\\") { 1 } else { 0 }
  let out = StringBuilder()
  for i in start..<cwd.length() {
    let c = cwd[i].unsafe_to_char()
    if c == '/' || c == '\\' || c == ':' {
      out.write_char('-')
    } else {
      out.write_char(c)
    }
  }
  "--\{out.to_string()}--"
}

///|
/// A fresh entry id: eight hex characters, matching the shape pi writes.
///
/// Ids only need to be unique within a session, and collisions across sessions
/// are harmless, so four random bytes are plenty.
pub fn new_entry_id() -> String {
  let bytes = match @env.rand(4) {
    Some(b) => b
    None => abort("no source of randomness available")
  }
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for b in bytes {
    let value = b.to_int()
    out.write_char(digits[value / 16].unsafe_to_char())
    out.write_char(digits[value % 16].unsafe_to_char())
  }
  out.to_string()
}

///|
/// Where a session file lives under a store root:
/// `<root>/<encoded-cwd>/<timestamp>_<id>.jsonl`, matching pi's layout so an
/// existing store can be read.
pub fn session_file_path(
  root : String,
  cwd : String,
  timestamp : Int64,
  id : String,
) -> String {
  let stamp = format_iso_utc(timestamp)
  // Colons are not portable in filenames; pi substitutes dashes and keeps the
  // trailing Z, which is what makes the name sort in time order.
  let safe_stamp = replace_all(stamp, ":", "-")
  "\{root}/\{session_dir_name(cwd)}/\{safe_stamp}_\{id}.jsonl"
}

///|
/// The directory holding a store root's sessions for one working directory.
pub fn session_dir_for(root : String, cwd : String) -> String {
  "\{root}/\{session_dir_name(cwd)}"
}

///|
fn replace_all(text : String, from : String, to : String) -> String {
  let out = StringBuilder()
  let parts = text.split(from)
  let mut first = true
  for part in parts {
    if !first {
      out.write_string(to)
    }
    out.write_string(part.to_owned())
    first = false
  }
  out.to_string()
}

///|
/// The directory part of a path, or `/` for a top-level path.
pub fn parent_of(path : String) -> String {
  let length = path.length()
  for back in 0..<length {
    let index = length - 1 - back
    if path[index].unsafe_to_char() == '/' {
      return if index == 0 { "/" } else { path[:index].to_owned() }
    }
  }
  "."
}
