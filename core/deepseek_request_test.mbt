///|
/// Request-body fixtures checked against bodies captured from pi's own builder.
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
test "deepseek requests match pi" {
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
