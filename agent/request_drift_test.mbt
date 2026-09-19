///|
/// What each request of a turn had in common with the one before it.
///
/// The figures a turn reports — model calls, tokens, cost — say what was billed. They cannot say
/// why: two turns can spend the same amount with one barely touching the cache and the other
/// reading almost all of it. This is the missing half, and the reason it is worth a test of its
/// own is that it is the only place the *sequence* of requests is visible: an individual request
/// is either a continuation of the last one or a rewrite of it, and which one it is decides what
/// the provider can serve from cache.

///|
/// Every request in a turn is the previous request plus a tail, except the first.
///
/// This is the property a turn is supposed to have, and the one a rewrite anywhere in the middle
/// would break. Asserted on the turn's own report rather than on the code that produces it.
async test "a turn's requests are append-only according to its own report" {
  let dir = scratch("drift-append")
  let seen : Array[String] = []
  let responses = [
    bash_tool_call_sse("echo one"),
    bash_tool_call_sse("echo two"),
    text_sse("done"),
  ]
  with_fake_model(responses, seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "run two commands",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_eq(result.model_calls, 3)
    assert_eq(result.request_drift.length(), 3)
    // The first request has nothing to compare against, and says so rather than reporting a
    // change of zero.
    assert_false(result.request_drift[0].comparable)
    for i in 1..<3 {
      let drift = result.request_drift[i]
      assert_true(
        drift.appended_only(),
        msg="request \{i} rewrote the past: first change at message \{drift.first_changed} of \{drift.previous_messages}",
      )
      // Appended-only means the fresh part is the tail, so it has to be smaller than the request
      // — unless the request is nothing but the tail, which this conversation is not.
      assert_true(
        drift.changed_bytes < drift.bytes,
        msg="changed \{drift.changed_bytes} of \{drift.bytes}",
      )
    }
    // The request grows by the model's own reply and the tool's answer each round, so the last
    // request carries more messages than the first.
    assert_true(
      result.request_drift[2].messages > result.request_drift[0].messages,
    )
    assert_true(result.request_drift[2].bytes > result.request_drift[0].bytes)
  })
}

///|
/// The drift is measured against the previous request, not against the conversation.
///
/// A second turn continues the same conversation, so its first request must extend the last
/// request of the first turn — which is a different claim from "the turn's requests agree with
/// each other", and the one a rebuild between turns would break.
async test "the first request of a turn follows the previous turn's last" {
  let dir = scratch("drift-turns")
  let seen : Array[String] = []
  let responses = [
    bash_tool_call_sse("echo one"),
    text_sse("first done"),
    text_sse("second done"),
  ]
  with_fake_model(responses, seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let first = @agent.run_turn(ctx, "first", FIXED_TIME, thinking_level="high")
    let second = @agent.run_turn(
      { ..ctx, session: first.session, },
      "second",
      FIXED_TIME,
      thinking_level="high",
      // What a caller that runs turn after turn does: hand back the last request so this turn's
      // first one has something to be compared against.
      previous_request=Some(first.last_request),
    )
    assert_eq(second.model_calls, 1)
    // The first request of a turn is measured against the previous turn's last request, which the
    // caller hands back for exactly this. A flow that drops `last_request` gets `comparable: false`
    // here instead -- and that is the request where a trim boundary most often moves, so losing it
    // would hide the expensive rewrite this report exists to show.
    assert_true(second.request_drift[0].comparable)
    assert_false(second.request_drift[0].within_turn)
    // The two turns together still only ever appended: the last request of the first turn has to
    // be a prefix of the request the second turn made, which `seen` can answer because the
    // scripted model records what it was sent.
    assert_eq(seen.length(), 3)
    let before = messages_of_body(seen[1])
    let after = messages_of_body(seen[2])
    assert_true(
      is_message_prefix(before, after),
      msg="the second turn rewrote the first turn's conversation",
    )
  })
}

///|
/// The messages of a recorded request body.
fn messages_of_body(body : String) -> Array[Json] {
  let parsed = try @json.parse(body) catch {
    _ => abort("not JSON")
  } noraise {
    j => j
  }
  match parsed {
    Object(fields) =>
      match fields.get("messages") {
        Some(Array(items)) => items
        _ => []
      }
    _ => []
  }
}

///|
/// Whether one request's messages begin the other's, message for message.
fn is_message_prefix(earlier : Array[Json], later : Array[Json]) -> Bool {
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
