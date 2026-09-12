///|
/// Truncating tool output to a size the model can use.
///
/// Two limits apply together, because output grows past either one: a command can
/// print a hundred thousand short lines, or three lines of a megabyte each.
///
/// Which end to keep depends on the tool. A file read is useful from the top —
/// imports, types, the shape of the thing. A command's output is useful from the
/// bottom, because that is where the error lands.

///|
pub fn max_output_lines() -> Int {
  2000
}

///|
pub fn max_output_bytes() -> Int {
  50 * 1024
}

///|
/// How long a single line may be before it is cut. Long lines come from minified
/// files and JSON dumps, where the interesting part is at one end.
pub fn max_line_chars() -> Int {
  500
}

///|
pub(all) struct Truncated {
  content : String
  truncated : Bool
  total_lines : Int
  /// True when the byte limit bound before the line limit did.
  truncated_by_bytes : Bool
} derive(Eq, Debug)

///|
/// Split into lines, with a trailing newline not counting as a line of its own.
/// Counting it would shift every limit by one and misreport the totals.
fn split_lines(text : String) -> Array[String] {
  let raw : Array[String] = []
  for line in text.split("\n") {
    raw.push(line.to_owned())
  }
  if raw.length() > 0 && raw[raw.length() - 1] == "" {
    raw[:raw.length() - 1].to_owned()
  } else {
    raw
  }
}

///|
/// Cut a single line to the character limit, on a character boundary.
pub fn truncate_line(line : String) -> String {
  if line.length() <= max_line_chars() {
    return line
  }
  let out = StringBuilder()
  let mut count = 0
  for c in line {
    if count >= max_line_chars() {
      break
    }
    out.write_char(c)
    count += 1
  }
  out.write_string("… (\{line.length() - max_line_chars()} more characters)")
  out.to_string()
}

///|
fn joined(lines : ArrayView[String], separator : String) -> String {
  let out = StringBuilder()
  for i in 0..<lines.length() {
    if i > 0 {
      out.write_string(separator)
    }
    out.write_string(lines[i])
  }
  out.to_string()
}

///|
/// Keep the start of the output.
pub fn truncate_head(
  content : String,
  max_lines? : Int,
  max_bytes? : Int,
) -> Truncated {
  let line_limit = match max_lines {
    Some(n) => n
    None => max_output_lines()
  }
  let byte_limit = match max_bytes {
    Some(n) => n
    None => max_output_bytes()
  }
  let lines = split_lines(content)
  let total = lines.length()
  if total <= line_limit && utf8_bytes(content) <= byte_limit {
    return {
      content,
      truncated: false,
      total_lines: total,
      truncated_by_bytes: false,
    }
  }
  // Walk forward, stopping at whichever limit binds first.
  let kept : Array[String] = []
  let mut bytes = 0
  let mut by_bytes = false
  for line in lines {
    if kept.length() >= line_limit {
      break
    }
    let line_bytes = utf8_bytes(line) + 1
    if bytes + line_bytes > byte_limit && !kept.is_empty() {
      by_bytes = true
      break
    }
    kept.push(line)
    bytes += line_bytes
  }
  if kept.is_empty() && total > 0 {
    // A single line larger than the whole budget: cut it rather than return
    // nothing, which would read as an empty file.
    return {
      content: truncate_line(lines[0]),
      truncated: true,
      total_lines: total,
      truncated_by_bytes: true,
    }
  }
  let omitted = total - kept.length()
  {
    content: joined(kept[:], "\n") +
    "\n… \{omitted} of \{total} lines omitted (\{utf8_bytes(content) / 1024} KB total) …\n",
    truncated: true,
    total_lines: total,
    truncated_by_bytes: by_bytes,
  }
}

///|
/// Keep the end of the output, where errors and the last of the work appear.
pub fn truncate_tail(
  content : String,
  max_lines? : Int,
  max_bytes? : Int,
) -> Truncated {
  let line_limit = match max_lines {
    Some(n) => n
    None => max_output_lines()
  }
  let byte_limit = match max_bytes {
    Some(n) => n
    None => max_output_bytes()
  }
  let lines = split_lines(content)
  let total = lines.length()
  if total <= line_limit && utf8_bytes(content) <= byte_limit {
    return {
      content,
      truncated: false,
      total_lines: total,
      truncated_by_bytes: false,
    }
  }
  let kept : Array[String] = []
  let mut bytes = 0
  let mut by_bytes = false
  // Walk backwards from the end.
  for back in 0..<total {
    let index = total - 1 - back
    if kept.length() >= line_limit {
      break
    }
    let line_bytes = utf8_bytes(lines[index]) + 1
    if bytes + line_bytes > byte_limit && !kept.is_empty() {
      by_bytes = true
      break
    }
    // Pushed in reverse and flipped after; prepending would be quadratic.
    kept.push(lines[index])
    bytes += line_bytes
  }
  if kept.is_empty() && total > 0 {
    return {
      content: truncate_line(lines[total - 1]),
      truncated: true,
      total_lines: total,
      truncated_by_bytes: true,
    }
  }
  let reversed : Array[String] = []
  for i in 0..<kept.length() {
    reversed.push(kept[kept.length() - 1 - i])
  }
  let omitted = total - kept.length()
  {
    content: "… \{omitted} of \{total} lines omitted (\{utf8_bytes(content) / 1024} KB total) …\n" +
    joined(reversed[:], "\n") +
    "\n",
    truncated: true,
    total_lines: total,
    truncated_by_bytes: by_bytes,
  }
}
