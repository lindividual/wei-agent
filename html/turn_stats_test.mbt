///|
/// A turn's figures, rendered under its reply.
///
/// The point of the line is the cache share, which only means something per turn: a session
/// total averages a cold start and a compaction away over a long conversation.

///|
fn usage(
  input : Int,
  output : Int,
  cache_read : Int,
  cost : Double,
) -> @core.Usage {
  {
    input,
    output,
    cache_read,
    cache_write: 0,
    reasoning: None,
    total_tokens: input + output + cache_read,
    cost: {
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: cost,
    },
  }
}

///|
test "a turn's figures name the cache share" {
  let stats : TurnStats = {
    model_calls: 3,
    tool_calls: 2,
    compactions: 0,
    usage: usage(100, 20, 900, 0.000123),
    truncated: false,
  }
  let text = turn_stats_text(stats)
  assert_true(text.contains("3 model calls"), msg=text)
  assert_true(text.contains("2 tool calls"), msg=text)
  assert_true(text.contains("90% cached"), msg=text)
  assert_true(text.contains("$0.000123"), msg=text)
}

///|
/// The truncation note, which lives on the footer now rather than on the status line.
///
/// It is the one signal that is not about a limit stopping the *turn*: the turn finished normally
/// and it is the model's last sentence that stops mid-thought. A reader who is not told sees a
/// finished-looking answer that is not one, so it has to survive somewhere — and the footer is
/// where the rest of the turn's figures are.
test "a truncated answer is called out on the footer" {
  let stats : TurnStats = {
    model_calls: 1,
    tool_calls: 0,
    compactions: 0,
    usage: usage(100, 384000, 0, 0.51),
    truncated: true,
  }
  let text = turn_stats_text(stats)
  // The ordinary figures are still there — the turn did finish.
  assert_true(text.contains("1 model call"), msg=text)
  assert_true(text.contains("cut off"), msg=text)
  let whole = turn_stats_text({ ..stats, truncated: false, })
  assert_false(whole.contains("cut off"), msg=whole)
}

///|
test "a single-call turn is not plural" {
  let stats : TurnStats = {
    model_calls: 1,
    tool_calls: 0,
    compactions: 0,
    usage: usage(100, 5, 0, 0.00001),
    truncated: false,
  }
  let text = turn_stats_text(stats)
  assert_true(text.contains("1 model call,"), msg=text)
  assert_false(text.contains("1 model calls"), msg=text)
}

///|
test "a compaction is named, and an unprompted turn shows no token figures" {
  let compacted : TurnStats = {
    model_calls: 2,
    tool_calls: 1,
    compactions: 1,
    usage: usage(10, 2, 0, 0.000001),
    truncated: false,
  }
  assert_true(
    turn_stats_text(compacted).contains("1 compacted"),
    msg=turn_stats_text(compacted),
  )
  let free : TurnStats = {
    model_calls: 1,
    tool_calls: 0,
    compactions: 0,
    usage: @core.Usage::zero(),
    truncated: false,
  }
  // No tokens billed means no token figures at all — not a row of zeroes.
  let text = turn_stats_text(free)
  assert_false(text.contains(" in /"), msg=text)
  assert_false(text.contains("$"), msg=text)
}

///|
test "the footer is rendered inside the exchange it belongs to" {
  let node = render_exchange(
    2,
    Some("do the thing"),
    [],
    stats=Some({
      model_calls: 1,
      tool_calls: 0,
      compactions: 0,
      usage: usage(100, 5, 100, 0.001),
      truncated: false,
    }),
  )
  let html = node.render()
  assert_true(html.contains("turn-stats"), msg=html)
  assert_true(html.contains("50% cached"), msg=html)
}

///|
test "a reloaded transcript recovers each turn's figures from the log" {
  let messages : Array[@core.ContextMessage] = [
    @core.User({ content: [@core.Text("one")], timestamp: 0L, }),
    assistant(usage(100, 10, 0, 0.001)),
    @core.ToolResult(tool_result("call-1")),
    @core.User({ content: [@core.Text("two")], timestamp: 0L, }),
    assistant(usage(50, 20, 950, 0.002)),
  ]
  let html = render_transcript(messages).render()
  // Two exchanges, each with its own line.
  assert_eq(
    html.split("turn-stats").length() - 1,
    2,
    msg="one footer per exchange",
  )
  assert_true(html.contains("1 model call, 1 tool calls"), msg=html)
  assert_true(html.contains("95% cached"), msg=html)
}

///|
fn assistant(usage : @core.Usage) -> @core.ContextMessage {
  @core.Assistant({
    content: [@core.Text("ok")],
    api: "openai-completions",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    usage,
    stop_reason: @core.Stop,
    timestamp: 0L,
    response_id: None,
    response_model: None,
    raw_stop_reason: None,
    error_message: None,
  })
}

///|
fn tool_result(id : String) -> @core.ToolResultMessage {
  {
    tool_call_id: id,
    tool_name: "bash",
    content: [@core.Text("done")],
    is_error: false,
    timestamp: 0L,
    details: None,
  }
}
