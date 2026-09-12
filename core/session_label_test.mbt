///|
/// Context messages that are not conversation, and how they reach the model.
///
/// The interesting assertions here are not about our code but about pi's: the
/// `<summary>` framing and the custom-message handling are compared against
/// `convertToLlm` output captured in `llm_message_fixtures.mbt`. A hand-written
/// expectation could not tell us that the wrapper changed under us.
///
/// The one thing that is *not* verifiable this way is the layer at which the
/// conversion happens. pi-ai drops a `compactionSummary` message silently, so a
/// design that handed summaries to the request builder would lose them entirely
/// and no fixture comparison would catch it — hence the direct test that the
/// conversion produces a user turn.

///|
test "context messages reach the model the way pi sends them" {
  for fixture in llm_message_fixtures {
    let (name, input, expected) = fixture
    let j = @json.parse(input)
    let message = match name {
      "compaction_summary" =>
        ContextMessage::to_message(
          CompactionSummary(
            summary=field_string(j, "summary"),
            tokens_before=field_int(j, "tokensBefore"),
            timestamp=field_int64(j, "timestamp"),
          ),
        )
      "branch_summary" =>
        ContextMessage::to_message(
          BranchSummary(
            summary=field_string(j, "summary"),
            from_id=field_string(j, "fromId"),
            timestamp=field_int64(j, "timestamp"),
          ),
        )
      "custom_parts" | "custom_string" =>
        ContextMessage::to_message(
          Custom(
            custom_type=field_string(j, "customType"),
            content=field(j, "content"),
            display=false,
            details=None,
            timestamp=field_int64(j, "timestamp"),
          ),
        )
      _ => fail("unknown fixture: \{name}")
    }
    assert_eq(message.to_json(), @json.parse(expected), msg=name)
  }
}

///|
/// A summary is a user turn, not a record the request builder has to know about.
///
/// This is the guard against the mistake the fixtures cannot see: pi-ai has no
/// case for `compactionSummary`, so anything that reaches it in that shape is
/// dropped from the request without an error.
test "a summary is converted before the request is built" {
  let context : SessionContext = {
    messages: [
      CompactionSummary(summary="old work", tokens_before=1000, timestamp=1L),
      User({ content: [Text("carry on")], timestamp: 2L, }),
    ],
    thinking_level: "high",
    model: None,
  }
  let messages = context.messages_for_model()
  assert_eq(messages.length(), 2)
  // Nothing that reaches the request builder may be a summary record.
  for message in messages {
    assert_true(
      message is User(_) || message is Assistant(_) || message is ToolResult(_),
    )
  }
}

///|
test "messages_before returns what a compaction would replace" {
  let a = entry_for("a", None, "first")
  let b = entry_for("b", Some("a"), "second")
  let c = entry_for("c", Some("b"), "third")
  let session = Session::new(header(), [a, b, c])

  let before = session.messages_before("c")
  assert_eq(before.length(), 2)
  assert_eq(context_text(before[0]), "first")
  assert_eq(context_text(before[1]), "second")
  // Cutting at the first entry leaves nothing to summarize, and an unknown id is
  // treated the same way: better to skip the compaction than to record a summary
  // of nothing.
  assert_true(session.messages_before("a").is_empty())
  assert_true(session.messages_before("missing").is_empty())
}

///|
/// A second compaction summarizes the first summary plus what followed, not the
/// history the first one already replaced.
test "messages_before honours the newest compaction" {
  let a = entry_for("a", None, "ancient")
  let b = entry_for("b", Some("a"), "recent")
  let compaction : Entry = {
    id: "cmp",
    parent_id: Some("b"),
    timestamp: fixed_timestamp(),
    kind: Compaction(
      summary="earlier summary",
      first_kept_entry_id="b",
      tokens_before=100,
      details=None,
      usage=None,
      from_hook=None,
    ),
  }
  let session = Session::new(header(), [a, b, compaction])
  let messages = session.context().messages
  // The summary stands in for everything before `b`.
  assert_eq(messages.length(), 2)
  assert_true(messages[0] is CompactionSummary(_))
  assert_eq(context_text(messages[1]), "recent")
}

///|
/// Appending in memory keeps the log and the session in step.
test "add_entries extends the session and moves the leaf" {
  let a = entry_for("a", None, "first")
  let session = Session::new(header(), [a])
  assert_eq(session.leaf_id, Some("a"))
  let b = entry_for("b", Some("a"), "second")
  let grown = session.add_entries([b])
  assert_eq(grown.entries.length(), 2)
  assert_eq(grown.leaf_id, Some("b"))
  assert_eq(grown.path().length(), 2)
  // The original is untouched: nothing here mutates.
  assert_eq(session.entries.length(), 1)
  // An empty append is a no-op rather than a reason to rebuild the index.
  assert_eq(session.add_entries([]).entries.length(), 1)
}

///|
test "session_label reads the first user turn out of a prefix" {
  let lines = [
    header().to_line(),
    entry_for("a", None, "  set\n up   the project ").to_line(),
    entry_for("b", Some("a"), "second").to_line(),
  ]
  assert_eq(session_label(lines.join("\n")), "set up the project")
}

///|
test "session_label tolerates a prefix cut mid-line" {
  let lines = [
    header().to_line(),
    entry_for("a", None, "hello").to_line(),
    // A truncated tail, as a byte-bounded read produces.
    "{\"type\":\"message\",\"id\":\"b\",\"message\":{\"role\":\"user\",\"cont",
  ]
  assert_eq(session_label(lines.join("\n")), "hello")
}

///|
test "session_label clips a long first turn" {
  let long = "x".repeat(200)
  let lines = [header().to_line(), entry_for("a", None, long).to_line()]
  let label = session_label(lines.join("\n"))
  // 80 characters plus the ellipsis.
  assert_eq(label.length(), 81)
  assert_true(label.has_suffix("…"), msg=label)
}

///|
test "session_label is empty when there is nothing to show" {
  assert_eq(session_label(""), "")
  assert_eq(session_label(header().to_line()), "")
}

// ── helpers ────────────────────────────────────────────────────────────────

///|
fn fixed_timestamp() -> String {
  format_iso_utc(1700000000000L)
}

///|
fn header() -> SessionHeader {
  {
    id: "s",
    timestamp: fixed_timestamp(),
    cwd: "/tmp",
    parent_session: None,
    version: Some(3),
  }
}

///|
fn entry_for(id : String, parent : String?, text : String) -> Entry {
  {
    id,
    parent_id: parent,
    timestamp: fixed_timestamp(),
    kind: Message(
      message=User({ content: [Text(text)], timestamp: 1700000000000L, }),
    ),
  }
}

///|
fn field(j : Json, key : String) -> Json raise {
  match j {
    Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => fail("missing field: \{key}")
      }
    _ => fail("not an object")
  }
}

///|
fn field_string(j : Json, key : String) -> String raise {
  match field(j, key) {
    String(value) => value
    _ => fail("\{key} is not a string")
  }
}

///|
fn field_int(j : Json, key : String) -> Int raise {
  match field(j, key) {
    Number(value, ..) => value.to_int()
    _ => fail("\{key} is not a number")
  }
}

///|
fn field_int64(j : Json, key : String) -> Int64 raise {
  match field(j, key) {
    Number(value, ..) => value.to_int64()
    _ => fail("\{key} is not a number")
  }
}

///|
fn context_text(message : ContextMessage) -> String {
  match message {
    User(user) =>
      match user.content[0] {
        Text(text) => text
        _ => ""
      }
    _ => ""
  }
}
