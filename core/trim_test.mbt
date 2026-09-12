///|
/// Context trimming: reducing old tool output and reasoning without touching the
/// session.

///|
fn text_message(role_text : String) -> ContextMessage {
  User({ content: [Text(role_text)], timestamp: 0L, })
}

///|
fn assistant_with(blocks : Array[Content]) -> ContextMessage {
  ContextMessage::from_message(
    Assistant({
      content: blocks,
      api: "openai-completions",
      provider: "deepseek",
      model: "deepseek-v4-flash",
      usage: Usage::zero(),
      stop_reason: Stop,
      timestamp: 0L,
      response_id: (None : String?),
      response_model: (None : String?),
      raw_stop_reason: (None : String?),
      error_message: (None : String?),
    }),
  )
}

///|
fn tool_result_msg(id : String, text : String) -> ContextMessage {
  ContextMessage::from_message(
    ToolResult({
      tool_call_id: id,
      tool_name: "read",
      content: [Text(text)],
      is_error: false,
      timestamp: 0L,
      details: None,
    }),
  )
}

///|
fn lines(count : Int, prefix : String) -> String {
  let out = StringBuilder()
  for i in 0..<count {
    out.write_string("\{prefix} line \{i}\n")
  }
  out.to_string()
}

///|
fn result_text(message : ContextMessage) -> String {
  match message {
    ToolResult({ content: [Text(t)], .. }) => t
    _ => "?"
  }
}

// ── Text trimming ──────────────────────────────────────────────────────────

///|
/// Small results are left alone: the marker would cost more than the bytes.
test "a small tool result is untouched" {
  let small = tool_result_msg("c1", "short output\n")
  let (trimmed, report) = trim_context_reporting([small], TrimPolicy::default())
  assert_eq(report.tool_results_trimmed, 0)
  assert_eq(result_text(trimmed[0]), "short output\n")
}

///|
/// A large result keeps its head and tail and says what was dropped — otherwise
/// the model reads a truncated file as if it were complete.
test "a large tool result is trimmed with an explicit marker" {
  let big = tool_result_msg("c1", lines(500, "content"))
  let policy : TrimPolicy = {
    recent_window: 0,
    tool_result_limit: 1024,
    head_lines: 5,
    tail_lines: 3,
    drop_old_thinking: false,
  }
  let (trimmed, report) = trim_context_reporting([big], policy)
  let text = result_text(trimmed[0])
  assert_eq(report.tool_results_trimmed, 1)
  // Head and tail survive intact.
  assert_true(text.contains("content line 0\n"), msg="head missing")
  assert_true(text.contains("content line 4\n"), msg="head end missing")
  assert_true(text.contains("content line 499"), msg="tail missing")
  // The middle does not.
  assert_false(text.contains("content line 250\n"), msg="middle survived")
  // And the omission is stated with a reason to re-read.
  assert_true(text.contains("492 of 500 lines omitted"), msg=text)
  assert_true(text.contains("re-read"), msg=text)
}

///|
/// When the size is in line length rather than line count, dropping lines would
/// gut the content for no benefit, so the text is kept whole.
test "a single enormous line is not shredded" {
  let one_line = "x".repeat(20000)
  let policy : TrimPolicy = {
    recent_window: 0,
    tool_result_limit: 1024,
    head_lines: 5,
    tail_lines: 3,
    drop_old_thinking: false,
  }
  let (trimmed, _) = trim_context_reporting(
    [tool_result_msg("c", one_line)],
    policy,
  )
  assert_eq(result_text(trimmed[0]), one_line)
}

// ── Reasoning ──────────────────────────────────────────────────────────────

///|
/// Old reasoning is blanked but the block and its signature stay, because
/// DeepSeek validates that `reasoning_content` is present, not what it holds.
test "old reasoning is blanked and keeps its signature" {
  let message = assistant_with([
    Thinking(thinking="a long chain of thought", signature="reasoning_content"),
    Text("the answer"),
  ])
  // Default window is 20 messages, so a lone message is "recent"; put it outside.
  let policy : TrimPolicy = {
    recent_window: 0,
    tool_result_limit: 0,
    head_lines: 0,
    tail_lines: 0,
    drop_old_thinking: true,
  }
  let (trimmed, report) = trim_context_reporting([message], policy)
  assert_eq(report.thinking_blanked, 1)
  assert_true(
    trimmed[0]
    is Assistant(
      {
        content: [
          Thinking(thinking="", signature="reasoning_content"),
          Text("the answer"),
        ],
        ..
      }
    ),
  )
}

