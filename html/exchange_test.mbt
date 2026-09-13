///|
/// A finished turn shows its answer, and folds the rest away.
///
/// The rules pinned here are the ones a reader would notice going wrong: the answer is the last
/// thing the model wrote, the working is still there behind one fold, and the line of figures is
/// both the label of that work and the way into what the figures are made of.

///|
fn thinking(what : String) -> @core.Content {
  @core.Content::Thinking(thinking=what, signature="reasoning_content")
}

///|
fn tool_call(name : String) -> @core.Content {
  @core.Content::ToolCall(id="call-1", name~, arguments=Json::object(Map([])))
}

///|
fn read_result() -> @core.ToolResultMessage {
  {
    tool_call_id: "call-1",
    tool_name: "read",
    content: [@core.Content::Text("...")],
    is_error: false,
    timestamp: 0L,
    details: None,
  }
}

///|
fn zero_cost() -> @core.Cost {
  { input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0, }
}

///|
fn stats(model_calls : Int, tool_calls : Int) -> TurnStats {
  {
    model_calls,
    tool_calls,
    compactions: 0,
    usage: @core.Usage::zero(),
    truncated: false,
  }
}

///|
/// The shape a real turn has: reason, say something, call a tool, get told, answer.
///
/// This is the fixture the three assertions below share, because the thing being pinned is what
/// happens to a *sequence* of pieces — which one is the answer and which are the work — and a
/// single piece cannot show that.
fn worked_turn() -> Array[Piece] {
  [
    Plain(block=thinking("the file is probably in the workspace root")),
    Plain(block=@core.Content::Text("Let me read that file.")),
    Tool(call=tool_call("read"), result=Some(read_result())),
    Plain(block=@core.Content::Text("The answer is forty-two.")),
  ]
}

///|
test "only the last thing the model wrote is outside the fold" {
  let html = render_exchange(
    1,
    Some("a question"),
    worked_turn(),
    stats=Some(stats(3, 1)),
  ).render()
  // Exactly one fold, and the folds it contains are inside it. The nested `<details>` are the
  // reasoning and the tool call, which is what nesting is for here: the reader opens one thing to
  // see the working, not three separate ones.
  assert_eq(count_of(html, "class=\"work\""), 1, msg=html)
  let fold_at = html.find("<details") |> Option::unwrap
  let work_at = html.find("class=\"work\"") |> Option::unwrap
  assert_true(work_at - fold_at < 40, msg=html)
  // The answer is outside it, and the narration and reasoning it replaced are inside. Position,
  // not presence: everything is present either way, which is the point of folding rather than
  // dropping.
  let after = html[fold_at:].to_owned()
  let answer_at = after.find("The answer is forty-two.") |> Option::unwrap
  let work_end = after.find("</details></details>") |> Option::unwrap
  assert_true(answer_at > work_end, msg=html)
  assert_true(after.contains("Let me read that file."), msg=html)
  assert_true(
    after.contains("the file is probably in the workspace root"),
    msg=html,
  )
}

///|
/// A turn that was one answer gets no fold at all.
///
/// The fold is over the working, and a turn with no working has nothing to fold. Left unconditional
/// it would put a closed disclosure between the reader and the only thing on the page.
test "a turn that was a single answer has no fold to open" {
  let pieces : Array[Piece] = [
    Plain(block=@core.Content::Text("Just the answer.")),
  ]
  let html = render_exchange(
    1,
    Some("a question"),
    pieces,
    stats=Some(stats(1, 0)),
  ).render()
  assert_false(html.contains("class=\"work\""), msg=html)
  assert_true(html.contains("Just the answer."), msg=html)
}

///|
/// The figures line is a control, and it says what it opens.
///
/// It has to be a button rather than a caption because the breakdown behind it was already known
/// and had nowhere to be read — and the label has to keep saying what it always said, since it is
/// the only place a turn's cost appears without a click.
test "the figures line opens the breakdown, and names it the way the page names things" {
  let html = render_exchange(
    7,
    Some("q"),
    worked_turn(),
    stats=Some(stats(3, 2)),
  ).render()
  assert_true(html.contains("data-expands=\"stats-7\""), msg=html)
  assert_true(html.contains("aria-controls=\"stats-7\""), msg=html)
  assert_true(html.contains("id=\"stats-7\""), msg=html)
  // The same sentence as before, still on the visible line.
  assert_true(html.contains("3 model calls, 2 tool calls"), msg=html)
}

