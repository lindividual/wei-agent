///|
/// Request-body fixtures checked against bodies captured from upstream's own builder.
///
/// This is a blackbox test, so the JSON accessors below are local: the shared
/// ones in `message_json.mbt` are package private, and a test that reaches for
/// them would stop proving that the public API is usable from outside.

///|
fn opt_field(j : Json, key : String) -> Json? {
  match j {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
fn require_field(j : Json, key : String) -> Json raise {
  match opt_field(j, key) {
    Some(v) => v
    None => fail("missing field: \{key}")
  }
}

///|
fn as_text(j : Json) -> String raise {
  match j {
    String(s) => s
    _ => fail("expected a string")
  }
}

///|
fn tool_of(j : Json) -> ToolDef raise {
  {
    name: as_text(require_field(j, "name")),
    description: as_text(require_field(j, "description")),
    parameters: require_field(j, "parameters"),
    // Not part of the wire format: scheduling and prompting are decided here.
    concurrency: Safe,
    timeout_ms: None,
    snippet: "",
  }
}

///|
/// Rebuild a `RequestSpec` from the recorded input, using only public API.
fn spec_of(input : Json) -> RequestSpec raise {
  let messages = match opt_field(input, "messages") {
    Some(Array(items)) => items.map(m => Message::from_json(m))
    _ => fail("input has no messages")
  }
  let system_prompt = match opt_field(input, "systemPrompt") {
    Some(String(s)) => Some(s)
    _ => None
  }
  let tools = match opt_field(input, "tools") {
    Some(Array(items)) => items.map(t => tool_of(t))
    _ => []
  }
  // A null or absent level means thinking is off, which is distinct from a
  // named level the model cannot honour.
  let level : String? = match opt_field(input, "thinking") {
    Some(String(s)) => Some(s)
    _ => None
  }
  let max_tokens = match opt_field(input, "maxTokens") {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
  let temperature = match opt_field(input, "temperature") {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
  {
    model: "deepseek-v4-flash",
    messages,
    system_prompt,
    tools,
    thinking: deepseek_v4_thinking_levels().resolve(level),
    max_tokens,
    temperature,
    vision: false,
  }
}

///|
/// Every captured request body must be reproduced exactly.
test "deepseek requests match the recorded bodies" {
  for entry in request_fixtures {
    let (name, about, input_text, expected_text) = entry
    let input = @json.parse(input_text)
    let expected = @json.parse(expected_text)
    let actual = build_deepseek_request(spec_of(input))
    if actual != expected {
      fail(
        "\{name} — \{about}\n    actual:   \{actual.stringify()}\n    expected: \{expected.stringify()}",
      )
    }
  }
}

// ── Rules the fixtures pin down, stated directly ───────────────────────────

///|
fn messages_of(built : Json) -> Array[Json] {
  match opt_field(built, "messages") {
    Some(Array(items)) => items
    _ => []
  }
}

///|
/// A message with nothing in it is dropped rather than sent as `null` content,
/// which DeepSeek rejects.
test "empty assistant and user messages are dropped" {
  let spec : RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [
      User({ content: [], timestamp: 0L, }),
      Assistant({
        content: [],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: Usage::zero(),
        stop_reason: Stop,
        timestamp: 0L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ],
    system_prompt: None,
    tools: [],
    thinking: Disabled,
    max_tokens: None,
    temperature: None,
    vision: false,
  }
  assert_eq(messages_of(build_deepseek_request(spec)).length(), 0)
}

///|
/// Reasoning always travels back under `reasoning_content`, which is the field
/// DeepSeek validates; an assistant turn without thinking still carries the key
/// so a replay is not rejected.
test "reasoning is replayed as reasoning_content" {
  let spec : RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [
      Assistant({
        content: [
          Thinking(thinking="why", signature="reasoning_content"),
          Text("answer"),
        ],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: Usage::zero(),
        stop_reason: Stop,
        timestamp: 0L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ],
    system_prompt: None,
    tools: [],
    thinking: Disabled,
    max_tokens: None,
    temperature: None,
    vision: false,
  }
  let built = messages_of(build_deepseek_request(spec))
  assert_eq(built.length(), 1)
  assert_eq(as_text(require_field(built[0], "reasoning_content")), "why")
  assert_eq(as_text(require_field(built[0], "content")), "answer")
}

///|
/// Tool arguments go on the wire as a JSON string; sending a nested object is
/// rejected by the API.
test "tool arguments are serialized as a string" {
  let spec : RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [
      Assistant({
        content: [
          ToolCall(
            id="c1",
            name="read",
            arguments=@json.parse("{\"path\":\"a\"}"),
          ),
        ],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: Usage::zero(),
        stop_reason: ToolUse,
        timestamp: 0L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ],
    system_prompt: None,
    tools: [],
    thinking: Disabled,
    max_tokens: None,
    temperature: None,
    vision: false,
  }
  let built = messages_of(build_deepseek_request(spec))
  let calls = match opt_field(built[0], "tool_calls") {
    Some(Array(items)) => items
    _ => fail("expected tool_calls")
  }
  assert_eq(calls.length(), 1)
  let func = require_field(calls[0], "function")
  assert_eq(as_text(require_field(func, "arguments")), "{\"path\":\"a\"}")
}

// ── Request drift ──────────────────────────────────────────────────────────

///|
/// The meter must measure the bytes that are actually sent, not a parallel reconstruction of
/// them: a measurement that can disagree with the wire is worse than none, because it would be
/// believed. Both go through `convert_messages`, and this is what says so.
test "the measured messages are the request's messages" {
  let spec : RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [
      User({ content: [Text("hello")], timestamp: 0L, }),
      Assistant({
        content: [Text("hi")],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: Usage::zero(),
        stop_reason: Stop,
        timestamp: 0L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ],
    system_prompt: Some("be brief"),
    tools: [],
    thinking: Disabled,
    max_tokens: None,
    temperature: None,
    vision: false,
  }
  let body_messages = messages_of(build_deepseek_request(spec))
  let encoded = convert_messages(
    spec.messages,
    spec.system_prompt,
    vision=spec.vision,
  )
  assert_eq(encoded, body_messages)
  let drift = request_drift(None, encoded)
  assert_eq(drift.messages, encoded.length())
}

///|
/// A request that only grew is billed by its tail.
///
/// This is the shape every call inside a turn should have, and the reason the boundary that
/// releases messages to trimming is quantized rather than free to move message by message.
test "appending a message leaves the earlier ones shared" {
  let first = convert_messages(
    [User({ content: [Text("one")], timestamp: 0L, })],
    Some("sys"),
    vision=false,
  )
  let second = convert_messages(
    [
      User({ content: [Text("one")], timestamp: 0L, }),
      Assistant({
        content: [Text("reply")],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: Usage::zero(),
        stop_reason: Stop,
        timestamp: 0L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ],
    Some("sys"),
    vision=false,
  )
  let drift = request_drift(Some(first), second)
  assert_true(drift.appended_only())
  // Two messages in the first request — the system prompt and the user's — and the appended reply
  // is the third. Nothing before it changed, which is what makes it the shared prefix.
  assert_eq(drift.previous_messages, 2)
  assert_eq(drift.first_changed, 2)
  assert_eq(drift.messages, 3)
  // Everything the previous request sent is shared, so only the appended message is fresh, and
  // only that message's bytes count as changed.
  assert_true(drift.changed_bytes < drift.bytes)
}

///|
/// Rewriting what was already sent ends the shared prefix there, and everything from that point
/// is charged again.
///
/// One changed message is enough. The system prompt is the first message of the request, so
/// changing it leaves nothing shared at all — the worst case, and the one worth pinning, because
/// the figure is reported from the first change to the end rather than summed over the
/// differences.
test "rewriting the first message rebills the whole request" {
  let user : Message = User({ content: [Text("one")], timestamp: 0L, })
  let first = convert_messages([user], Some("sys"), vision=false)
  let second = convert_messages(
    [user],
    Some("a different system prompt"),
    vision=false,
  )
  let drift = request_drift(Some(first), second)
  assert_false(drift.appended_only())
  assert_true(drift.comparable)
  assert_eq(drift.first_changed, 0)
  assert_eq(drift.changed_bytes, drift.bytes)
}

///|
/// A rewrite further in keeps the bytes before it shared, so the bill is what follows it.
///
/// The distinction the figure exists to draw: a message that changed near the end costs the tail,
/// and the same change near the front costs almost everything.
test "rewriting a later message keeps the earlier ones shared" {
  let first = convert_messages(
    [
      User({ content: [Text("one")], timestamp: 0L, }),
      User({ content: [Text("two")], timestamp: 0L, }),
    ],
    Some("sys"),
    vision=false,
  )
  let second = convert_messages(
    [
      User({ content: [Text("one")], timestamp: 0L, }),
      User({ content: [Text("two, but different")], timestamp: 0L, }),
    ],
    Some("sys"),
    vision=false,
  )
  let drift = request_drift(Some(first), second)
  assert_false(drift.appended_only())
  assert_eq(drift.first_changed, 2)
  assert_true(drift.changed_bytes < drift.bytes)
}

///|
/// The first request of a turn has nothing to compare against, and says so.
///
/// Not the same as having changed nothing: a caller summing `changed_bytes` over a turn would
/// otherwise report a first request as free.
test "the first request reports itself as incomparable" {
  let encoded = convert_messages(
    [User({ content: [Text("hi")], timestamp: 0L, })],
    None,
    vision=false,
  )
  let drift = request_drift(None, encoded)
  assert_false(drift.comparable)
  assert_false(drift.appended_only())
  assert_eq(drift.previous_messages, 0)
  assert_eq(drift.changed_bytes, drift.bytes)
}

///|
/// A request that shrank has nothing left to bill.
///
/// Compaction is the case: it replaces the older half of the conversation with a summary, which
/// can leave a request shorter than the one before it. Reporting the overlap as unchanged would
/// be wrong in the other direction — those bytes are billed by whatever remains of them.
test "a shorter request reports nothing changed" {
  let first = convert_messages(
    [
      User({ content: [Text("one")], timestamp: 0L, }),
      User({ content: [Text("two")], timestamp: 0L, }),
    ],
    None,
    vision=false,
  )
  let second = convert_messages(
    [User({ content: [Text("one")], timestamp: 0L, })],
    None,
    vision=false,
  )
  let drift = request_drift(Some(first), second)
  assert_eq(drift.messages, 1)
  assert_eq(drift.first_changed, 1)
  assert_eq(drift.changed_bytes, 0)
}
