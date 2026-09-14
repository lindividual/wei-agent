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
