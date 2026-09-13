///|
/// Reasoning has two shapes, and the difference between them is the whole point.
///
/// While it is arriving it is a `div` with a button, because a reader wants three states — the
/// newest few lines, all of it, out of the way — and a `<details>` has two. Once the turn ends it
/// is a collapsed `<details>`, because two is all that is wanted then. Both are asserted here so a
/// change to one that quietly changes the other's behaviour is not a silent difference.

///|
test "reasoning in flight is not a details, and says what its button controls" {
  let html = render_thinking_stream(
    "t1",
    "t1-body",
    text="first\nsecond\nthird\nfourth",
  ).render()
  assert_false(html.contains("<details"), msg=html)
  // The button names the block it opens, so the client never has to guess which one it is; and it
  // starts closed, because the newest-lines view is the closed state.
  assert_true(html.contains("data-expands=\"t1\""), msg=html)
  assert_true(html.contains("aria-expanded=\"false\""), msg=html)
  assert_true(html.contains("aria-controls=\"t1-body\""), msg=html)
  // All of the text is sent, not three lines of it. How much is shown is a stylesheet's business:
  // a server that trimmed the text here would leave the reader nothing to expand *into*, and the
  // streaming path appends deltas — it has no idea where a line ends.
  assert_true(html.contains("fourth"), msg=html)
  assert_true(html.contains("first"), msg=html)
  assert_eq(count_of(html, "id=\"t1-body\""), 1, msg=html)
}

///|
/// The finished shape, which the streaming one has to be replaced *by*.
///
/// The id is the same one the stream was appending into, and the element is a closed `<details>`:
/// that is what makes "the turn ended, stop showing me the reasoning" a thing the replacement does
/// rather than a thing the client has to be told about.
test "reasoning that has finished is a collapsed details" {
  let html = render_block(
    "b1",
    @core.Thinking(thinking="some reasoning", signature="reasoning_content"),
  ).render()
  assert_true(html.contains("<details"), msg=html)
  assert_true(html.contains("class=\"thinking\" id=\"b1\""), msg=html)
  // No `open`, and nothing else that would make the browser start it expanded.
  assert_false(html.contains("open"), msg=html)
}
