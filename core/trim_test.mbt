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
    advance_step: 1,
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
    advance_step: 1,
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
    advance_step: 1,
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
    advance_step: 1,
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
    advance_step: 1,
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
    advance_step: 1,
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
    advance_step: 1,
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
    advance_step: 1,
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

// ── The boundary's effect on the request prefix ────────────────────────────

///|
/// A conversation of `count` large tool results, each of which trimming will actually
/// change. Big enough that no policy's window protects all of them, and larger than the
/// default size threshold so the default policy trims them too.
fn conversation(count : Int) -> Array[ContextMessage] {
  let out : Array[ContextMessage] = []
  for i in 0..<count {
    out.push(tool_result_msg("c\{i}", lines(500, "result-\{i}")))
  }
  out
}

///|
/// Whether one derived conversation is a byte-for-byte prefix of the next.
///
/// This is the property the provider's cache is made of: the shared leading messages are read
/// from cache and only the tail is billed fresh. A single message that differs at a position
/// ends the shared prefix there, so everything after it is re-sent at full price.
fn is_prefix_of(
  earlier : Array[ContextMessage],
  later : Array[ContextMessage],
) -> Bool {
  if earlier.length() > later.length() {
    return false
  }
  for i in 0..<earlier.length() {
    if earlier[i] != later[i] {
      return false
    }
  }
  true
}

///|
/// Each turn's request begins with the previous turn's, so the provider reads it from cache.
///
/// This is the whole reason the boundary is quantized. A conversation that grows one message
/// per turn is the normal case; each step is compared against the previous one, and every step
/// must share the prefix except the ones where the boundary is due to jump.
test "a growing conversation keeps its request prefix between boundary jumps" {
  let policy : TrimPolicy = {
    recent_window: 4,
    advance_step: 4,
    tool_result_limit: 1024,
    head_lines: 3,
    tail_lines: 2,
    drop_old_thinking: true,
  }
  let messages = conversation(30)
  let mut jumps = 0
  for n in 6..<30 {
    let before = trim_context(messages[:n].to_owned(), policy)
    let after = trim_context(messages[:n + 1].to_owned(), policy)
    if !is_prefix_of(before, after) {
      jumps += 1
    }
  }
  // 24 steps, a jump every fourth: six of them, and the rest are pure appends.
  assert_eq(jumps, 6)
  // The old rule breaks the prefix on every single step, because the boundary moves with the
  // conversation and the message sitting at it changes: 24 of 24. That is what the
  // quantization buys.
  assert_eq(old_boundary_jumps(messages, 6, 30), 24)
}

///|
/// The count of prefix breaks the old rule produced, for contrast in the test above.
///
/// Written as its own function so the comparison is a number rather than a claim: the boundary
/// that follows the conversation moves on every single step, so almost no step shares a prefix.
fn old_boundary_jumps(
  messages : Array[ContextMessage],
  from : Int,
  to : Int,
) -> Int {
  let moving : TrimPolicy = {
    recent_window: 4,
    advance_step: 1,
    tool_result_limit: 1024,
    head_lines: 3,
    tail_lines: 2,
    drop_old_thinking: true,
  }
  let mut jumps = 0
  for n in from..<to {
    let before = trim_context(messages[:n].to_owned(), moving)
    let after = trim_context(messages[:n + 1].to_owned(), moving)
    if !is_prefix_of(before, after) {
      jumps += 1
    }
  }
  jumps
}

///|
/// The boundary lags until a whole step has piled up, then releases it at once.
test "the boundary waits for a full step before moving" {
  let policy : TrimPolicy = {
    recent_window: 2,
    advance_step: 4,
    tool_result_limit: 1024,
    head_lines: 3,
    tail_lines: 2,
    drop_old_thinking: true,
  }
  // 11 messages, window 2: nine are past the window, and the step releases eight of them.
  let trimmed = trim_context(conversation(11), policy)
  // The released eight lost their middle.
  assert_true(
    result_text(trimmed[0]).contains("omitted"),
    msg=result_text(trimmed[0]),
  )
  assert_true(
    result_text(trimmed[7]).contains("omitted"),
    msg=result_text(trimmed[7]),
  )
  // Everything from the boundary on is untouched. Three messages, not the window's two: the
  // remainder of the step is held verbatim rather than trimmed, which is the price of the
  // boundary holding still.
  for i in 8..<11 {
    assert_false(
      result_text(trimmed[i]).contains("omitted"),
      msg="message \{i} was trimmed before the boundary released it",
    )
  }
}

///|
/// A step of one is the old behaviour, kept so the difference stays measurable.
test "a step of one moves the boundary every message" {
  let policy : TrimPolicy = {
    recent_window: 2,
    advance_step: 1,
    tool_result_limit: 1024,
    head_lines: 3,
    tail_lines: 2,
    drop_old_thinking: true,
  }
  let trimmed = trim_context(conversation(10), policy)
  // Window 2 of 10 leaves 8 released, so the boundary is at 8 rather than lagging to 4.
  assert_true(
    result_text(trimmed[7]).contains("omitted"),
    msg=result_text(trimmed[7]),
  )
  assert_false(
    result_text(trimmed[8]).contains("omitted"),
    msg=result_text(trimmed[8]),
  )
}

///|
/// Trimming nothing is still an option, and the default's step leaves short conversations alone.
test "the default policy trims nothing until a step has accumulated" {
  let policy = TrimPolicy::default()
  // 20 messages with a window of 20: nothing is past it.
  assert_eq(trim_context(conversation(20), policy).length(), 20)
  // 24: four past the window, which is less than the default step of eight.
  let trimmed = trim_context(conversation(24), policy)
  assert_false(
    result_text(trimmed[0]).contains("omitted"),
    msg="the boundary moved before a full step had accumulated",
  )
  // 28: eight past, so one step is released.
  let released = trim_context(conversation(28), policy)
  assert_true(
    result_text(released[0]).contains("omitted"),
    msg="the boundary never moved",
  )
}
