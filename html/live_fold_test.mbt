///|
/// The fold a running turn puts its finished tools into.
///
/// Two rules, and they have to be the *same* rules the streaming path reaches, because the two meet:
/// this snapshot is what a browser joining mid-turn is given, and the stream then keeps writing into
/// those nodes. Disagree about the structure and a patch lands on an element that is not there — and
/// the client drops a patch whose target is missing without saying anything, which is the failure
/// this whole arrangement exists to avoid.
///
/// The rule itself: the fold holds every finished tool except the newest one while a tool is still
/// running, and every finished tool once none is. A tool's block is worth looking at while it is the
/// newest thing that happened, and worth nothing once the turn has moved on.

///|
fn args_for(command : String) -> Json {
  Json::object(Map([("command", Json::string(command))]))
}

///|
fn call_for(id : String, command : String) -> @core.Content {
  @core.ToolCall(id~, name="bash", arguments=args_for(command))
}

///|
fn result_for(id : String) -> @core.ToolResultMessage {
  {
    tool_call_id: id,
    tool_name: "bash",
    content: [@core.Text("done")],
    is_error: false,
    timestamp: 0L,
    details: None,
  }
}

///|
fn tool(id : String) -> LivePiece {
  Tool(id~, call=call_for(id, "echo \{id}"), result=result_for(id))
}

///|
fn busy(id : String) -> LivePiece {
  RunningTool(
    id~,
    name="bash",
    arguments=args_for("/bin/sleep 30"),
    since=1700000000000L,
  )
}

///|
/// The pieces of a running turn, as the transcript of the fold.
///
/// Written as a plain string so the shape of the nesting is visible in the failure message: who is
/// inside the fold and who is outside is the whole subject here.
fn shape(index : Int, pieces : Array[LivePiece]) -> String {
  let html = render_running_exchange(index, "q", pieces).render()
  let root = html.find("id=\"streams-").unwrap()
  let inside = html[root:]
  let fold_at = inside.find("class=\"work\"")
  match fold_at {
    None => "no fold"
    Some(at) => {
      // The fold's own subtree: up to the `</details>` that closes it, counting one level of nesting.
      let rest = inside[at:]
      let end = rest.find("</details></details>").unwrap_or(rest.length())
      let fold = rest[:end]
      let parts : Array[String] = []
      if fold.contains("id=\"live-tool-1\"") {
        parts.push("1")
      }
      if fold.contains("id=\"live-tool-2\"") {
        parts.push("2")
      }
      if fold.contains("id=\"live-tool-3\"") {
        parts.push("3")
      }
      "fold[\{parts.join(",")}]"
    }
  }
}

///|
test "the fold holds every finished tool but the newest" {
  // Two tools done and a third under way: the second is what the reader is coming back from, so it
  // stays out; the first is history.
  assert_eq(
    shape(1, [tool("live-tool-1"), tool("live-tool-2"), busy("live-tool-3")]),
    "fold[1]",
  )
  // Three done and nothing running: the same rule, and it has to be the same one — the newest
  // finished tool is put away when the next tool starts, not when the turn stops.
  assert_eq(
    shape(1, [tool("live-tool-1"), tool("live-tool-2"), tool("live-tool-3")]),
    "fold[1,2]",
  )
  // One tool and nothing else: it is the newest finished thing there is, so it stays out. A fold
  // with nothing in it is not rendered, which is also the state of a turn before its second tool.
  assert_eq(shape(1, [tool("live-tool-1")]), "no fold")
}

///|
test "a turn with nothing finished yet has no fold to open" {
  // A fold appears when there is a first thing to put in it. Rendering one earlier would put a closed
  // disclosure on the page saying the turn had worked through no tool calls.
  assert_eq(shape(1, [busy("live-tool-1")]), "no fold")
  assert_eq(
    shape(1, [Thinking(id="t1", text="thinking"), busy("live-tool-1")]),
    "no fold",
  )
}

