///|
/// Skills: reusable instruction files the agent loads on demand.
///
/// A skill is a directory bundle (`<name>/SKILL.md`) or a flat `<name>.md`, beginning with a
/// YAML frontmatter block that carries a `name` and a one-line `description`. Only those two
/// fields are read here, and only the two forms they take in real files — a plain scalar, a
/// quoted one, or a block (`|`/`>`). Everything else in the frontmatter is ignored.
///
/// The split is the point and it is what keeps the cost honest: the model sees a catalog of
/// names and descriptions (a few hundred tokens for a dozen skills), and reads the full body
/// through the ordinary `read` tool only when a task matches one. Loading every body into the
/// system prompt would spend the tokens on skills the turn never uses.
///
/// The format is pi's, so a skill written for pi works here unchanged. Parsing is pure: it
/// takes the text of a file and a path to name it by, and touches nothing else, which is why
/// it is testable without a filesystem.

///|
/// A skill as the catalog needs it: what to call it, how to decide to use it, and where to
/// read it from.
pub(all) struct Skill {
  /// The skill's own name, from the frontmatter. Also what `/skill:<name>` matches.
  name : String
  /// One line telling the model when this skill applies. The whole basis for choosing it.
  description : String
  /// Absolute path of the instruction file: `SKILL.md` for a bundle, the `.md` itself for a
  /// flat skill. This is what the catalog tells the model to read.
  path : String
} derive(Eq, Debug)

///|
/// Read the frontmatter of a skill file, or `None` when it is not one.
///
/// Deliberately strict about the fence: a file that starts with `---` but never closes it is
/// not a skill, because treating the whole file as frontmatter would invent a description out
/// of the body. A file that is not a skill at all — a README, a note — is `None` too, which is
/// what lets a scanned root contain ordinary markdown.
pub fn parse_skill_header(text : String, path : String) -> Skill? {
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(strip_cr(line.to_owned()))
  }
  if lines.length() == 0 || !is_fence(lines[0]) {
    return None
  }
  let mut name = ""
  let mut description = ""
  let mut closed = false
  let mut i = 1
  while i < lines.length() {
    let raw = lines[i]
    if is_fence(raw) {
      closed = true
      break
    }
    // A top-level key starts at column zero. An indented line belongs to the key above it
    // (`metadata:` and its children), so it is skipped rather than read as a field.
    if raw.has_prefix(" ") || raw.has_prefix("\t") {
      i = i + 1
      continue
    }
    let at = raw.find(":")
    if at is None {
      i = i + 1
      continue
    }
    let colon = at.unwrap()
    let key = raw[:colon].trim().to_owned()
    let mut value = raw[colon + 1:].trim().to_owned()
    if is_block_marker(value) {
      let block = collect_block(lines, i + 1)
      value = block.0
      i = block.1
    } else {
      value = unquote(value)
      i = i + 1
    }
    // First occurrence wins: a later duplicate is more likely a mistake in the file than an
    // override someone meant.
    if key == "name" && name == "" {
      name = collapse_whitespace(value)
    }
    if key == "description" && description == "" {
      description = collapse_whitespace(value)
    }
  }
  if !closed || name == "" || description == "" {
    return None
  }
  Some({ name, description, path, })
}

///|
/// The catalog injected into the system prompt, or `""` when there are no skills.
///
/// Returning `""` rather than an empty block matters: with no skills the system prompt is
/// byte-for-byte what it was before skills existed, so a machine that has none pays nothing —
/// not even a changed prefix that would invalidate a cached prompt.
///
/// The XML shape is pi's, which is the Agent Skills convention, and the escaping is not
/// optional: a description is arbitrary text from a file, and one containing `<` must not
/// turn into markup the model reads as structure.
pub fn skill_catalog_prompt(skills : Array[Skill]) -> String {
  if skills.length() == 0 {
    return ""
  }
  let ordered = dedup_skills(skills)
  let out = StringBuilder()
  out.write_string(
    "The following skills provide specialized instructions for specific tasks.\n",
  )
  out.write_string(
    "Use the read tool to load a skill's file when the task matches its description.\n",
  )
  out.write_string(
    "When a skill file references a relative path, resolve it against the skill directory (the one holding SKILL.md) and use that absolute path in tool commands.\n\n",
  )
  out.write_string("<available_skills>\n")
  for skill in ordered {
    out.write_string("  <skill>\n")
    out.write_string("    <name>\{xml_escape(skill.name)}</name>\n")
    out.write_string(
      "    <description>\{xml_escape(skill.description)}</description>\n",
    )
    out.write_string("    <location>\{xml_escape(skill.path)}</location>\n")
    out.write_string("  </skill>\n")
  }
  out.write_string("</available_skills>\n")
  out.to_string()
}

