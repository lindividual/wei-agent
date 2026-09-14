///|
/// A window over a transcript: the newest turns, and an honest way back.
///
/// The reason this exists is size. Measured on a real 14-turn session, the newest six exchanges are
/// about a third of the HTML and a third of the DOM nodes, and those two are most of what switching
/// to a session costs. The assertions below are about what must stay true when the transcript is
/// clipped: the ids have to keep matching the ones the stream used, or a patch lands nowhere.

///|
fn turns(count : Int) -> Array[@core.ContextMessage] {
  let out : Array[@core.ContextMessage] = []
  for i in 0..<count {
    out.push(@core.User({ content: [@core.Text("q\{i}")], timestamp: 0L, }))
    out.push(assistant_reply("a\{i}"))
  }
  out
}

///|
fn assistant_reply(text : String) -> @core.ContextMessage {
  @core.Assistant({
    content: [@core.Text(text)],
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
/// The window is exact, at every size.
///
/// Written as a loop because the off-by-one this guards against is not a constant: the last exchange
/// is flushed after the walk rather than inside it, so "count the user messages" and "count the
/// rendered exchanges" disagree by one — and an earlier version of this code did exactly that,
/// rendering one turn more than asked. Checking one size would have passed on the wrong half.
test "a window renders exactly the turns it was asked for" {
  for limit in [1, 2, 3, 6, 13] {
    let html = render_transcript(turns(14), limit~).render()
    assert_eq(
      count_of(html, "class=\"exchange\""),
      limit,
      msg="limit \{limit} rendered the wrong number of turns",
    )
    // Singular at one, which is the sort of thing a written-out expectation gets wrong.
    let missing = 14 - limit
    let expected = if missing == 1 {
      "1 earlier turn"
    } else {
      "\{missing} earlier turns"
    }
    assert_true(html.contains(expected), msg="expected \{expected} in \{html}")
  }
}

///|
test "a window renders the newest turns and counts the rest" {
  let html = render_transcript(turns(14), limit=6).render()
  assert_eq(count_of(html, "class=\"exchange\""), 6, msg=html)
  // The control names how much is missing, so a reader knows what they are opening.
  assert_true(html.contains("8 earlier turns"), msg=html)
  // The newest turn is present and the oldest is not.
  assert_true(html.contains("q13"), msg=html)
  assert_false(html.contains(">q0<"), msg=html)
}

///|
/// Ids keep the numbers they had when they were streamed.
///
/// This is the part that would rot silently. The live patches target `exchange-7-blocks` and
/// `b7-0`; if clipping renumbered exchanges from the window, the ids in the page and the ids in the
/// stream would disagree and every later patch would land on nothing — with no error anywhere.
test "a window does not renumber the exchanges it keeps" {
  let html = render_transcript(turns(14), limit=6).render()
  // Exchanges 9..13 survive, so the last one is still 13, not 4.
  assert_true(html.contains("id=\"exchange-13\""), msg=html)
  assert_true(html.contains("id=\"b13-0\""), msg=html)
  assert_false(
    html.contains("id=\"exchange-4\""),
    msg="a dropped turn must not be rendered",
  )
}

///|
test "a transcript shorter than the window is untouched" {
  let html = render_transcript(turns(3), limit=6).render()
  assert_eq(count_of(html, "class=\"exchange\""), 3, msg=html)
  assert_false(html.contains("earlier turn"), msg=html)
}

///|
/// No limit means no limit: the default has to be "render everything" so that every existing caller
/// and the whole test suite keep meaning what they meant.
test "no window renders the whole conversation" {
  let html = render_transcript(turns(14)).render()
  assert_eq(count_of(html, "class=\"exchange\""), 14, msg=html)
  assert_false(html.contains("earlier turn"), msg=html)
}
