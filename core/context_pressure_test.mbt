///|
/// Anchored request pressure.
///
/// The point of these tests is the two errors the anchor exists to remove: a fixed overhead the
/// heuristic never counted, and a systematic under-count of the conversation itself. Both are
/// checked as properties rather than as one expected number, because the number is not the point —
/// being close to what the provider reports is.

///|
fn user_text(text : String) -> ContextMessage {
  User({ content: [Text(text)], timestamp: 0L, })
}

///|
fn usage_of(input : Int, cache_read : Int, output : Int) -> Usage {
  let billed = input + cache_read
  let usage : Usage = {
    input,
    output,
    cache_read,
    cache_write: 0,
    reasoning: None,
    total_tokens: billed + output,
    cost: {
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    },
  }
  usage
}

///|
fn assistant_text(text : String, usage : Usage) -> ContextMessage {
  Assistant({
    content: [Text(text)],
    api: "openai-completions",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    usage,
    stop_reason: Stop,
    timestamp: 0L,
    response_id: (None : String?),
    response_model: (None : String?),
    raw_stop_reason: (None : String?),
    error_message: (None : String?),
  })
}

///|
/// Before any response has reported a size, the heuristic is all there is — but it at least
/// includes the part of the request that is not the conversation.
test "with no anchor the pressure is the heuristic plus the fixed overhead" {
  let messages : Array[ContextMessage] = [user_text("hello")]
  let pressure = context_pressure(messages, 1300)
  assert_true(pressure.source is Estimated)
  // The message is a token or two; the overhead is the bulk of it, and it is counted.
  assert_true(pressure.tokens > 1300, msg="\{pressure.tokens}")
  assert_eq(pressure.tokens, pressure.estimated)
}

///|
/// Once a response reports a size, that size is a fact and the conversation does not have to be
/// estimated at all — only what was appended after it does.
test "an anchor replaces the estimate for everything it already covered" {
  // A response that was told 100,000 prompt tokens.
  let messages : Array[ContextMessage] = [
    user_text("a long conversation"),
    assistant_text("an answer", usage_of(99000, 1000, 50)),
  ]
  let pressure = context_pressure(messages, 1300)
  assert_true(pressure.source is Provider)
  // The anchor plus the answer itself, and nowhere near the heuristic's answer — which would
  // have been a few tokens for a few dozen bytes.
  assert_true(pressure.tokens >= 100000, msg="\{pressure.tokens}")
  assert_true(pressure.tokens < 100100, msg="\{pressure.tokens}")
  assert_true(
    pressure.estimated < 1400,
    msg="the heuristic's own answer: \{pressure.estimated}",
  )
}

///|
/// The overhead is what makes the un-anchored estimate wrong for a short conversation, and the
/// anchor is what makes it irrelevant afterwards.
///
/// This is the concrete failure the old estimator had: a new conversation of one word reported
/// about one token, while the request carried a system prompt and seven tool schemas.
test "a one-word conversation is not reported as one token" {
  let messages : Array[ContextMessage] = [user_text("hi")]
  let estimated = context_pressure(messages, 1314)
  assert_true(estimated.tokens >= 1314, msg="\{estimated.tokens}")

  // And once the provider answers, the number is the provider's.
  let anchored : Array[ContextMessage] = [
    user_text("hi"),
    assistant_text("hello", usage_of(1300, 14, 2)),
  ]
  let after = context_pressure(anchored, 1314)
  assert_true(after.source is Provider)
  assert_eq(after.tokens, 1314 + estimate_tokens(anchored[1]))
}

///|
/// Content added after the anchor is counted, including tool results — that is the delta, and it
/// is the only thing still estimated.
test "the delta covers everything appended after the anchored response" {
  let anchor = assistant_text("an answer", usage_of(5000, 0, 10))
  let without_result : Array[ContextMessage] = [user_text("go"), anchor]
  let with_result : Array[ContextMessage] = [
    user_text("go"),
    anchor,
    ToolResult({
      tool_call_id: "c1",
      tool_name: "read",
      content: [Text("x".repeat(4000))],
      is_error: false,
      timestamp: 0L,
      details: None,
    }),
  ]
  let before = context_pressure(without_result, 0)
  let after = context_pressure(with_result, 0)
  // The tool result is 4000 characters, so about a thousand tokens more.
  assert_eq(after.tokens - before.tokens, estimate_tokens(with_result[2]))
  assert_true(
    after.tokens - before.tokens > 900,
    msg="\{after.tokens - before.tokens}",
  )
}

///|
/// The most recent measurement wins: an older report describes a smaller conversation.
test "the anchor is the last reported size, not the first" {
  let messages : Array[ContextMessage] = [
    user_text("first"),
    assistant_text("one", usage_of(1000, 0, 5)),
    user_text("second"),
    assistant_text("two", usage_of(50000, 0, 5)),
  ]
  let pressure = context_pressure(messages, 0)
  assert_true(pressure.tokens >= 50000, msg="\{pressure.tokens}")
}

///|
/// A response that reported nothing — a failed call — cannot anchor, so the search falls back to
/// the last one that did.
test "a zero-billed response is not used as an anchor" {
  let messages : Array[ContextMessage] = [
    user_text("first"),
    assistant_text("one", usage_of(2000, 0, 5)),
    user_text("second"),
    assistant_text("", usage_of(0, 0, 0)),
  ]
  let pressure = context_pressure(messages, 0)
  assert_true(pressure.source is Provider)
  // Anchored on the 2000-token report, plus everything after it.
  assert_true(pressure.tokens >= 2000, msg="\{pressure.tokens}")
  let anchored_at_two_thousand = 2000 +
    estimate_tokens(messages[1]) +
    estimate_tokens(messages[2]) +
    estimate_tokens(messages[3])
  assert_eq(pressure.tokens, anchored_at_two_thousand)
}
