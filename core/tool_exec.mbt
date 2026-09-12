///|
/// Tool execution: the parts that are pure logic.
///
/// Argument extraction, output formatting, and the edit algorithm live here so
/// they can be tested without a filesystem. The IO that feeds them lives in
/// `platform/`.

///|
/// What a tool returns.
///
/// `content` is what the model sees; `details` is metadata for the UI — a diff, a
/// truncation notice — that would only get in the model's way.
pub(all) struct ToolOutput {
  content : Array[Content]
  is_error : Bool
  details : Json?
} derive(Eq, Debug)

///|
pub fn ToolOutput::text(text : String) -> ToolOutput {
  { content: [Text(text)], is_error: false, details: None, }
}

///|
pub fn ToolOutput::error(text : String) -> ToolOutput {
  { content: [Text(text)], is_error: true, details: None, }
}

///|
pub fn ToolOutput::with_details(
  self : ToolOutput,
  details : Json,
) -> ToolOutput {
  { ..self, details: Some(details), }
}

///|
/// The outcome of running a command, as data. Defined here rather than in the
/// platform layer so the formatting below can be tested without spawning
/// anything.
pub(all) struct ExecResult {
  stdout : String
  stderr : String
  exit_code : Int
  timed_out : Bool
} derive(Eq, Debug)

// ── Argument access ────────────────────────────────────────────────────────

