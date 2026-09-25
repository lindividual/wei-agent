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

// ── Turn outcomes ───────────────────────────────────────────────────

///|
/// Why a turn ended the way it did, when the reason is not visible in the conversation.
///
/// A turn has three ways to end that look identical in the log: the model stopped, a limit
/// stopped it, or the output was cut off at the token ceiling. The first is normal and needs no
/// record. The other two change what the reader should do next — resume with a longer bound, or
/// ask the model to continue — and are otherwise unrecoverable once the process exits, because
/// the messages they left behind say nothing about why writing stopped.
///
/// A `custom` entry rather than a field on the assistant message: the message format is upstream's and
/// shared with other readers, while this is a fact about how *this* agent ran the turn. `custom`
/// entries are not replayed to the model, so recording one cannot change what the model sees, and
/// a reader that does not know the type skips it.
pub fn turn_outcome_type() -> String {
  "turn-outcome"
}

///|
/// How a turn ended, in the cases worth writing down.
pub(all) enum TurnEnding {
  /// The model decided it was done. Recorded like the others so that a turn which never wrote an
  /// outcome is unambiguously one that was interrupted — the alternative, writing nothing on
  /// success, makes "stopped" and "finished" the same absence in the log.
  Completed
  /// A guard stopped the turn rather than the model finishing.
  CostLimit
  TimeLimit
  RoundLimit
  /// The model's last answer hit the output ceiling.
  Truncated
  /// The reader stopped it.
  Stopped
  /// The reader chose to start over rather than continue an interrupted turn.
  ///
  /// Distinct from `Stopped`, which means a turn that was running was cut short. This one was
  /// never running when it ended: it is how an interrupted turn is closed when the reader decides
  /// not to resume it. Both close the turn, and the difference is what a later reader needs to know
  /// — one says "someone stopped this", the other says "this was left behind".
  Abandoned
} derive(Eq, Debug)

///|
/// The `customType` under which a session records that it was forked from another.
///
/// A `custom` entry rather than a field somewhere, for three reasons that all have to hold at once: it
/// must not be replayed to the model (it is not a message), it must be visible to a *later* reader of
/// the file (so a fact written on the header would do, but a second reader would have to know the
/// field), and it must be something the arithmetic can find (see `Session::usage`, which starts its sum
/// after the newest one). A `custom` entry is the only shape here that is silent to the model and
/// still an entry.
///
/// The entry's own `parent_id` is the fork point, and its `data` repeats that id: an entry explains
/// itself without its neighbours, which is what makes a log readable a year later.
pub fn fork_type() -> String {
  "fork"
}

///|
/// Build the entry that marks where a session's own history begins.
///
/// `parent_session` is the file it was copied from, `from_id` the entry in that history the copy ends
/// at. Both are recorded because they answer different questions — "which conversation did this come
/// from" and "how much of this is mine" — and because the second is what lets a reader of the log see
/// the point without following `parent_id` links back through it.
pub fn fork_entry(
  parent_session : String,
  from_id : String?,
  parent_id : String?,
  timestamp : Int64,
) -> Entry {
  let fields : Array[(String, Json?)] = [
    ("parent", Some(Json::string(parent_session))),
  ]
  match from_id {
    Some(id) => fields.push(("from", Some(Json::string(id))))
    None => ()
  }
  {
    id: new_entry_id(),
    parent_id,
    timestamp: format_iso_utc(timestamp),
    kind: Custom(
      custom_type=fork_type(),
      data=Some(Json::object(obj_opt_pairs(fields))),
    ),
  }
}

///|
/// The `customType` under which a turn's opening is stored.
///
/// A turn is *durably open* between this entry and its outcome. That is what makes an
/// interruption a fact recorded in the log rather than something inferred from how the messages
/// happen to end — and inferring it is unreliable, because a turn cut off by a cost limit and a
/// turn that finished both stop at a message.
pub fn turn_start_type() -> String {
  "turn-start"
}

///|
/// Build the entry that opens a turn.
///
/// The prompt is recorded here rather than left to the user message that follows, because the
/// interesting case is the one where there is no following message: a reader asking "what was it
/// doing when it stopped?" has nothing else to go on.
pub fn turn_start_entry(
  prompt : String,
  parent_id : String?,
  timestamp : Int64,
) -> Entry {
  {
    id: new_entry_id(),
    parent_id,
    timestamp: format_iso_utc(timestamp),
    kind: Custom(
      custom_type=turn_start_type(),
      data=Some(Json::object(Map([("prompt", Json::string(prompt))]))),
    ),
  }
}

