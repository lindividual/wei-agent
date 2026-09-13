///|
/// A tool block, from the moment it starts to the moment it is replaced by its result.
///
/// This is the shape part of the feature. The part that cannot be asserted here is that the id the
/// running block is given is the same id the report is patched in at, because that is decided in
/// `ui/turn.mbt` — but the two halves are pinned on this side so that a change to either one that
/// breaks the agreement shows up as a failing test rather than as a tool whose output silently never
/// appears.

///|
fn args(command : String) -> Json {
  Json::object(Map([("command", Json::string(command))]))
}

///|
fn running(id : String) -> LivePiece {
  RunningTool(
    id~,
    name="bash",
    arguments=args("/bin/sleep 30"),
    since=1700000000000L,
  )
}

///|
fn result(output : String) -> @core.ToolResultMessage {
  {
    tool_call_id: "call-1",
    tool_name: "bash",
    content: [@core.Content::Text(output)],
    is_error: false,
    timestamp: 0L,
    details: None,
  }
}

///|
fn call() -> @core.Content {
  @core.ToolCall(id="call-1", name="bash", arguments=args("/bin/sleep 30"))
}

///|
/// The state a block is drawn in: running, arriving, or read back later.
///
/// Three names for what is nearly one rendering, because the differences between them are the whole
/// feature — and they are differences of `open` and one attribute, not of structure.
enum Phase {
  Running
  Settling
  Done
} derive(Eq)

///|
fn block(id : String, phase : Phase, output : String) -> String {
  match phase {
    Running =>
      render_running_tool(id, "bash", args("/bin/sleep 30"), 1700000000000L).render()
    Settling =>
      render_tool(id, call(), Some(result(output)), settling=true).render()
    Done => render_tool(id, call(), Some(result(output))).render()
  }
}

///|
test "a running tool is open, counted, and shows the call" {
  let html = block("live-tool-1-1", Running, "")
  assert_true(html.contains("class=\"tool running\""), msg=html)
  // `open` is what makes it visible without a click, and `open=""` is how this program writes a
  // valueless attribute (`html/sessions.mbt` does the same for the active workspace).
  assert_true(html.contains("open=\"\""), msg=html)
  // The clock is both drawn and carried: drawn so the first paint is right, carried so the browser
  // can keep it moving without a frame a second from the server.
  assert_true(html.contains("data-since=\"1700000000000\""), msg=html)
  assert_true(html.contains("<time"), msg=html)
  // The arguments, in the same `<pre>` the finished block uses. This is the "not shown incompletely"
  // half: a running block used to render a one-line summary here instead, so it looked like a
  // thinner, different element than the one it turns into.
  assert_true(html.contains("class=\"args\""), msg=html)
  assert_true(html.contains("/bin/sleep 30"), msg=html)
  // And the body shape the finished block has, down to the placeholder a result will replace.
  assert_true(html.contains("class=\"pending\""), msg=html)
}

///|
/// The property that matters most here: a block does not change shape when the tool ends.
///
/// A reader watching a block that then visibly becomes a different element has to re-find what they
/// were looking at. So the *call* half is compared byte for byte between the two renderings — the
/// arguments, the `<pre>` they are in, everything between the summary and the body — and the parts
/// that are supposed to differ are asserted separately: a clock and a class while it runs, a
/// placeholder instead of a result.
test "the running block and the finished one are the same block" {
  let running_html = block("t", Running, "")
  let done_html = block("t", Done, "ok")
  // The call rendering, with the two ends trimmed off: whatever is between the summary and the body.
  let call_part = (html : String) => {
    let after = html[html.find("</summary>").unwrap() + 10:]
    let body_at = after.find("<div class=").unwrap()
    after[:body_at].to_owned()
  }
  let same_call = call_part(running_html)
  assert_eq(
    same_call,
    call_part(done_html),
    msg="the call should render identically running and finished:\n\{running_html}\n\{done_html}",
  )
  // And it is the real thing, not an empty match: the arguments in their `<pre>`.
  assert_true(same_call.contains("class=\"args\""), msg=same_call)
  assert_true(same_call.contains("/bin/sleep 30"), msg=same_call)
  // Same element, same id; the only difference in the opening tag is the state class and `open`.
  assert_true(
    running_html.contains("<details class=\"tool running\" id=\"t\" open=\"\">"),
    msg=running_html,
  )
  assert_true(
    done_html.contains("<details class=\"tool\" id=\"t\">"),
    msg=done_html,
  )
  // The body is the one part that is meant to differ: the running line while it runs, the result
  // once it is over. The clock travels with it — it is part of that line.
  assert_true(
    running_html.contains(
      "<div class=\"pending\">running… · <time data-since=\"1700000000000\">",
    ),
    msg=running_html,
  )
  assert_true(done_html.contains("class=\"result-body\""), msg=done_html)
  // And the summary is not one of the parts that differ any more: both say the tool's name and
  // nothing else, so a block does not even change its heading when the tool ends.
  assert_true(
    running_html.contains("<summary>bash</summary>"),
    msg=running_html,
  )
  assert_true(done_html.contains("<summary>bash</summary>"), msg=done_html)
}

