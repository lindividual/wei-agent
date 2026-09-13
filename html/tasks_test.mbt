///|
/// The background panel keeps live jobs and counts the finished ones rather than listing a card
/// for every command ever run. The panel sits above the session list, so an unbounded history is
/// paid for by the thing the reader came to the sidebar to click.
test "the background panel caps finished jobs but never drops a live one" {
  let items : Array[JobItem] = []
  for i in 0..<6 {
    items.push(job_item("done-\{i}", false, 1000L * (i + 1).to_int64()))
  }
  for i in 0..<2 {
    items.push(job_item("live-\{i}", true, 1000L))
  }
  let html = render_jobs(items, 1_700_000_000_000L).render()
  // Both live ones, with the only way to stop them.
  assert_eq(count_of(html, "data-kill="), 2, msg=html)
  // Three finished ones, and a count of the rest rather than silence.
  assert_eq(count_of(html, "task done"), 3, msg=html)
  assert_true(html.contains("3 older"), msg=html)
}

///|
/// One job, as the tests build them.
fn job_item(id : String, live : Bool, age_ms : Int64) -> JobItem {
  {
    id,
    label: "sleep 300",
    kind: "bash",
    status: if live {
      "running"
    } else {
      "completed"
    },
    age_ms,
    pids: if live {
      [42]
    } else {
      []
    },
    live,
    detail: if live {
      ""
    } else {
      "exited on its own"
    },
  }
}
