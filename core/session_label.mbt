///|
/// Describing a session file without loading it.
///
/// A picker has to recognise a conversation from the outside: reading every
/// session in full to draw a list would make opening the UI cost as much as
/// replaying every one of them. The label is the first thing the user asked, which
/// is near the top of the file, so a bounded prefix is enough.

///|
/// The first thing the user asked, from the start of a session file.
///
/// Tolerates a prefix that ends mid-line — the last line is simply dropped if it
/// does not parse, which is what a byte-bounded read produces. That is a real case,
/// not a defensive one: the caller decides how much to read, and it always reads
/// bytes rather than lines.
pub fn session_label(prefix : String) -> String {
  // Only the beginning is worth scanning. A session whose first user turn is
  // deeper than this belongs to something other than a picker.
  let mut seen = 0
  for raw in prefix.split("\n") {
    if seen >= 400 {
      break
    }
    seen += 1
    let line = raw.trim()
    if line.is_empty() {
      continue
    }
    let entry = try Entry::from_json(@json.parse(line)) catch {
      _ => continue
    } noraise {
      parsed => parsed
    }
    match entry.kind {
      Message(message~) =>
        match message {
          User(user) => {
            let text = user_text(user)
            if text != "" {
              return one_line(text, 80)
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  ""
}

///|
fn user_text(message : UserMessage) -> String {
  let out = StringBuilder()
  for block in message.content {
    match block {
      Text(text) => {
        if out.to_string() != "" {
          out.write_string(" ")
        }
        out.write_string(text)
      }
      _ => ()
    }
  }
  out.to_string()
}

///|
/// Collapse whitespace and cut to `limit` characters.
///
/// Characters rather than bytes: `String::length()` means UTF-8 bytes natively and
/// UTF-16 units in JavaScript, and a label cut differently on different backends
/// would be a backend-dependent bug in a package that has to compile for all of
/// them.
fn one_line(text : String, limit : Int) -> String {
  let out = StringBuilder()
  let mut count = 0
  let mut started = false
  let mut gap = false
  let mut clipped = false
  for c in text {
    let is_space = c == ' ' || c == '\n' || c == '\t' || c == '\r'
    if is_space {
      if started {
        gap = true
      }
      continue
    }
    if count >= limit {
      clipped = true
      break
    }
    if gap {
      out.write_char(' ')
      count += 1
      gap = false
    }
    out.write_char(c)
    count += 1
    started = true
  }
  if clipped {
    out.write_string("…")
  }
  out.to_string()
}