///|
/// One entry per name, sorted so the catalog is stable across scans.
///
/// The last skill of a name wins, which is the precedence the discovery order encodes: a
/// project skill is found after the global one it shadows. Sorting by name rather than keeping
/// discovery order keeps the catalog from reshuffling when a directory does, and a catalog that
/// changes only when its contents do is what lets the prompt prefix stay cacheable.
pub fn dedup_skills(skills : Array[Skill]) -> Array[Skill] {
  let by_name : Map[String, Skill] = Map([])
  for skill in skills {
    by_name.set(skill.name, skill)
  }
  let out : Array[Skill] = []
  for pair in by_name.to_array() {
    out.push(pair.1)
  }
  out.sort_by((a, b) => compare_names(a.name, b.name))
  out
}

///|
/// Order two names lexicographically by code unit.
///
/// Written out rather than written as `a.name.compare(b.name)`, because MoonBit's `String::compare`
/// orders by length first: `"aaa".compare("b")` is positive, which would sort `aaa` after `b`.
/// The catalog order does not have to be anyone's idea of natural, but it does have to be stable
/// and based on the name, so the comparator says exactly that.
fn compare_names(a : String, b : String) -> Int {
  let shared = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < shared {
    let left = a.at(i)
    let right = b.at(i)
    if left < right {
      return -1
    }
    if left > right {
      return 1
    }
    i = i + 1
  }
  if a.length() < b.length() {
    -1
  } else if a.length() > b.length() {
    1
  } else {
    0
  }
}

// ── Frontmatter, as much of YAML as a skill header uses ────────────────────

///|
fn strip_cr(line : String) -> String {
  if line.has_suffix("\r") {
    line[:line.length() - 1].to_owned()
  } else {
    line
  }
}

///|
/// The `---` line that opens and closes the block, tolerating a leading byte-order mark.
fn is_fence(line : String) -> Bool {
  let trimmed = line.trim().to_owned()
  trimmed == "---" || trimmed == "\u{FEFF}---"
}

///|
/// Whether a value introduces a block scalar: `|` or `>`, optionally with a chomping
/// indicator. Both are collected the same way here, because a description is rendered on one
/// line either way and the difference only concerns trailing newlines nobody reads.
fn is_block_marker(value : String) -> Bool {
  value == "|" ||
  value == ">" ||
  value == "|-" ||
  value == "|+" ||
  value == ">-" ||
  value == ">+"
}

///|
/// Collect the indented lines of a block scalar, and where the scan should resume.
///
/// Indentation is what ends a block: the first line back at column zero is the next key, so
/// the scan hands its index back rather than consuming it.
fn collect_block(lines : Array[String], start : Int) -> (String, Int) {
  let out = StringBuilder()
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.trim() == "" {
      // A blank line separates paragraphs of a description; a space keeps the boundary once
      // the whole thing is collapsed to one line.
      out.write_string(" ")
      i = i + 1
      continue
    }
    if line.has_prefix(" ") || line.has_prefix("\t") {
      out.write_string(line.trim().to_owned())
      out.write_string(" ")
      i = i + 1
    } else {
      break
    }
  }
  (out.to_string(), i)
}

///|
fn unquote(value : String) -> String {
  if value.length() >= 2 {
    if value.has_prefix("\"") && value.has_suffix("\"") {
      return value[1:value.length() - 1].to_owned()
    }
    if value.has_prefix("'") && value.has_suffix("'") {
      return value[1:value.length() - 1].to_owned()
    }
  }
  value
}

///|
/// Collapse every run of whitespace to one space and trim the ends.
///
/// A description arrives on one line no matter how the file wrapped it: the catalog is read by
/// a model scanning for a match, and a line break inside a `<description>` is noise the XML
/// does not need.
fn collapse_whitespace(text : String) -> String {
  let out = StringBuilder()
  let mut count = 0
  let mut pending = false
  for c in text {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      pending = true
    } else {
      if pending && count > 0 {
        out.write_char(' ')
        count = count + 1
      }
      pending = false
      out.write_char(c)
      count = count + 1
    }
  }
  out.to_string()
}

