///|
/// Facts that survive compaction verbatim.
///
/// The summarization prompt asks the model to preserve file paths, commands, and
/// error messages. That is a request, not a guarantee, and a summary that
/// paraphrases `src/agent/loop.ts` into "the agent loop file" has lost something a
/// rule could have kept exactly.
///
/// Two sources feed this: facts extracted by rule from the messages being
/// summarized, and notes the agent itself chose to record. Both are precise
/// strings that never needed summarizing — so neither goes through the model.

///|
/// Upper bounds on how much is carried forward. A fact list longer than the
/// conversation it summarizes has stopped being a summary.
pub fn default_max_facts() -> Int {
  60
}

///|
/// The longest a single command or error line may be before it is elided. A
/// multi-line shell command is not a fact worth reproducing in full.
fn max_fact_length() -> Int {
  200
}

///|
pub(all) struct Facts {
  /// Files the agent read, wrote, or edited, in first-seen order.
  files : Array[String]
  /// Commands that were run, first line only.
  commands : Array[String]
  /// First lines of tool results that came back as errors.
  errors : Array[String]
} derive(Eq, Debug)

///|
pub fn Facts::empty() -> Facts {
  { files: [], commands: [], errors: [], }
}

///|
/// Whether there is anything worth appending to a summary.
pub fn Facts::is_empty(self : Facts, notes : Array[String]) -> Bool {
  self.files.is_empty() &&
  self.commands.is_empty() &&
  self.errors.is_empty() &&
  notes.is_empty()
}

///|
/// The path a tool call operated on, for the tools that take one.
fn file_argument(name : String, arguments : Json) -> String? {
  match name {
    "read" | "write" | "edit" | "glob" | "grep" =>
      json_string_field(arguments, "path")
    _ => None
  }
}

///|
fn first_line(text : String) -> String {
  for line in text.split("\n") {
    let trimmed = line.trim()
    if trimmed != "" {
      return elide(trimmed.to_owned())
    }
  }
  ""
}

///|
fn elide(text : String) -> String {
  if text.length() <= max_fact_length() {
    return text
  }
  // Cut on a character boundary; slicing bytes would split a multi-byte
  // character and produce a replacement glyph.
  let out = StringBuilder()
  let mut count = 0
  for c in text {
    if count >= max_fact_length() {
      out.write_string("…")
      break
    }
    out.write_char(c)
    count += 1
  }
  out.to_string()
}

///|
fn first_text(content : Array[Content]) -> String? {
  for block in content {
    match block {
      Text(text) => if text.trim() != "" { return Some(text) }
      _ => ()
    }
  }
  None
}

///|
/// Append unless already present, keeping first-seen order.
fn push_unique(into : Array[String], value : String) -> Unit {
  if value == "" {
    return
  }
  for existing in into {
    if existing == value {
      return
    }
  }
  if into.length() < default_max_facts() {
    into.push(value)
  }
}

///|
/// Extract facts from the messages about to be summarized.
pub fn extract_facts(messages : Array[ContextMessage]) -> Facts {
  let facts = Facts::empty()
  for message in messages {
    match message {
      Assistant(assistant) =>
        for block in assistant.content {
          match block {
            ToolCall(name~, arguments~, ..) => {
              match file_argument(name, arguments) {
                Some(path) => push_unique(facts.files, path)
                None => ()
              }
              if name == "bash" {
                match json_string_field(arguments, "command") {
                  // Only the first line: a heredoc's body is not a fact anyone
                  // needs to resume from.
                  Some(command) =>
                    push_unique(facts.commands, first_line(command))
                  None => ()
                }
              }
            }
            _ => ()
          }
        }
      ToolResult(result) =>
        if result.is_error {
          match first_text(result.content) {
            Some(text) => push_unique(facts.errors, first_line(text))
            None => ()
          }
        }
      _ => ()
    }
  }
  facts
}

///|
/// Render the facts plus any recorded notes as an appendix to a summary.
///
/// Kept as a separate section rather than folded into the summary text so it is
/// obvious which parts are verbatim. An empty appendix renders as an empty string,
/// so a caller can append unconditionally.
pub fn render_preserved(facts : Facts, notes : Array[String]) -> String {
  if facts.is_empty(notes) {
    return ""
  }
  let out = StringBuilder()
  out.write_string(
    "\n\n---\n\n## Recorded facts (extracted verbatim, not summarized)\n",
  )
  if !notes.is_empty() {
    out.write_string("\n### Notes the agent recorded\n")
    for note in notes {
      out.write_string("- \{note}\n")
    }
  }
  if !facts.files.is_empty() {
    out.write_string("\n### Files touched\n")
    for file in facts.files {
      out.write_string("- \{file}\n")
    }
  }
  if !facts.commands.is_empty() {
    out.write_string("\n### Commands run\n")
    for command in facts.commands {
      out.write_string("- `\{command}`\n")
    }
  }
  if !facts.errors.is_empty() {
    out.write_string("\n### Errors encountered\n")
    for error in facts.errors {
      out.write_string("- \{error}\n")
    }
  }
  out.to_string()
}

///|
/// The summary a compaction should record: the model's prose plus the verbatim
/// appendix.
pub fn assemble_summary(
  summary : String,
  facts : Facts,
  notes : Array[String],
) -> String {
  summary + render_preserved(facts, notes)
}

// ── Agent notes ────────────────────────────────────────────────────────────

///|
/// The `customType` under which agent notes are stored in a session.
///
/// A `custom` entry is the right home: notes record state rather than
/// conversation, so they must not be replayed to the model as turns, but they do
/// need to outlive the messages they came from.
pub fn agent_note_type() -> String {
  "agent-note"
}

///|
/// Build the entry recording a session's name.
///
/// `None` clears it, which is why the field is optional rather than a plain string: what a rename
/// replaces is the *previous* entry, and an entry that says "no name" has to be expressible.
pub fn session_name_entry(
  name : String?,
  parent_id : String?,
  timestamp : Int64,
) -> Entry {
  {
    id: new_entry_id(),
    parent_id,
    timestamp: format_iso_utc(timestamp),
    kind: SessionInfo(name~),
  }
}

///|
/// Build the entry recording a note.
pub fn agent_note_entry(
  note : String,
  parent_id : String?,
  timestamp : Int64,
) -> Entry {
  {
    id: new_entry_id(),
    parent_id,
    timestamp: format_iso_utc(timestamp),
    kind: Custom(
      custom_type=agent_note_type(),
      data=Some(Json::object(Map([("text", Json::string(note))]))),
    ),
  }
}

///|
/// Collect every agent note on the active path.
///
/// Notes are read from the entries rather than from the derived context, because
/// a note is deliberately not part of the conversation.
pub fn Session::agent_notes(self : Session) -> Array[String] {
  let out : Array[String] = []
  for entry in self.path() {
    match entry.kind {
      Custom(custom_type~, data~) =>
        if custom_type == agent_note_type() {
          match data {
            Some(Json::Object(fields)) =>
              match fields.get("text") {
                Some(String(text)) => out.push(text)
                _ => ()
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  out
}
