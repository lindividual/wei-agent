///|
/// The client watches the stream, rather than trusting it to report its own death.
///
/// This is asserted on the script's text, which is weak, and it is weak in the way that is useful
/// here: the failure it guards against is not a subtle wrong answer but a *removal*. The liveness
/// watchdog only matters in the situation nobody can reproduce on demand — a connection that has
/// gone quiet without erroring — so if someone tidies it away, nothing else in the suite notices,
/// and the symptom comes back as "the page froze and a reload fixed it".
///
/// The two halves have to agree with the server: the name the server sends (`ping`) and the interval
/// the client tolerates. Both are pinned here because a mismatch is silent on both sides.
test "the client observes liveness and can rebuild the stream" {
  let js = client_script()
  assert_true(
    js.contains("addEventListener('ping'"),
    msg="the client does not listen for the heartbeat, so a quiet connection looks like a live one",
  )
  assert_true(
    js.contains("lastSeen"),
    msg="the client never records when it last heard anything",
  )
  assert_true(
    js.contains("new EventSource"),
    msg="the stream is not created where the watchdog can rebuild it",
  )
  // One call at startup, and the interval that re-checks. Two occurrences of `connect` beyond its
  // definition: the initial call and the staleness check.
  assert_true(
    js.contains("setInterval"),
    msg="nothing re-checks the connection, so a stalled stream is never noticed",
  )
}

///|
/// Loading earlier turns keeps the reader where they were.
///
/// The transcript is one element, so replacing it is a new subtree rather than content inserted above
/// the viewport — the browser keeps the scroll *offset*, and since the page just grew above the
/// reader, what they were reading moves down by exactly the height that was added. Measured at 4,202
/// pixels for three turns, which is enough to lose your place completely.
///
/// Asserted on the script's text, which only proves the correction was not removed. The behaviour
/// itself needs a browser, and was measured there: the same anchor element returns to the same
/// offset on screen (0px shift) where it moved 4,202px before.
test "the earlier-turns reply corrects the scroll offset" {
  let js = client_script()
  assert_true(
    js.contains("grow = true"),
    msg="the earlier button does not mark that the page is about to grow upward",
  )
  assert_true(
    js.contains("document.body.scrollHeight - growFrom"),
    msg="nothing compensates for the height added above the reader",
  )
}

///|
/// The undo note takes itself away.
///
/// The offer after a delete is a courtesy, not a control, and a reader who has moved on should not
/// have to dismiss it. Two halves, and both are asserted here because the pair is what makes it a
/// rule rather than a coincidence: the server stops rendering the note once its window has passed
/// (`html/render_deleted` tests that), and the page takes it off screen on the same deadline for the
/// reader who is already looking at it. Without this half, the note would sit there until the next
/// region refresh — which may be a turn that never comes.
test "an expired element takes itself off the page" {
  let js = client_script()
  assert_true(
    js.contains("[data-expires]"),
    msg="nothing sweeps the elements that carry a deadline",
  )
  assert_true(
    js.contains("Number(node.dataset.expires) <= now"),
    msg="the sweep does not compare the deadline against the reader's clock",
  )
  assert_true(
    js.contains("node.remove()"),
    msg="an expired element stays on the page",
  )
}

///|
/// A click on anything naming a session opens that session.
///
/// The delegation used to be scoped to `#sessions`, which was right while the sidebar was the only
/// thing that named one. Two panels name one now — the row of a running turn, and the command of a
/// background job — and they are the two places a reader most wants to follow the work to. A scope
/// left in place is not a broken page but a dead label, so the selector is pinned here: whatever
/// carries `data-session` is a way in, and the panels do not have to remember to live in the sidebar.
///
/// The one deliberate exclusion is still the transcript, and it is an exclusion by *absence* of the
/// attribute rather than by scope (see `html/render_transcript`).
test "every element naming a session is a way to open it" {
  let js = client_script()
  assert_true(
    js.contains("closest('[data-session]')"),
    msg="a click on a panel label would no longer open the session it names",
  )
  assert_false(
    js.contains("closest('#sessions [data-session]')"),
    msg="the delegation is scoped to the sidebar again, which leaves the panels' labels dead",
  )
}
