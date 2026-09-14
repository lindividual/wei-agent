///|
/// Every card the background panel draws is a job that can be stopped.
///
/// Which jobs reach here is the `ui` package's decision — only the live ones do. What this package
/// owns is the shape: a Kill button on every card, and no finished-job bookkeeping left behind. A
/// card without a Kill would be a row the reader can neither act on nor dismiss, which is exactly
/// what the panel is above the session list for.

///|
/// The panel's rows are labeled by a session, and the label is the way to it.
///
/// The card has to answer "which session is this?" as well as "can I stop it?", because a job is
/// work that outlived the turn that started it and the reader's next move is usually to go and look
/// at it. The label carries the same `data-session` the sidebar's rows do — one convention, one
/// client handler — and Stop keeps its own attribute beside it.
test "each job card offers a Kill and a way back to its session" {
  let items : Array[JobItem] = []
  for i in 0..<2 {
    items.push(job_item("live-\{i}", 1000L))
  }
  let html = render_jobs(items, 1_700_000_000_000L).render()
  assert_eq(count_of(html, "data-kill="), 2, msg=html)
  assert_eq(count_of(html, "class=\"task\""), 2, msg=html)
  assert_eq(count_of(html, "data-session=\"/store/one.jsonl\""), 2, msg=html)
  // No `data-session` on the Kill button: one click must not both open a session and end a job.
  assert_eq(count_of(html, "data-kill=\"/store/one.jsonl\""), 0, msg=html)
  assert_false(html.contains("task done"), msg=html)
  assert_false(html.contains("older"), msg=html)
}

///|
/// Nothing running is an empty container rather than an empty heading: a section that is usually
/// empty should not take up space or attention.
test "the background panel takes no space when no job is live" {
  let items : Array[JobItem] = []
  assert_eq(render_jobs(items, 1L).render(), "<div id=\"jobs\"></div>")
}

///|
/// One job, as the tests build them.
fn job_item(id : String, age_ms : Int64) -> JobItem {
  {
    id,
    label: "sleep 300",
    kind: "bash",
    status: "running",
    age_ms,
    pids: [42],
    session: "/store/one.jsonl",
  }
}