///|
/// Whether the active path ends inside a turn that never recorded an outcome.
///
/// This is the durable form of "the process died mid-turn". Read from the entries, so it is the
/// same answer after a restart as before one, and it holds even when the interruption left the
/// conversation perfectly balanced — a turn killed between two tool calls wrote no unanswered
/// call, so a check for unanswered calls cannot see it.
pub fn Session::turn_in_flight(self : Session) -> Bool {
  let mut open = false
  for entry in self.path() {
    match entry.kind {
      Custom(custom_type~, ..) =>
        if custom_type == turn_start_type() {
          open = true
        } else if custom_type == turn_outcome_type() {
          open = false
        }
      _ => ()
    }
  }
  open
}

///|
/// The prompt of the turn that is currently open, if one is.
pub fn Session::in_flight_prompt(self : Session) -> String? {
  let mut prompt : String? = None
  for entry in self.path() {
    match entry.kind {
      Custom(custom_type~, data~) =>
        if custom_type == turn_start_type() {
          prompt = match data {
            Some(Json::Object(fields)) =>
              match fields.get("prompt") {
                Some(String(text)) => Some(text)
                _ => Some("")
              }
            _ => Some("")
          }
        } else if custom_type == turn_outcome_type() {
          prompt = None
        }
      _ => ()
    }
  }
  prompt
}

///|
/// The `kind` field written for one ending.
fn ending_name(ending : TurnEnding) -> String {
  match ending {
    Completed => "completed"
    CostLimit => "cost_limit"
    TimeLimit => "time_limit"
    RoundLimit => "round_limit"
    Truncated => "truncated"
    Stopped => "stopped"
    Abandoned => "abandoned"
  }
}

///|
/// Build the entry recording how a turn ended.
///
/// `turns` is the count of model calls the turn made; it is what a reader needs to judge whether
/// the limit was reached quickly (a looping model) or after a long stretch of real work (a task
/// that simply needed more room).
pub fn turn_outcome_entry(
  ending : TurnEnding,
  turns : Int,
  cost : Double,
  parent_id : String?,
  timestamp : Int64,
) -> Entry {
  {
    id: new_entry_id(),
    parent_id,
    timestamp: format_iso_utc(timestamp),
    kind: Custom(
      custom_type=turn_outcome_type(),
      data=Some(
        Json::object(
          Map([
            ("ending", Json::string(ending_name(ending))),
            ("turns", Json::number(turns.to_double())),
            ("cost", Json::number(cost)),
          ]),
        ),
      ),
    ),
  }
}

///|
/// How the most recent turn on the active path ended, if it was an ending worth recording.
///
/// Read from the entries rather than the derived context, for the same reason notes are: the
/// record is deliberately not part of the conversation.
pub fn Session::last_turn_ending(self : Session) -> TurnEnding? {
  let path = self.path()
  let mut found : TurnEnding? = None
  for entry in path {
    match entry.kind {
      Custom(custom_type~, data~) =>
        if custom_type == turn_outcome_type() {
          match data {
            Some(Json::Object(fields)) =>
              match fields.get("ending") {
                Some(String(name)) =>
                  found = Some(
                    if name == "completed" {
                      Completed
                    } else if name == "cost_limit" {
                      CostLimit
                    } else if name == "time_limit" {
                      TimeLimit
                    } else if name == "round_limit" {
                      RoundLimit
                    } else if name == "truncated" {
                      Truncated
                    } else if name == "stopped" {
                      Stopped
                    } else if name == "abandoned" {
                      Abandoned
                    } else {
                      continue
                    },
                  )
                _ => ()
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  found
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
/// Build the entry recording which model a session runs on.
///
/// An entry rather than a field on the session header, because upstream derives the model from the log
/// and a session resumed here has to read back the way upstream would read it. It is a settings entry,
/// not a message: it never reaches the model as a turn.
pub fn model_change_entry(
  provider : String,
  model_id : String,
  parent_id : String?,
  timestamp : Int64,
) -> Entry {
  {
    id: new_entry_id(),
    parent_id,
    timestamp: format_iso_utc(timestamp),
    kind: ModelChange(provider~, model_id~),
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