///|
/// Escape the five characters that would end a text node or an attribute early.
fn xml_escape(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&apos;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

// ── invoking one by name ───────────────────────────────────────────────────

///|
/// A skill named explicitly, rather than one the model chose to read.
///
/// The catalog tells the model what exists and lets it decide; this is the reader deciding. Both
/// end in the same place — the skill's text reaching the model — and the difference is who
/// chooses, which matters when the model's judgement is not what you want: a skill the reader
/// knows is relevant should not depend on a one-line description persuading anyone.
///
/// The syntax and the expansion are pi's, so a habit formed there works here: `/skill:<name>`
/// with optional text after it. The name is the frontmatter `name`, not the directory, and the
/// block carries the file's location so relative references inside it keep working.

///|
/// The name and the trailing text of a `/skill:<name> …` command, or `None` when the text is not
/// one.
///
/// The colon is what makes this safe to intercept: a message that begins `/skill:` is not a path,
/// a division or a regex, so recognising it cannot swallow something the reader meant as prose.
/// That is exactly the worry that keeps every other `/x` from being treated as a command.
pub fn skill_command_parts(text : String) -> (String, String)? {
  let trimmed = text.trim()
  if !trimmed.has_prefix("/skill:") {
    return None
  }
  let rest = trimmed[7:].to_owned()
  match rest.find(" ") {
    Some(index) =>
      Some((rest[:index].to_owned(), rest[index + 1:].trim().to_owned()))
    None => Some((rest, ""))
  }
}

///|
/// Whether the text is a bare `/skill` — the reader asking what there is rather than naming one.
///
/// `/skill:` with nothing after it counts too. Both are what someone types one character before
/// they remember the name, and answering with the list is more use than either silence or an
/// error.
pub fn is_skill_list_command(text : String) -> Bool {
  let trimmed = text.trim()
  trimmed == "/skill" || trimmed == "/skill:"
}

///|
/// A skill's instruction file with its frontmatter removed, and newlines normalized.
///
/// pi's `stripFrontmatter`, reproduced deliberately rather than approximated: the frontmatter is
/// what the catalog read, and re-sending it to the model spends tokens on YAML it has already
/// been told the meaning of. The exact rules are its rules —
///
/// - CRLF and lone CR become LF, and a leading BOM is dropped, so a file written on Windows or
///   saved by an editor that adds a BOM parses the same way it did when the header was read;
/// - a document that does not open with `---` is returned whole, because there is nothing to
///   strip and inventing a boundary would delete content;
/// - the closing fence must start a line, found from index 3 so the opening fence is not mistaken
///   for it;
/// - a fence that never closes likewise means the whole text, which is the case the header parser
///   already refuses as "not a skill" — so this is only reachable for a file read directly.
pub fn strip_skill_frontmatter(text : String) -> String {
  let normalized = normalize_newlines(strip_bom(text))
  if !normalized.has_prefix("---") {
    return normalized
  }
  match normalized[3:].find("\n---") {
    Some(offset) => {
      // `offset` is relative to the slice, so the fence sits at 3 + offset and the body starts
      // four characters later: past `\n---`, and past the newline (or end) that follows it.
      let end = 3 + offset
      let body_start = end + 4
      if body_start >= normalized.length() {
        return ""
      }
      normalized[body_start:].trim().to_owned()
    }
    None => normalized
  }
}

///|
/// One skill's body, framed as the block pi sends.
///
/// `<skill name="…" location="…">` with the preamble about relative references, because a skill
/// bundle is a directory of documents and the body may well say `./reference.md`. The location is
/// what makes that resolvable, and the reader's own words follow the block so a request like
/// `/skill:pdf-report from the numbers in data.csv` reads as the skill plus an instruction rather
/// than two unrelated paragraphs.
///
/// The two attribute values are escaped. pi does not escape them, and escaping is a strict
/// improvement: a name is arbitrary text from a file, and one containing a quote would otherwise
/// end the attribute and turn the rest of the name into markup the model reads as structure. For
/// an ordinary name the output is byte-identical to pi's.
pub fn skill_expansion(skill : Skill, body : String, args : String) -> String {
  // Escaped into locals first: an interpolation placed immediately after an escaped quote is
  // easy to misread, and an unescaped attribute here is exactly the bug this function must not
  // have.
  let name = xml_escape(skill.name)
  let location = xml_escape(skill.path)
  let block = "<skill name=\"" +
    name +
    "\" location=\"" +
    location +
    "\">\n" +
    "References are relative to " +
    skill_dir(skill) +
    ".\n\n" +
    body +
    "\n" +
    "</skill>"
  if args == "" {
    block
  } else {
    block + "\n\n" + args
  }
}

///|
/// The directory a skill's relative references resolve against: the one holding its instruction
/// file. For a bundle that is `<name>/`, for a flat skill the directory it sits in — which is what
/// pi calls the skill's base directory, and the same directory `read` was told to resolve against
/// in the catalog prompt.
pub fn skill_dir(skill : Skill) -> String {
  parent_of(skill.path)
}

///|
fn strip_bom(text : String) -> String {
  if text.has_prefix("\u{FEFF}") {
    text[1:].to_owned()
  } else {
    text
  }
}

///|
fn normalize_newlines(text : String) -> String {
  if !text.contains("\r") {
    return text
  }
  // `replace_all`, not `replace`: the latter swaps only the first occurrence, which would leave
  // a CRLF file mostly CRLF and fail on exactly the case this exists for.
  text.replace_all(old="\r\n", new="\n").replace_all(old="\r", new="\n")
}