///|
/// Two turns on one page each get their own panel.
///
/// The id is derived from the exchange index, and two turns sharing one would mean clicking the
/// second turn's line opened the first turn's numbers — or, worse, that the click did nothing
/// because the id it looked for was already open elsewhere.
test "each exchange's breakdown has its own id" {
  let messages : Array[@core.ContextMessage] = [
    @core.User({ content: [@core.Content::Text("one")], timestamp: 0L, }),
    assistant_saying("first answer"),
    @core.User({ content: [@core.Content::Text("two")], timestamp: 0L, }),
    assistant_saying("second answer"),
  ]
  let html = render_transcript(messages).render()
  assert_true(html.contains("data-expands=\"stats-1\""), msg=html)
  assert_true(html.contains("data-expands=\"stats-2\""), msg=html)
  assert_true(html.contains("id=\"stats-1\""), msg=html)
  assert_true(html.contains("id=\"stats-2\""), msg=html)
}

///|
/// The breakdown is the numbers that were being thrown away, not a re-derivation.
///
/// The cache split is the one that earns its place: fresh input and cached input are the same
/// tokens at very different prices, so a total says what a turn cost without saying what it was
/// spent on.
test "the breakdown splits the prompt between fresh and cached input" {
  let with_cache : TurnStats = {
    model_calls: 3,
    tool_calls: 0,
    compactions: 0,
    usage: {
      input: 447,
      output: 28,
      cache_read: 8524,
      cache_write: 0,
      reasoning: Some(64),
      total_tokens: 8999,
      cost: {
        input: 0.00003,
        output: 0.00004,
        cache_read: 0.00006,
        cache_write: 0.0,
        total: 0.00013,
      },
    },
    truncated: false,
  }
  let html = render_turn_footer("stats-1", with_cache).render()
  assert_true(html.contains("cached input"), msg=html)
  assert_true(html.contains("8524 tokens"), msg=html)
  assert_true(html.contains("95% of the prompt"), msg=html)
  // Reasoning is a real measurement when the model reports it, and an absent row when it does not.
  assert_true(html.contains("reasoning"), msg=html)
  let no_cache : TurnStats = {
    model_calls: 1,
    tool_calls: 0,
    compactions: 0,
    usage: {
      input: 100,
      output: 5,
      cache_read: 0,
      cache_write: 0,
      reasoning: None,
      total_tokens: 105,
      cost: zero_cost(),
    },
    truncated: false,
  }
  let plain = render_turn_footer("stats-1", no_cache).render()
  assert_false(plain.contains("cached input"), msg=plain)
  assert_false(plain.contains("reasoning"), msg=plain)
  assert_true(plain.contains("input"), msg=plain)
}

///|
fn assistant_saying(text : String) -> @core.ContextMessage {
  @core.Assistant({
    content: [@core.Content::Text(text)],
    api: "openai-completions",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    usage: @core.Usage::zero(),
    stop_reason: @core.Stop,
    timestamp: 0L,
    response_id: None,
    response_model: None,
    raw_stop_reason: None,
    error_message: None,
  })
}

///|
/// The breakdown's four cost parts add up to the total it prints.
///
/// That is the property that makes the split worth having: a reader can see which part of the turn
/// the money went to, and the parts reconcile with the number they saw on the line. A cost row that
/// quietly went missing would leave a total that does not match its own parts, which is worse than
/// a total with no breakdown at all.
test "the cost parts reconcile with the cost total" {
  let stats : TurnStats = {
    model_calls: 3,
    tool_calls: 2,
    compactions: 0,
    usage: {
      input: 447,
      output: 28,
      cache_read: 8524,
      cache_write: 130,
      reasoning: Some(64),
      total_tokens: 9129,
      cost: {
        input: 0.00003,
        output: 0.00004,
        cache_read: 0.00006,
        cache_write: 0.00001,
        total: 0.00014,
      },
    },
    truncated: false,
  }
  let html = render_turn_footer("stats-1", stats).render()
  for
    row in [
      "cost · input", "cost · cache", "cost · cache writes", "cost · output",
      "cost · total",
    ] {
    assert_true(html.contains(row), msg="\{row} missing from: \{html}")
  }
  // The four parts are printed with `format_cost`, and so is the total, so the sum the reader can do
  // in their head is the sum the page shows.
  assert_true(html.contains("$0.000140"), msg=html)
  // A value is a number, not a sentence: every token count sits on its own row, and the `$` only
  // ever introduces a price. `at $447 tokens` was the shape this caught.
  assert_false(html.contains("$447"), msg=html)
}
