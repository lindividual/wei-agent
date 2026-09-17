///|
let pricing_deepseek_v4_flash : Pricing = deepseek_v4_flash_pricing()

///|
fn has_key(j : Json, key : String) -> Bool {
  match j {
    Object(m) => m.get(key) is Some(_)
    _ => false
  }
}

///|
fn without_key(j : Json, key : String) -> Json {
  match j {
    Object(m) => {
      let out : Map[String, Json] = Map([])
      for k, v in m {
        if k != key {
          out.set(k, v)
        }
      }
      Json::object(out)
    }
    _ => j
  }
}

///|
/// Compare a parse result against upstream's, treating `errorMessage` as
/// presence-only.
///
/// Its text comes from the runtime: upstream surfaces the host JSON decoder's wording
/// (`Unexpected token 'o', "not-json" is not valid JSON`), which no other
/// implementation can reproduce. Whether an error is reported is behaviour;
/// the sentence describing it is not.
fn compare_stream_result(actual : Json, expected : Json) -> String? {
  let actual_has = has_key(actual, "errorMessage")
  let expected_has = has_key(expected, "errorMessage")
  if actual_has != expected_has {
    return Some(
      "errorMessage presence differs: actual=\{actual_has} expected=\{expected_has}",
    )
  }
  let a = without_key(actual, "errorMessage")
  let e = without_key(expected, "errorMessage")
  if a != e {
    return Some(
      "mismatch\n    actual:   \{a.stringify()}\n    expected: \{e.stringify()}",
    )
  }
  None
}

///|
/// Every recorded SSE body must parse to exactly the message recorded beside it.
test "deepseek SSE matches the recorded parse" {
  for entry in sse_fixtures {
    let (name, about, body, expected_text) = entry
    let expected = @json.parse(expected_text)
    let actual = parse_deepseek_stream(
      body,
      api="openai-completions",
      provider="deepseek",
      model="deepseek-v4-flash",
      timestamp=1700000000000L,
      pricing=pricing_deepseek_v4_flash,
    ).to_json()
    match compare_stream_result(actual, expected) {
      None => ()
      Some(problem) => fail("\{name} — \{about}\n  \{problem}")
    }
  }
}

// ── Behaviour the fixtures pin down, stated directly ───────────────────────

///|
fn parse(body : String) -> Message {
  parse_deepseek_stream(
    body,
    api="openai-completions",
    provider="deepseek",
    model="deepseek-v4-flash",
    timestamp=0L,
    pricing=pricing_deepseek_v4_flash,
  )
}

///|
/// Cache hits are part of `prompt_tokens`, so fresh input is what remains, and
/// the two are priced separately.
test "cache hits are split out of input and priced separately" {
  let body = "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5000,\"completion_tokens\":30,\"prompt_cache_hit_tokens\":4608,\"completion_tokens_details\":{\"reasoning_tokens\":11}}}\n\n"
  let message = parse(body)
  match message {
    Assistant(a) => {
      assert_eq(a.usage.input, 392)
      assert_eq(a.usage.cache_read, 4608)
      assert_eq(a.usage.output, 30)
      assert_eq(a.usage.reasoning, Some(11))
      assert_eq(a.usage.total_tokens, 5030)
      // 0.14/1e6*392 + 0.28/1e6*30 + 0.0028/1e6*4608
      let expected = 0.00005488 + 0.0000084 + 0.0000129024
      assert_true(
        (a.usage.cost.total - expected).abs() < 1.0e-12,
        msg="cost=\{a.usage.cost.total} expected=\{expected}",
      )
    }
    _ => fail("expected an assistant message")
  }
}

///|
/// Arguments arrive as fragments of a JSON string; only the joined text is
/// meaningful.
test "tool call arguments are joined before parsing" {
  let body = "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]},\"finish_reason\":null}]}\n\n" +
    "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a.ts\\\"}\"}}]},\"finish_reason\":null}]}\n\n" +
    "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n"
  match parse(body) {
    Assistant({ content: [ToolCall(id~, name~, arguments~)], .. }) => {
      assert_eq(id, "call_1")
      assert_eq(name, "read")
      assert_eq(arguments.stringify(), "{\"path\":\"a.ts\"}")
    }
    _ => fail("expected one tool call")
  }
}

///|
/// A stream that stops without a `finish_reason` is truncated, not finished.
test "missing finish_reason is an error" {
  let body = "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"cut off\"},\"finish_reason\":null}]}\n\n"
  match parse(body) {
    Assistant(
      { stop_reason: Error, error_message: Some(msg), content: [Text(t)], .. }
    ) => {
      assert_eq(t, "cut off")
      assert_eq(msg, "Stream ended without finish_reason")
    }
    _ => fail("expected a truncated-stream error")
  }
}

///|
/// A malformed payload aborts the stream, keeping what arrived before it.
test "non-JSON payload aborts the stream" {
  let body = "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"kept\"},\"finish_reason\":null}]}\n\n" +
    "data: not-json\n\n" +
    "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"dropped\"},\"finish_reason\":null}]}\n\n"
  match parse(body) {
    Assistant(
      { stop_reason: Error, error_message: Some(_), content: [Text(t)], .. }
    ) => assert_eq(t, "kept")
    _ => fail("expected a malformed-payload error")
  }
}

///|
/// SSE comment lines are keep-alives, not payloads.
test "comment lines are ignored" {
  let body = ": keep-alive\n\n" +
    "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n"
  match parse(body) {
    Assistant({ content: [Text(t)], stop_reason: Stop, .. }) =>
      assert_eq(t, "ok")
    _ => fail("expected a clean parse")
  }
}