///|
/// The part that the fold must *not* swallow: what the model is doing.
///
/// A tool's result is something the reader asked for once and is done with; reasoning and the prose
/// between tool calls are the model explaining itself, and they have no other home. Putting those
/// away would leave a page that shows nothing but a clock.
test "reasoning and what the model is saying stay outside the fold" {
  let html = render_running_exchange(1, "q", [
    Thinking(id="live-think-1", text="I should look at the logs"),
    Text(id="live-text-1", text="Let me check."),
    tool("live-tool-1"),
    tool("live-tool-2"),
    busy("live-tool-3"),
  ]).render()
  let fold_at = html.find("class=\"work\"").unwrap()
  let fold_end = html[fold_at:].find("</details></details>").unwrap() + fold_at
  let fold = html[fold_at:fold_end]
  let outside = html[:fold_at].to_owned() + html[fold_end:].to_owned()
  for content in ["I should look at the logs", "Let me check."] {
    assert_true(
      fold.contains(content) == false,
      msg="\{content} should not be in the fold:\n\{html}",
    )
    assert_true(
      outside.contains(content),
      msg="\{content} should be outside the fold:\n\{html}",
    )
  }
  // And the tool that is still running is outside too — it is the thing being shown.
  assert_true(outside.contains("/bin/sleep 30"), msg=html)
  assert_true(fold.contains("/bin/sleep 30") == false, msg=html)
}

///|
/// The fold takes the place of the first tool it put away.
///
/// Position is what makes it read as the turn's working: everything said before the tools stays
/// before them, everything said after stays after. A fold appended at the end would put the middle of
/// the turn below the end of it.
test "the fold sits where the first folded tool was, not at the end" {
  let html = render_running_exchange(1, "q", [
    Thinking(id="live-think-1", text="reasoning first"),
    tool("live-tool-1"),
    tool("live-tool-2"),
    Text(id="live-text-1", text="and now the summary"),
    busy("live-tool-3"),
  ]).render()
  let think_at = html.find("reasoning first").unwrap()
  let fold_at = html.find("class=\"work\"").unwrap()
  let text_at = html.find("and now the summary").unwrap()
  assert_true(think_at < fold_at, msg=html)
  assert_true(fold_at < text_at, msg=html)
}

///|
/// A tool that is running, filed into the fold. The two attributes are the whole instruction.
///
/// The *oldest* finished tool is the one filed, not the newest: the fold wants the one the turn has
/// moved past, and the reader wants the one that just came back.
test "a running block can name the finished block to put away, and where" {
  // The instruction rides on the frame that starts the *next* tool, because that is the moment the
  // previous one stops being the newest thing that happened. It names both the block and the fold:
  // the server knows both, and a browser that had to work them out would be re-implementing the rule
  // above. So it is a property of the rendering function, not of the snapshot.
  let plain = render_running_tool("live-tool-2", "bash", args_for("x"), 0L).render()
  assert_false(plain.contains("data-file"), msg=plain)
  let filing = render_running_tool(
    "live-tool-2",
    "bash",
    args_for("x"),
    0L,
    file=Some("live-tool-1"),
    file_into="live-work-4",
  ).render()
  assert_true(filing.contains("data-file=\"live-tool-1\""), msg=filing)
  assert_true(filing.contains("data-file-into=\"live-work-4\""), msg=filing)
  // And it is still the same running block in every other respect: a turn's third tool must be the
  // same kind of thing as its first.
  assert_true(filing.contains("class=\"tool running\""), msg=filing)
  assert_true(filing.contains("open=\"\""), msg=filing)
}

///|
test "the running block with no earlier tool to file carries no instruction" {
  let html = render_running_tool(
    "live-tool-1-1",
    "bash",
    args_for("/bin/sleep 30"),
    0L,
  ).render()
  assert_false(html.contains("data-file"), msg=html)
}

///|
test "the fold's ids are the ones the stream keeps writing to" {
  let html = render_running_exchange(7, "q", [
    tool("live-tool-1"),
    tool("live-tool-2"),
    busy("live-tool-3"),
  ]).render()
  assert_true(html.contains("id=\"live-work-7\""), msg=html)
  assert_true(html.contains("id=\"live-work-7-label\""), msg=html)
  // The label is a node of its own so it can be replaced on its own. Replacing the fold to move a
  // number would take with it the blocks the browser had been moving in.
  let label = label_of(html)
  assert_eq(label, "worked through 1 tool call", msg=label)
}

///|
/// Pull the live fold's summary text out of a rendered exchange.
fn label_of(html : String) -> String {
  let at = html.find("id=\"live-work-7-label\"").unwrap()
  let rest = html[at:]
  let open = rest.find(">").unwrap() + 1
  let close = rest.find("</summary>").unwrap()
  rest[open:close].to_owned()
}

///|
test "the fold's label counts what is in it, in the singular when there is one" {
  assert_eq(live_work_label(1), "worked through 1 tool call")
  assert_eq(live_work_label(3), "worked through 3 tool calls")
  assert_eq(live_work_label(0), "worked through 0 tool calls")
}
