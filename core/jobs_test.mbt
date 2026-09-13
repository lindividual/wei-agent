///|
/// The job state machine, without a process table.

///|
test "jobs are numbered per kind, as dsh numbers them" {
  let store = JobStore::new()
  let first = store.start(
    kind="bash",
    label="npm run dev",
    session="/a",
    started_at=0L,
    pids=[10],
  )
  let second = store.start(
    kind="bash",
    label="sleep 30",
    session="/a",
    started_at=1L,
    pids=[11],
  )
  assert_eq(first, "bash-1")
  assert_eq(second, "bash-2")
  assert_eq(store.list().length(), 2)
}

///|
test "a live job is the only thing worth showing prominently" {
  let store = JobStore::new()
  let id = store.start(
    kind="bash",
    label="npm run dev",
    session="/a",
    started_at=0L,
    pids=[10],
  )
  assert_eq(store.live().length(), 1)
  assert_eq(store.live_count("/a"), 1)
  assert_eq(store.live_count("/b"), 0)
  store.finish(id, Completed, detail="exit code: 0", finished_at=5L)
  assert_eq(store.live().length(), 0)
  // The record survives so the reader can see how it ended.
  assert_eq(store.list().length(), 1)
  assert_eq(
    store.get(id).unwrap().list_line(),
    "bash-1 [bash] completed (exit code: 0) — npm run dev",
  )
}

///|
test "settlement is first-wins" {
  let store = JobStore::new()
  let id = store.start(kind="bash", label="x", session="/a", started_at=0L, pids=[])
  store.finish(id, Completed, detail="exit code: 0", finished_at=5L)
  // A kill that arrives after the process already exited must not rewrite history: an exit
  // code that can become "killed" is an exit code nobody can trust.
  store.finish(id, Killed, detail="SIGTERM", finished_at=6L)
  let job = store.get(id).unwrap()
  assert_eq(job.status, Completed)
  assert_eq(job.detail, "exit code: 0")
  assert_eq(job.finished_at, Some(5L))
}

///|
test "stopping is a state a reader can see" {
  let store = JobStore::new()
  let id = store.start(
    kind="bash",
    label="sleep 300",
    session="/a",
    started_at=0L,
    pids=[10, 11],
  )
  // The pids come back so the caller knows what to signal; the status says the request is out
  // but the work is not gone yet.
  assert_eq(store.request_stop(id), [10, 11])
  assert_eq(store.get(id).unwrap().status, Stopping)
  assert_true(store.get(id).unwrap().is_live())
  // Asking twice is harmless.
  assert_eq(store.request_stop(id), [10, 11])
  store.finish(id, Killed, detail="SIGTERM", finished_at=9L)
  assert_eq(store.request_stop(id), [])
}

///|
test "a job remembers every pid it was seen with" {
  let store = JobStore::new()
  let id = store.start(kind="bash", label="x", session="/a", started_at=0L, pids=[
    10,
  ])
  store.observe(id, [11, 12], tail="listening on 3000")
  // Repeats are not added twice: the list is what a kill walks.
  store.observe(id, [10, 11], tail="")
  let job = store.get(id).unwrap()
  assert_eq(job.pids, [10, 11, 12])
  assert_eq(job.tail, "listening on 3000")
}

///|
test "the list puts live jobs first and newest first" {
  let store = JobStore::new()
  let first = store.start(
    kind="bash",
    label="one",
    session="/a",
    started_at=0L,
    pids=[],
  )
  let second = store.start(
    kind="bash",
    label="two",
    session="/a",
    started_at=1L,
    pids=[],
  )
  store.finish(first, Completed, detail="exit code: 0", finished_at=2L)
  let order : Array[String] = []
  for job in store.list() {
    order.push(job.id)
  }
  assert_eq(order, [second, first])
}

///|
test "finished jobs are forgotten after a while, live ones never" {
  let store = JobStore::new()
  let done = store.start(
    kind="bash",
    label="done",
    session="/a",
    started_at=0L,
    pids=[],
  )
  let live = store.start(
    kind="bash",
    label="live",
    session="/a",
    started_at=0L,
    pids=[],
  )
  store.finish(done, Completed, detail="exit code: 0", finished_at=1000L)
  // Not yet: a job that just finished is news.
  assert_eq(store.forget_finished(older_than=5000L, now=2000L), 0)
  assert_eq(store.forget_finished(older_than=5000L, now=9000L), 1)
  assert_eq(store.list().length(), 1)
  assert_eq(store.list()[0].id, live)
}

///|
test "the age of a job is how long it ran, or has been running" {
  let store = JobStore::new()
  let id = store.start(kind="bash", label="x", session="/a", started_at=1000L, pids=[])
  assert_eq(store.get(id).unwrap().age_ms(4000L), 3000L)
  store.finish(id, Completed, detail="exit code: 0", finished_at=2500L)
  // Finished: the age stops growing, which is what "ran for 1.5s" means.
  assert_eq(store.get(id).unwrap().age_ms(9000L), 1500L)
}

///|
test "a record that was not background work can be dropped" {
  let store = JobStore::new()
  let id = store.start(kind="bash", label="ls", session="/a", started_at=0L, pids=[])
  assert_eq(store.list().length(), 1)
  store.forget(id)
  assert_eq(store.list().length(), 0)
  assert_true(store.get(id) is None)
}

///|
/// A job whose processes are gone settles, and how it settles depends on who ended it.
test "settling a job whose processes are gone distinguishes stopping from exiting" {
  let store = JobStore::new()
  let stopped = store.start(
    kind="bash",
    label="npm run dev",
    session="/a",
    started_at=0L,
    pids=[10, 11],
  )
  let left = store.start(
    kind="bash",
    label="sleep 30",
    session="/a",
    started_at=0L,
    pids=[12],
  )
  // The reader asked for one of them to stop; the other simply ended.
  ignore(store.request_stop(stopped))
  // While every job still has a live process, nothing settles.
  assert_false(store.settle_gone(pid => pid == 10 || pid == 12, now=5L))
  assert_true(store.get(stopped).unwrap().is_live())
  // One of the stopped job's processes is gone and the other is too, so it settles — while the
  // job whose process is alive is left alone.
  assert_true(store.settle_gone(pid => pid == 12, now=6L))
  assert_eq(store.get(stopped).unwrap().status, Killed)
  assert_true(store.get(left).unwrap().is_live())
  // Now nothing is alive.
  assert_true(store.settle_gone(_pid => false, now=7L))
  assert_eq(store.get(stopped).unwrap().status, Killed)
  assert_eq(store.get(stopped).unwrap().detail, "stopped")
  // A job that left on its own is not one the reader stopped.
  assert_eq(store.get(left).unwrap().status, Completed)
  assert_eq(store.get(left).unwrap().detail, "exited on its own")
  assert_eq(store.get(left).unwrap().finished_at, Some(7L))
  // Settling again changes nothing, so a caller can poll without churning the panel.
  assert_false(store.settle_gone(_pid => false, now=8L))
}

///|
/// A job with no recorded pids is not evidence that its work is gone.
///
/// The window is real: a command that backgrounds something is registered before its pids are
/// known, and settling it there would drop the record that the whole feature exists for.
test "a job with no pids yet is left alone" {
  let store = JobStore::new()
  let id = store.start(
    kind="bash",
    label="npm run dev &",
    session="/a",
    started_at=0L,
    pids=[],
  )
  assert_false(store.settle_gone(_pid => false, now=100L))
  assert_true(store.get(id).unwrap().is_live())
}