///|
/// Read a string argument.
///
/// Arguments have already passed schema validation, so a missing required field
/// is unreachable here. Missing optional ones return `None`; a missing required
/// one returns an empty string, which the tool will then fail on with a message
/// the model can act on rather than an exception that ends the turn.
pub fn arg_string(arguments : Json, key : String) -> String? {
  match opt(arguments, key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
pub fn arg_required_string(arguments : Json, key : String) -> String {
  match arg_string(arguments, key) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn arg_int(arguments : Json, key : String) -> Int? {
  match opt(arguments, key) {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
pub fn arg_bool(arguments : Json, key : String) -> Bool? {
  match opt(arguments, key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
pub fn arg_array(arguments : Json, key : String) -> Array[Json] {
  match opt(arguments, key) {
    Some(Array(items)) => items
    _ => []
  }
}

// ── Output formatting ──────────────────────────────────────────────────────

///|
/// Render a command's outcome for the model.
///
/// stdout and stderr are labelled rather than merged: a command that fails and
/// prints nothing to stdout is a different situation from one that prints the
/// error and exits zero, and merging them hides which happened.
pub fn format_exec_result(result : ExecResult, cwd : String) -> ToolOutput {
  if result.timed_out {
    return ToolOutput::error(
      "Command timed out and was terminated. Partial output:\n\{result.stdout}\{result.stderr}",
    )
  }
  let out = StringBuilder()
  let stdout = truncate_tail(result.stdout)
  let stderr = truncate_tail(result.stderr)
  if stdout.content != "" {
    out.write_string(stdout.content)
  }
  if stderr.content != "" {
    if out.to_string() != "" {
      out.write_string("\n")
    }
    out.write_string("stderr:\n\{stderr.content}")
  }
  if out.to_string() == "" {
    out.write_string(
      if result.exit_code == 0 {
        "(no output)"
      } else {
        "(no output)"
      },
    )
  }
  let text = out.to_string()
  if result.exit_code != 0 {
    return ToolOutput::error("\{text}\n\nExit code \{result.exit_code}")
  }
  ignore(cwd)
  ToolOutput::text(text)
}

///|
/// Render a file read with line numbers.
///
/// `content` is the slice being returned and `offset` says which line of the file
/// it starts at, so the numbers are absolute rather than relative to the slice.
/// The model cites these numbers when editing, and counting lines itself is
/// exactly the arithmetic it gets wrong.
///
/// Whether the offset is in range is the caller's business: only the caller knows
/// how long the file actually is.
pub fn format_read_result(
  path : String,
  content : String,
  offset : Int?,
) -> ToolOutput {
  let lines = split_lines(content)
  let first = match offset {
    Some(n) if n > 1 => n
    _ => 1
  }
  let body = StringBuilder()
  let line_count = lines.length()
  // `lines[i]` is the (i+1)-th line of the slice; its number in the file is
  // `first + i`, since the slice begins at `first`.
  for i in 0..<line_count {
    body.write_string("\{first + i}: \{truncate_line(lines[i])}\n")
  }
  let rendered = truncate_head(body.to_string())
  let text = if first == 1 {
    rendered.content
  } else {
    "(\{path} from line \{first})\n\{rendered.content}"
  }
  ToolOutput::text(text)
}

// ── Editing ────────────────────────────────────────────────────────────────

///|
/// One replacement: locate `old` in the original text and put `new` there.
pub(all) struct Replacement {
  old_text : String
  new_text : String
} derive(Eq, Debug)

///|
/// A located replacement, ready to apply.
priv struct Range {
  start : Int
  end : Int
  new_text : String
}

///|
/// Why an edit could not be applied. These are reported to the model verbatim, so
/// each one says what was wrong and what to do instead.
pub(all) enum EditError {
  /// The text was not in the file at all.
  NotFound(index~ : Int, text~ : String)
  /// The text appears more than once, so the intended one is ambiguous.
  Ambiguous(index~ : Int, text~ : String, count~ : Int)
  /// Two edits claim overlapping regions.
  Overlapping(first~ : Int, second~ : Int)
} derive(Eq, Debug)

///|
pub impl Show for EditError with fn output(self, logger) {
  match self {
    NotFound(index~, text~) =>
      logger.write_string(
        "edits[\{index}]: text not found in the file: \{summarize(text)}",
      )
    Ambiguous(index~, text~, count~) =>
      logger.write_string(
        "edits[\{index}]: text appears \{count} times, so it is ambiguous; include more surrounding context to make it unique: \{summarize(text)}",
      )
    Overlapping(first~, second~) =>
      logger.write_string(
        "edits[\{second}] overlaps edits[\{first}]; merge them into one edit",
      )
  }
}

///|
fn summarize(text : String) -> String {
  let flat = text.replace(old="\n", new="\\n")
  let flat = truncate_line(flat)
  if flat.length() > 60 {
    "\{flat[:60]}…"
  } else {
    flat
  }
}

///|
/// Find every occurrence of `needle` in `haystack`, as byte offsets.
///
/// A byte search is correct here because both strings come from the same file, so
/// a match always begins and ends on a character boundary.
fn find_all(haystack : StringView, needle : StringView) -> Array[Int] {
  let found : Array[Int] = []
  if needle.length() == 0 || needle.length() > haystack.length() {
    return found
  }
  let last = haystack.length() - needle.length()
  let limit = last + 1
  for start in 0..<limit {
    if haystack[start:start + needle.length()] == needle {
      found.push(start)
    }
  }
  found
}

///|
/// Apply replacement edits to `content`.
///
/// Every edit is located in the *original* text, not in the text as previous
/// edits have changed it. That is the contract the tool description makes, and it
/// matters: it means an edit can refer to a region another edit has already
/// touched without the model having to predict the intermediate state. Overlapping
/// edits are refused rather than resolved, because there is no way to guess which
/// order was meant.
pub fn apply_edits(
  content : String,
  replacements : Array[Replacement],
) -> Result[String, EditError] {
  let ranges : Array[Range] = []
  for i in 0..<replacements.length() {
    let replacement = replacements[i]
    let matches = find_all(content[:], replacement.old_text[:])
    match matches.length() {
      0 => return Err(NotFound(index=i, text=replacement.old_text))
      1 =>
        ranges.push({
          start: matches[0],
          end: matches[0] + replacement.old_text.length(),
          new_text: replacement.new_text,
        })
      n => return Err(Ambiguous(index=i, text=replacement.old_text, count=n))
    }
  }
  // Overlap check before mutating anything, so a rejected edit set changes nothing.
  for i in 0..<ranges.length() {
    for j in (i + 1)..<ranges.length() {
      if ranges[i].start < ranges[j].end && ranges[j].start < ranges[i].end {
        return Err(Overlapping(first=i, second=j))
      }
    }
  }
  // Apply left to right with a cursor that only moves forward. Sorting ascending
  // is what makes the slice `content[cursor:start]` valid at every step; walking
  // backwards would need the cursor to move backwards with it.
  let ordered = ranges.copy()
  ordered.sort_by((a, b) => a.start.compare(b.start))
  let out = StringBuilder()
  let mut cursor = 0
  for range in ordered {
    out.write_string(content[cursor:range.start].to_owned())
    out.write_string(range.new_text)
    cursor = range.end
  }
  out.write_string(content[cursor:].to_owned())
  Ok(out.to_string())
}

///|
/// One line describing what a tool call is doing, for a reader watching it run.
///
/// Deliberately not the whole argument object: the point is to answer "what is it doing
/// right now" at a glance — the command, the file, the pattern — where JSON would bury that
/// in punctuation. Falls back to the whole object when nothing recognisable is there, so an
/// unfamiliar tool still says something rather than nothing.
pub fn tool_summary(arguments : Json) -> String {
  for key in ["command", "path", "pattern", "query", "url"] {
    match arg_string(arguments, key) {
      Some(value) if value != "" => return clip_one_line(value, 120)
      _ => ()
    }
  }
  let text = arguments.stringify()
  if text == "{}" || text == "null" {
    ""
  } else {
    clip_one_line(text, 120)
  }
}

///|
fn clip_one_line(text : String, limit : Int) -> String {
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
