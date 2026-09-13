///|
/// The live view — what a browser that connects mid-turn is given.
///
/// The live view exists so a turn that is joined late looks the same as a turn that was watched from
/// the start, and the tests here are about the one thing that used to break that: a tool that has
/// started but not yet reported has no `Tool` value, because that variant's result is not optional.
/// It is its own variant now, and these are the properties that make the snapshot usable.

///|
fn live_runner() -> Runner {
  let runner = runner_at("/tmp/live-view", 0)
  runner.live = []
  runner
}

///|
fn started(id : String) -> @html.LivePiece {
  @html.RunningTool(
    id~,
    name="bash",
    arguments=Json::object(Map([("command", Json::string("/bin/sleep 30"))])),
    since=1700000000000L,
  )
}

///|
fn reported(id : String) -> @html.LivePiece {
  @html.Tool(
    id~,
    call=@core.ToolCall(
      id="call-1",
      name="bash",
      arguments=Json::object(Map([])),
    ),
    result={
      tool_call_id: "call-1",
      tool_name: "bash",
      content: [@core.Text("done")],
      is_error: false,
      timestamp: 0L,
      details: None,
    },
  )
}

///|
/// The upgrade happens in place, which is what keeps the snapshot's ids the ones the stream is
/// still writing to.
///
/// If the finished piece were appended instead, the live view would hold two entries for one tool:
/// the snapshot would render both, and the second one would be a block the stream never touches.
test "a tool that reports replaces its own running entry rather than adding one" {
  let runner = live_runner()
  runner.trace(started("live-tool-1-1"))
  assert_eq(runner.live.length(), 1, msg="the live view holds the wrong pieces")
  assert_true(
    runner.live[0] is @html.RunningTool(..),
    msg="the live view holds the wrong pieces",
  )
  runner.trace(reported("live-tool-1-1"))
  assert_eq(runner.live.length(), 1, msg="one tool, one entry")
  assert_true(
    runner.live[0] is @html.Tool(..),
    msg="the running entry should have been replaced, not added to",
  )
}

///|
/// Two tools in one turn are two entries, and the order is the order they ran.
///
/// Matching is by id, so this is also what would fail if the ids collided — which they cannot,
/// because the sequence number is per turn.
test "each tool in a turn keeps its own entry" {
  let runner = live_runner()
  runner.trace(started(tool_block_id(1, 1)))
  runner.trace(reported(tool_block_id(1, 1)))
  runner.trace(started(tool_block_id(1, 2)))
  runner.trace(reported(tool_block_id(1, 2)))
  assert_eq(runner.live.length(), 2, msg="the live view holds the wrong pieces")
  assert_true(
    runner.live[0] is @html.Tool(..),
    msg="the running entry should have been replaced, not added to",
  )
  assert_true(
    runner.live[1] is @html.Tool(..),
    msg="the second tool is its own entry",
  )
}

///|
/// The block a tool starts as and the block it is patched into carry one id, built one way.
///
/// The duplicate literal this replaced was two format strings that had to stay identical by
/// inspection, and the failure mode if they ever stopped matching is silent: the client ignores a
/// patch whose target is missing, so the tool's output would never appear and nothing would say so.
test "a tool's block id is what both halves of its life agree on" {
  assert_eq(tool_block_id(1, 1), "live-tool-1-1")
  assert_eq(tool_block_id(12, 34), "live-tool-12-34")
  // And the running rendering and the finished one both accept it, which is the agreement in code
  // rather than in prose.
  let running = @html.render_running_tool(tool_block_id(1, 2), "bash", "x", 0L).render()
  let finished = @html.render_tool(
    tool_block_id(1, 2),
    @core.ToolCall(id="c", name="bash", arguments=Json::object(Map([]))),
    Some({
      tool_call_id: "c",
      tool_name: "bash",
      content: [@core.Text("done")],
      is_error: false,
      timestamp: 0L,
      details: None,
    }),
  ).render()
  for html in [running, finished] {
    assert_true(html.contains("id=\"live-tool-1-2\""), msg=html)
  }
}