///|
/// A result is handed over open, and only for a moment.
///
/// The result is the thing the reader was waiting for; arriving already folded puts it behind a
/// click nobody knows to make. So the frame that carries it open is the frame that also says how
/// long to leave it that way — and the attribute is gone from every other rendering of the same
/// block, which is what keeps this a transient rather than a state the server has to remember.
test "the result arrives open, for a moment, and only once" {
  let settling = block("t", Settling, "ok")
  assert_true(settling.contains("open=\"\""), msg=settling)
  assert_true(settling.contains("data-settle=\"1000\""), msg=settling)
  // The result itself is in there, which is the point of opening it.
  assert_true(settling.contains("class=\"result\""), msg=settling)
  assert_true(settling.contains("ok"), msg=settling)
  // A reloaded transcript — the same tool, rendered later from the log — is folded and says nothing
  // about settling. That is what makes "leave it open a second" a moment rather than a state: the
  // server never has to know which blocks a reader has already seen.
  let done = block("t", Done, "ok")
  assert_false(done.contains("open="), msg=done)
  assert_false(done.contains("data-settle"), msg=done)
}

///|
test "the running block and the finished block are the same element, so one replace is enough" {
  // Same id on both, which is the whole mechanism: the report is patched in *at* the running
  // block's id rather than appended after it. Appending was the earlier shape and it left the
  // running block behind for good.
  let running_html = render_running_exchange(1, "q", [running("live-tool-1-1")]).render()
  let finished_html = block("live-tool-1-1", Settling, "ok")
  for html in [running_html, finished_html] {
    assert_true(html.contains("id=\"live-tool-1-1\""), msg=html)
  }
  // And the frames that arrive shut are the ones that are read back, not the one that is handed
  // over: the settled rendering is what a reload produces.
  assert_true(running_html.contains("open=\"\""), msg=running_html)
  assert_false(
    block("live-tool-1-1", Done, "ok").contains("open="),
    msg="a re-read block folds",
  )
  assert_true(finished_html.contains("result-body"), msg=finished_html)
}

///|
/// A snapshot of a running turn has to include the tool that is mid-flight.
///
/// This is the assertion that stands in for the whole feature's risk. Before `RunningTool` existed,
/// this snapshot had no way to represent a tool that had started but not reported — so a browser
/// that connected or refreshed while a tool was running got a stream root without that block in it,
/// the report was patched at an id that was not there, and the client dropped it in silence
/// (`if (!node) return`). Everything else in the page kept working, which is what made it expensive.
test "a snapshot of a running turn shows the tool that is in flight" {
  let html = render_running_exchange(3, "what is the deploy doing", [
    Thinking(id="live-think-3-1", text="I should look at the logs"),
    running("live-tool-3-2"),
  ]).render()
  assert_true(html.contains("id=\"live-tool-3-2\""), msg=html)
  assert_true(html.contains("class=\"tool running\""), msg=html)
  // And it carries the arguments too, so the block a late arrival sees is the block everyone else
  // is looking at rather than a thinner one.
  assert_true(html.contains("/bin/sleep 30"), msg=html)
  // The ids the stream writes into are the ones the snapshot hands back, so a turn that is
  // continued rather than restarted keeps landing in the same nodes.
  assert_true(html.contains("id=\"streams-3\""), msg=html)
  assert_true(html.contains("id=\"live-think-3-1\""), msg=html)
}
