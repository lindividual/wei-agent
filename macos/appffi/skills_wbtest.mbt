///|
/// A `/skill:<name>` question, live and replayed

///|
/// The three parts of a skill question cross the wire as written — live and replayed alike.
///
/// This is the rule the transcript's fold hangs on. The prompt the shell writes is the skill's whole
/// document with the reader's own words after it, so both paths have to say where those words are; and
/// they have to say the *same* thing, which is why this compares the two rather than checking two
/// hand-written expectations. A live turn that draws correctly and a replayed one that draws the
/// document as the reader's sentence is the bug this catches.
test "a skill question crosses as its three parts" {
  let skill : @core.Skill = {
    name: "pdf-report",
    description: "Turn data into a PDF.",
    path: "/home/u/.wei/skills/pdf-report/SKILL.md",
  }
  let body = "# Report\n\nRead reference.md first.\n"
  let expanded = @core.skill_expansion(skill, body, "from data.csv")
  // Live: the `user` event's own fields.
  let live = field_of_fields(user_fields(expanded, false, []), "skill")
  // Replayed: the same prompt, as a session file on disk.
  let header =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
  let file = header + "\n" + user_line("m1", expanded)
  let rows = history_rows(@core.parse_session_file(file))
  let replayed = field_of_object(rows[0], "skill")
  assert_eq(live.stringify(), replayed.stringify(), msg=live.stringify())
  match live {
    Json::Object(fields) => {
      assert_eq(field_of_map(fields, "name").stringify(), "\"pdf-report\"")
      assert_eq(field_of_map(fields, "args").stringify(), "\"from data.csv\"")
      assert_eq(
        field_of_map(fields, "body").stringify(),
        Json::string(body).stringify(),
      )
    }
    _ => fail("the skill field is not an object")
  }
  // The text still crosses whole — the log and the host's `text` are what the model was asked, and
  // that is not the part being changed.
  assert_true(
    field_of_object(rows[0], "text").stringify().has_prefix("\"<skill name="),
  )
}

///|
/// A question the reader typed is told about no skill at all: the field is absent from the live event
/// (rather than false) and `null` in a row (rather than `{}`), so the host has one rule — a framing, or
/// the reader's own words.
test "an ordinary question carries no skill" {
  assert_eq(user_fields("just a question", false, []).length(), 3)
  let header =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
  let rows = history_rows(
    @core.parse_session_file(header + "\n" + user_line("m1", "just a question")),
  )
  assert_eq(field_of_object(rows[0], "skill").stringify(), "null")
}

///|
fn field_of_fields(fields : Array[(String, Json)], key : String) -> Json raise {
  for (name, value) in fields {
    if name == key {
      return value
    }
  }
  fail("\{key} is not in the event: \{fields.length()} fields")
}

///|
fn field_of_object(row : Json, key : String) -> Json raise {
  match row {
    Json::Object(fields) => field_of_map(fields, key)
    _ => fail("not an object")
  }
}

///|
fn field_of_map(fields : Map[String, Json], key : String) -> Json raise {
  match fields.get(key) {
    Some(value) => value
    None => fail("no \{key} in the object")
  }
}

///|
/// One user message, as a session file line.
///
/// Built with the encoder rather than written out, because the skill framing is full of quotes: a
/// hand-written literal would have to escape the very characters whose handling is part of what is
/// being tested.
fn user_line(id : String, text : String) -> String {
  Json::object(
    Map([
      ("type", Json::string("message")),
      ("id", Json::string(id)),
      ("parentId", Json::null()),
      ("timestamp", Json::string("2026-08-23T06:26:18.662Z")),
      (
        "message",
        Json::object(
          Map([
            ("role", Json::string("user")),
            (
              "content",
              Json::array([
                Json::object(
                  Map([
                    ("type", Json::string("text")),
                    ("text", Json::string(text)),
                  ]),
                ),
              ]),
            ),
            ("timestamp", Json::number(1.0)),
          ]),
        ),
      ),
    ]),
  ).stringify()
}

///|
/// The notice for an interrupted turn shows the question **the reader asked**, not the expansion.
///
/// A `/skill:<name>` turn's prompt in the log is the skill's document. Quoted in a three-line notice,
/// that is three lines of somebody else's instructions under the words "this turn was interrupted" —
/// and the one thing the notice is for is letting the reader check it against what they remember
/// asking. The command is what they remember.
///
/// Display only: Continue replays the prompt from the log, so this cannot change what is sent.
test "an interrupted skill turn quotes the command, not the document" {
  let skill : @core.Skill = {
    name: "pdf-report",
    description: "Turn data into a PDF.",
    path: "/home/u/.wei/skills/pdf-report/SKILL.md",
  }
  let body = "# Report\n\nRead reference.md, then run the pipeline.\n"
  assert_eq(
    prompt_as_asked(@core.skill_expansion(skill, body, "from data.csv")),
    "/skill:pdf-report from data.csv",
  )
  // Nothing after the command: the command is the whole of what was asked.
  assert_eq(
    prompt_as_asked(@core.skill_expansion(skill, body, "")),
    "/skill:pdf-report",
  )
  // An ordinary question is handed back untouched, byte for byte.
  assert_eq(prompt_as_asked("refactor the parser"), "refactor the parser")
}