///|
/// The visible answer is never touched: it is the conversation, not scratch work.
test "assistant text survives reasoning being blanked" {
  let message = assistant_with([
    Thinking(thinking="reasoning", signature="reasoning_content"),
    Text("important answer"),
  ])
  let policy : TrimPolicy = {
    recent_window: 0,
    tool_result_limit: 0,
    head_lines: 0,
    tail_lines: 0,
    drop_old_thinking: true,
  }
  let (trimmed, _) = trim_context_reporting([message], policy)
  assert_true(
    trimmed[0] is Assistant({ content: [_, Text("important answer")], .. }),
  )
}

///|
/// The policy can be told to leave reasoning alone.
test "reasoning can be kept" {
  let message = assistant_with([
    Thinking(thinking="keep me", signature="reasoning_content"),
  ])
  let policy : TrimPolicy = {
    recent_window: 0,
    tool_result_limit: 0,
    head_lines: 0,
    tail_lines: 0,
    drop_old_thinking: false,
  }
  let (trimmed, report) = trim_context_reporting([message], policy)
  assert_eq(report.thinking_blanked, 0)
  assert_true(
    trimmed[0] is Assistant({ content: [Thinking(thinking="keep me", ..)], .. }),
  )
}

// ── The window ─────────────────────────────────────────────────────────────

///|
/// Nothing inside the recent window is touched, however large: the model is
/// working on it right now.
test "the recent window is left alone" {
  let messages : Array[ContextMessage] = [
    tool_result_msg("old", lines(500, "ancient")),
    tool_result_msg("new", lines(500, "current")),
  ]
  let policy : TrimPolicy = {
    recent_window: 1,
    tool_result_limit: 1024,
    head_lines: 2,
    tail_lines: 2,
    drop_old_thinking: false,
  }
  let (trimmed, report) = trim_context_reporting(messages, policy)
  assert_eq(report.tool_results_trimmed, 1)
  // The first was reduced; the second, inside the window, is byte-identical.
  assert_true(result_text(trimmed[0]).contains("omitted"))
  assert_eq(result_text(trimmed[1]), lines(500, "current"))
}

///|
/// A conversation shorter than the window is returned unchanged, allocation
/// aside — trimming never reaches into the part the model is actually using.
test "a short conversation is unchanged" {
  let messages : Array[ContextMessage] = [
    text_message("hi"),
    tool_result_msg("c", lines(500, "big")),
  ]
  let (trimmed, report) = trim_context_reporting(
    messages,
    TrimPolicy::default(),
  )
  assert_eq(report.tool_results_trimmed, 0)
  assert_eq(trimmed, messages)
}

///|
/// Length and order are preserved, so anything that indexes the conversation
/// keeps lining up.
test "shape is preserved" {
  let messages : Array[ContextMessage] = [
    text_message("one"),
    tool_result_msg("c1", lines(500, "a")),
    assistant_with([Thinking(thinking="t", signature="reasoning_content")]),
    text_message("two"),
    tool_result_msg("c2", lines(500, "b")),
  ]
  let policy : TrimPolicy = {
    recent_window: 1,
    tool_result_limit: 1024,
    head_lines: 2,
    tail_lines: 2,
    drop_old_thinking: true,
  }
  let (trimmed, _) = trim_context_reporting(messages, policy)
  assert_eq(trimmed.length(), messages.length())
  // Roles line up position by position.
  for i in 0..<messages.length() {
    let same_role = match (messages[i], trimmed[i]) {
      (User(_), User(_))
      | (Assistant(_), Assistant(_))
      | (ToolResult(_), ToolResult(_)) => true
      _ => false
    }
    assert_true(same_role, msg="position \{i} changed role")
  }
}

