///|
/// Facts extracted for a summary appendix, and the notes an agent records.

///|
fn call_to(name : String, arguments : String) -> ContextMessage raise {
  ContextMessage::from_message(
    Assistant({
      content: [
        ToolCall(id="c-\{name}", name~, arguments=@json.parse(arguments)),
      ],
      api: "openai-completions",
      provider: "deepseek",
      model: "m",
      usage: Usage::zero(),
      stop_reason: ToolUse,
      timestamp: 0L,
      response_id: (None : String?),
      response_model: (None : String?),
      raw_stop_reason: (None : String?),
      error_message: (None : String?),
    }),
  )
}

///|
fn failed_result(text : String) -> ContextMessage {
  ContextMessage::from_message(
    ToolResult({
      tool_call_id: "c",
      tool_name: "bash",
      content: [Text(text)],
      is_error: true,
      timestamp: 0L,
      details: None,
    }),
  )
}

// ── Extraction ─────────────────────────────────────────────────────────────

///|
test "file paths come from the tools that take one" {
  let facts = extract_facts([
    call_to("read", "{\"path\":\"src/a.ts\"}"),
    call_to("write", "{\"path\":\"src/b.ts\",\"content\":\"x\"}"),
    call_to("edit", "{\"path\":\"src/c.ts\",\"edits\":[]}"),
  ])
  assert_eq(facts.files, ["src/a.ts", "src/b.ts", "src/c.ts"])
}

///|
/// A file touched twice is one fact; the appendix is a checklist, not a log.
test "repeated paths are deduplicated in first-seen order" {
  let facts = extract_facts([
    call_to("read", "{\"path\":\"b.ts\"}"),
    call_to("read", "{\"path\":\"a.ts\"}"),
    call_to("read", "{\"path\":\"b.ts\"}"),
  ])
  assert_eq(facts.files, ["b.ts", "a.ts"])
}

///|
/// Commands are recorded by their first line: a heredoc body is not something
/// anyone resumes from.
test "commands are recorded as their first line" {
  let facts = extract_facts([
    call_to("bash", "{\"command\":\"npm test\\n-- --watch\\nmore\"}"),
  ])
  assert_eq(facts.commands, ["npm test"])
}

///|
/// Only failing results are interesting; a list of every successful command's
/// output would be as long as the conversation.
test "only errors are collected" {
  let facts = extract_facts([
    failed_result("Error: ENOENT: no such file\n  at ..."),
    failed_result("Error: ENOENT: no such file\n  at ..."),
    ContextMessage::from_message(
      ToolResult({
        tool_call_id: "ok",
        tool_name: "read",
        content: [Text("all good")],
        is_error: false,
        timestamp: 0L,
        details: None,
      }),
    ),
  ])
  assert_eq(facts.errors, ["Error: ENOENT: no such file"])
}

///|
/// A long first line is cut on a character boundary, not a byte one, so a
/// multi-byte character is never split in half.
test "long facts are elided without breaking characters" {
  let long = "错误".repeat(300)
  let facts = extract_facts([failed_result(long)])
  assert_eq(facts.errors.length(), 1)
  let kept = facts.errors[0]
  assert_true(kept.length() <= 201, msg="length \{kept.length()}")
  assert_true(kept.has_suffix("…"), msg="expected an ellipsis")
  // Still valid UTF-8 and still made of the original characters.
  assert_true(kept.contains("错误"), msg=kept)
}

///|
/// An empty conversation yields nothing rather than an empty section.
test "no facts from messages without any" {
  let facts = extract_facts([User({ content: [Text("hello")], timestamp: 0L, })])
  assert_true(facts.is_empty([]))
}

// ── Rendering ──────────────────────────────────────────────────────────────

///|
/// Facts are labelled as extracted so a reader can tell them from the model's own
/// prose — the point of the appendix is that it is verbatim.
test "the appendix says it was not summarized" {
  let facts = extract_facts([
    call_to("bash", "{\"command\":\"npm test\"}"),
    call_to("read", "{\"path\":\"src/a.ts\"}"),
    failed_result("Error: boom"),
  ])
  let rendered = render_preserved(facts, ["the user wants X"])
  assert_true(rendered.contains("extracted verbatim"), msg=rendered)
  assert_true(rendered.contains("- `npm test`"), msg=rendered)
  assert_true(rendered.contains("- src/a.ts"), msg=rendered)
  assert_true(rendered.contains("- Error: boom"), msg=rendered)
  assert_true(rendered.contains("- the user wants X"), msg=rendered)
}

///|
/// Nothing to preserve renders as nothing, so a caller can append the result
/// without checking first.
test "an empty appendix renders empty" {
  assert_eq(render_preserved(Facts::empty(), []), "")
}

///|
/// The assembled summary is the model's prose with the appendix attached.
test "assemble appends the appendix to the summary" {
  let facts = extract_facts([call_to("read", "{\"path\":\"a.ts\"}")])
  let summary = assemble_summary("## Goal\nDo the thing.", facts, [])
  assert_true(summary.has_prefix("## Goal"), msg=summary)
  assert_true(summary.contains("- a.ts"), msg=summary)
}

// ── Notes ──────────────────────────────────────────────────────────────────

///|
/// A note is stored as a `custom` entry, so it survives in the session without
/// being replayed to the model as a turn.
test "notes are stored as custom entries" {
  let entry = agent_note_entry("the config lives in ~/.wei", None, 0L)
  assert_true(entry.kind is Custom(custom_type="agent-note", ..))
  // And they survive a file round trip like anything else.
  assert_eq(Entry::from_json(entry.to_json()), entry)
}

///|
test "notes are read back from the path" {
  let note = agent_note_entry("remember this", None, 0L)
  let session = Session::new(
    {
      id: "s",
      timestamp: format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [
      note,
      {
        id: "m1",
        parent_id: Some(note.id),
        timestamp: format_iso_utc(0L),
        kind: Message(message=User({ content: [Text("hi")], timestamp: 0L, })),
      },
    ],
  )
  assert_eq(session.agent_notes(), ["remember this"])
  // And a note does not appear as a conversation message.
  assert_eq(session.context().messages.length(), 1)
}

///|
/// A session with unrelated custom entries does not mistake them for notes.
test "only agent notes are collected" {
  let other : Entry = {
    id: "x",
    parent_id: None,
    timestamp: format_iso_utc(0L),
    kind: Custom(
      custom_type="web-search-results",
      data=Some(Json::object(Map([("text", Json::string("not a note"))]))),
    ),
  }
  let session = Session::new(
    {
      id: "s",
      timestamp: format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [other],
  )
  assert_eq(session.agent_notes().length(), 0)
}
