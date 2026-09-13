///|
/// What the page says when there is nothing in it yet.
///
/// The empty conversation is the only state where a reader has no conversation to learn from, so it
/// is the only place the page can teach anything — and until this existed, it taught nothing.

///|
test "an empty transcript offers a starting point" {
  let html = render_welcome().render()
  assert_true(html.contains("class=\"welcome\""), msg=html)
  // Fillable rather than sent: the reader's next move is to type, and a suggestion they have to
  // retype is a tax on the one action the page wants from them.
  assert_true(count_of(html, "data-fill=") >= 3, msg=html)
  // And it says how to send, which nothing else on the page does once the placeholder is gone.
  assert_true(html.contains("to send"), msg=html)
}

///|
/// The awkward half of an empty state: it has to know when it is no longer true.
///
/// `render_transcript` is the place that can tell, because it is the function that walks the
/// messages — including the ones that have not been committed yet, which is why the check is on the
/// assembled sections rather than on the array it was handed.
test "the welcome appears only when the transcript would otherwise be empty" {
  let empty = render_transcript([]).render()
  assert_true(
    empty.contains("class=\"welcome\""),
    msg="an empty transcript should teach: \{empty}",
  )
  let said = render_transcript([
    @core.User({ content: [@core.Text("hello")], timestamp: 0L, }),
  ]).render()
  assert_false(
    said.contains("class=\"welcome\""),
    msg="the welcome must go once there is something to read",
  )
  // A turn that is still arriving is something to look at, so the welcome must not talk over it.
  let running = render_transcript([], extra=[
    el(Div, attrs=[attr("id", "exchange-0")], children=[]),
  ]).render()
  assert_false(
    running.contains("class=\"welcome\""),
    msg="a running turn is not an empty page",
  )
}

///|
/// Every command the composer answers is offered, so the list is a real index of what can be typed.
///
/// The list is the discoverability half of `/name` and `/model`: `parse_command` is what makes them
/// work, and nothing else on the page says they exist.
test "the command list names the commands the composer understands" {
  let hints = commands()
  let html = render_commands(hints).render()
  assert_true(html.contains("/name "), msg=html)
  assert_true(html.contains("/model "), msg=html)
  // A space after each, so the caret lands where the argument goes.
  assert_true(html.contains("data-fill=\"/name \""), msg=html)
  // Hidden until the reader opens a command: the list must not be a permanent band under the box.
  assert_true(html.contains("hidden"), msg=html)
}
