///|
/// The model picker.
///
/// The contract with the client is what these pin: the id the `change` listener delegates on, the
/// field name the body is read from, one `selected` option, and the `disabled` that keeps a
/// running turn's log from being forked. The looks are not asserted, but the *shape* is: a
/// `<select>` and not a list of buttons, because that is what makes it keyboard-reachable.

///|
fn picker(current : String, locked : Bool) -> ModelPicker {
  { current_id: current, models: @core.model_catalog(), locked, }
}

///|
test "the picker is a select carrying the id and the field name the client posts" {
  let html = render_model_picker(picker("deepseek-v4-pro", false)).render()
  assert_true(html.has_prefix("<select"), msg=html)
  assert_true(html.contains("id=\"model-picker\""), msg=html)
  // The listener reads `picker.value`, and the body is the id alone, so the option values are the
  // wire ids — not the labels a reader sees.
  assert_true(html.contains("name=\"model\""), msg=html)
  for id in @core.model_ids() {
    let wanted = "value=\"" + id + "\""
    assert_true(html.contains(wanted), msg="missing " + wanted)
  }
}

///|
test "exactly the current model is selected" {
  let html = render_model_picker(picker("deepseek-v4-pro", false)).render()
  assert_eq(count_of(html, "selected"), 1)
  let at = html.find("value=\"deepseek-v4-pro\"").unwrap()
  assert_true(
    html[at:].has_prefix("value=\"deepseek-v4-pro\" selected"),
    msg=html,
  )
}

///|
/// A turn running is the one state that must not be changeable: the entry would be appended off
/// the turn's own leaf and land on a branch nobody walks.
test "a running turn disables the picker and says why" {
  let locked = render_model_picker(picker("deepseek-v4-flash", true)).render()
  assert_true(locked.contains("disabled"), msg=locked)
  assert_true(locked.contains("cannot change the model"), msg=locked)
  let free = render_model_picker(picker("deepseek-v4-flash", false)).render()
  assert_false(free.contains("disabled"), msg=free)
  // Closed, the select shows the label of the selected option, which is what a reader recognises.
  assert_true(free.contains("DeepSeek V4 Flash"), msg=free)
}

///|
/// An unknown model — a log from a newer build — is still listed and still selected, so the
/// control does not silently claim the session is on something else.
test "an unknown model stays listed and selected" {
  let unknown : ModelPicker = {
    ..picker("deepseek-v9-someday", false),
    models: [
      { ..@core.default_model(), id: "deepseek-v9-someday", name: "someday", },
      ..@core.model_catalog(),
    ],
  }
  let html = render_model_picker(unknown).render()
  assert_true(html.contains("value=\"deepseek-v9-someday\" selected"), msg=html)
  assert_eq(count_of(html, "selected"), 1)
}

///|
/// The composer carries the picker and the figures, and keeps the things that must not move: the
/// textarea, the send and stop buttons, and the form the prompt is submitted through.
///
/// The picker used to sit in the corner of the box's own row. It is on the line under it now,
/// beside the figures — so this pins the two ids that the composer is the only home for, and the
/// region the picker is replaced through.
test "the composer holds the picker without disturbing what was there" {
  let html = composer(picker("deepseek-v4-flash", false), true, commands(), [
    chip("cost", "$0.01"),
  ]).render()
  assert_true(html.contains("id=\"composer\""), msg=html)
  assert_true(html.contains("id=\"prompt\""), msg=html)
  assert_true(html.contains("id=\"send\""), msg=html)
  assert_true(html.contains("id=\"stop\""), msg=html)
  assert_true(html.contains("id=\"model-picker\""), msg=html)
  // The id is the patch target, so it must appear exactly once — a second one would make which
  // element gets replaced depend on document order. The same goes for the figures, which arrive as
  // a region of their own.
  assert_eq(count_of(html, "id=\"model-picker\""), 1)
  assert_eq(count_of(html, "id=\"usage\""), 1)
  assert_true(html.contains("$0.01"), msg=html)
  // The figures are under the box, not beside it: the input keeps the width it had.
  let box = match html.find("id=\"prompt\"") {
    Some(at) => at
    None => -1
  }
  let figures = match html.find("id=\"usage\"") {
    Some(at) => at
    None => -1
  }
  assert_true(box >= 0 && figures > box, msg=html)
}

///|
/// Stop is offered while there is something to stop and greyed out when there is not, rather than
/// being live in every state and doing nothing in two of them.
test "Stop is disabled when no turn is running in this session" {
  let idle = composer(picker("deepseek-v4-flash", false), false, commands(), []).render()
  assert_true(idle.contains("id=\"stop\""), msg=idle)
  assert_true(
    idle.contains("disabled"),
    msg="idle Stop should be disabled: \{idle}",
  )
  assert_true(idle.contains("nothing is running"), msg=idle)
  let busy = composer(picker("deepseek-v4-flash", false), true, commands(), []).render()
  assert_false(
    busy.contains("disabled"),
    msg="running Stop should be live: \{busy}",
  )
  assert_true(busy.contains("stop this turn"), msg=busy)
}

///|
/// A command list, as the tests build one.
fn commands() -> Array[CommandHint] {
  [
    { insert: "/name ", what: "name this session", },
    { insert: "/model ", what: "switch the model", },
  ]
}