///|
/// Trimming only ever shrinks: a policy that grew the context would be a bug.
test "trimming never grows the context" {
  let messages : Array[ContextMessage] = []
  for i in 0..<40 {
    // ~13 KB each, comfortably over the 8 KB default limit.
    messages.push(tool_result_msg("c\{i}", lines(1000, "line")))
  }
  // A small window, so most of the history is old enough to trim.
  let policy : TrimPolicy = {
    recent_window: 5,
    tool_result_limit: 4 * 1024,
    head_lines: 40,
    tail_lines: 20,
    drop_old_thinking: true,
  }
  let (_, report) = trim_context_reporting(messages, policy)
  assert_true(
    report.after_tokens <= report.before_tokens,
    msg="\{report.before_tokens} -> \{report.after_tokens}",
  )
  // 35 of 40 results shrink by ~94%, so the total should more than halve.
  assert_true(
    report.after_tokens * 2 < report.before_tokens,
    msg="expected a large reduction, got \{report.before_tokens} -> \{report.after_tokens}",
  )
  assert_true(
    report.tool_results_trimmed >= 30,
    msg="\{report.tool_results_trimmed} trimmed",
  )
}

///|
/// The zero policy is the identity, which is what makes the reduction reportable
/// as a before/after pair.
test "the none policy changes nothing" {
  let messages : Array[ContextMessage] = [
    tool_result_msg("c", lines(500, "x")),
    assistant_with([Thinking(thinking="t", signature="reasoning_content")]),
  ]
  let (trimmed, report) = trim_context_reporting(messages, TrimPolicy::none())
  assert_eq(trimmed, messages)
  assert_eq(report.before_tokens, report.after_tokens)
  assert_eq(report.tool_results_trimmed, 0)
  assert_eq(report.thinking_blanked, 0)
}

// ── The combined path ──────────────────────────────────────────────────────

///|
fn session_of(messages : Array[ContextMessage]) -> Session {
  let entries : Array[Entry] = []
  for i in 0..<messages.length() {
    let message = match messages[i] {
      User(m) => Message::User(m)
      Assistant(m) => Message::Assistant(m)
      ToolResult(m) => Message::ToolResult(m)
      _ => continue
    }
    entries.push({
      id: "e\{i}",
      parent_id: if i == 0 {
        None
      } else {
        Some("e\{i - 1}")
      },
      timestamp: format_iso_utc(0L),
      kind: Message(message~),
    })
  }
  Session::new(
    {
      id: "s",
      timestamp: format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    entries,
  )
}

///|
/// The convenience path must equal deriving and trimming by hand; it exists so a
/// caller cannot get the order wrong, not to do something different.
test "prepared_context matches the two steps" {
  let session = session_of([
    tool_result_msg("c1", lines(500, "old")),
    assistant_with([Thinking(thinking="thought", signature="reasoning_content")]),
    text_message("recent"),
  ])
  let prepared = session.prepared_context()
  let manual = trim_context(session.context().messages, TrimPolicy::default())
  assert_eq(prepared.messages, manual)
  // Settings are carried through untouched.
  assert_eq(prepared.thinking_level, session.context().thinking_level)
}

///|
test "prepared_context accepts an explicit policy" {
  let session = session_of([tool_result_msg("c1", lines(500, "old"))])
  let prepared = session.prepared_context(policy=TrimPolicy::none())
  assert_eq(prepared.messages, session.context().messages)
}

///|
/// Trimming cannot disturb the log: deriving again with no policy returns the
/// original conversation in full, which is what makes the reduction reversible.
test "trimming leaves the session intact" {
  let session = session_of([
    tool_result_msg("c1", lines(500, "old")),
    assistant_with([Thinking(thinking="thought", signature="reasoning_content")]),
  ])
  let before = session.context().messages
  let _ = session.prepared_context()
  let after = session.context().messages
  assert_eq(before, after)
  // The untrimmed derivation still carries the full text.
  assert_true(result_text(after[0]).contains("old line 250"))
  assert_true(
    after[1] is Assistant({ content: [Thinking(thinking="thought", ..)], .. }),
  )
}
