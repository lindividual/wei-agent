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
  assert_eq(store.get(id).unwrap().status, Completed)
  assert_eq(store.get(id).unwrap().detail, "exit code: 0")
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
  // Both calls have returned, so what the store knows is everything there is to know.
  store.finish_call(stopped)
  store.finish_call(left)
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

// ── Persistence ────────────────────────────────────────────────────────────

///|
/// A store written and read back keeps every field that matters.
///
/// The point of the file is the pids: without them the next start knows a job existed but not what
/// to do about it, which is the difference between a record and a note.
test "a job store round-trips through JSON" {
  let store = JobStore::new()
  let live = store.start(
    kind="bash",
    label="npm run dev",
    session="/a/session.jsonl",
    started_at=1000L,
    pids=[41, 42],
  )
  let done = store.start(
    kind="bash",
    label="ls",
    session="/a/session.jsonl",
    started_at=2000L,
    pids=[43],
  )
  store.finish(done, Completed, detail="exit code: 0", finished_at=3000L)
  // A second live job, to check the counter is not simply reset by what was read.
  let next = store.start(
    kind="bash",
    label="sleep 100",
    session="/a/session.jsonl",
    started_at=4000L,
    pids=[44],
  )
  let restored = parse_job_store(store.to_json().stringify())
  assert_eq(restored.jobs.length(), 3)
  let back = restored.get(live).unwrap()
  assert_eq(back.label, "npm run dev")
  assert_eq(back.session, "/a/session.jsonl")
  assert_eq(back.pids, [41, 42])
  assert_true(back.is_live())
  let settled = restored.get(done).unwrap()
  assert_eq(settled.status, Completed)
  assert_eq(settled.detail, "exit code: 0")
  assert_eq(settled.finished_at, Some(3000L))
  // Ids continue past what was read rather than restarting at bash-1, which would let a new job
  // share an id with one still running from the previous run.
  let fresh = restored.start(
    kind="bash",
    label="next",
    session="/a",
    started_at=5000L,
    pids=[],
  )
  assert_false(fresh == live)
  assert_false(fresh == next)
}

///|
/// A file that cannot be read is an empty store, not a failure to start.
test "a corrupt store reads as empty" {
  assert_eq(parse_job_store("").jobs.length(), 0)
  assert_eq(parse_job_store("not json at all").jobs.length(), 0)
  assert_eq(parse_job_store("{\"jobs\":\"nope\"}").jobs.length(), 0)
  // A truncated write: the record is unusable and is dropped, which is the reason the format is
  // read tolerantly rather than trusted.
  assert_eq(parse_job_store("{\"jobs\":[{\"id\":\"bash-1\"").jobs.length(), 0)
}

///|
/// Starting again after a crash: what is still there stays live, what is not is reported lost.
///
/// This is the whole reason the records are written down. A job whose process survived is one the
/// reader can still find and kill; a job whose process is gone is one nobody witnessed the end of,
/// and saying so is better than leaving it on the panel claiming to run forever.
test "reconcile keeps the survivors and marks the rest lost" {
  let store = JobStore::new()
  let surviving = store.start(
    kind="bash",
    label="npm run dev",
    session="/a",
    started_at=0L,
    pids=[41, 42],
  )
  let orphaned = store.start(
    kind="bash",
    label="sleep 100",
    session="/a",
    started_at=0L,
    pids=[43],
  )
  let finished = store.start(
    kind="bash",
    label="ls",
    session="/a",
    started_at=0L,
    pids=[44],
  )
  store.finish(finished, Completed, detail="exit code: 0", finished_at=1L)
  // Only pid 42 is still there — the command's shell exited and its child is what survived, which
  // is exactly the case several pids are recorded for.
  let lost = store.reconcile(pid => pid == 42, 99L)
  assert_eq(lost, 1)
  assert_true(store.get(surviving).unwrap().is_live())
  assert_eq(store.get(surviving).unwrap().pids, [41, 42])
  // The one with nothing behind it says what happened rather than pretending.
  let gone = store.get(orphaned).unwrap()
  assert_eq(gone.status, Failed)
  assert_true(gone.detail.contains("lost"), msg=gone.detail)
  // A job that had already settled is not touched: it was not running, so there is nothing to
  // reconcile, and its recorded exit code must survive.
  let untouched = store.get(finished).unwrap()
  assert_eq(untouched.status, Completed)
  assert_eq(untouched.detail, "exit code: 0")
}

///|
/// A real epoch-millisecond timestamp survives the round trip.
///
/// This is the regression test for a bug that the round-trip test above could not see: it used
/// timestamps of a few thousand, which fit in an `Int`. A real `startedAt` is around 1.79e12, and
/// this platform's `Int` is 32-bit, so reading it through `Int` saturated it to `2147483647` — a job
/// that had been running for a minute came back claiming to have started in 1970, and the panel
/// printed an age of 496,426 hours. Times have to be read as `Int64`.
test "an epoch-millisecond timestamp round-trips exactly" {
  let started = 1789283993636L
  let finished = 1789284993636L
  let store = JobStore::new()
  let id = store.start(
    kind="bash",
    label="npm run dev",
    session="/a",
    started_at=started,
    pids=[41],
  )
  store.finish(id, Completed, detail="exit code: 0", finished_at=finished)
  let restored = parse_job_store(store.to_json().stringify())
  let job = restored.get(id).unwrap()
  assert_eq(job.started_at, started)
  assert_eq(job.finished_at, Some(finished))
  // The consequence, stated as the reader sees it: the age is a minute, not half a million hours.
  assert_eq(job.age_ms(finished), 1000000L)
  assert_eq(duration_label_of(job.age_ms(finished)), "16m 40s")
}

///|
/// The age of a still-running job is measured from now, and of a settled one from its end.
test "age is measured against now while running" {
  let store = JobStore::new()
  let id = store.start(
    kind="bash",
    label="sleep 100",
    session="/a",
    started_at=1789283993636L,
    pids=[41],
  )
  // A minute later.
  assert_eq(store.get(id).unwrap().age_ms(1789284053636L), 60000L)
}

///|
fn duration_label_of(ms : Int64) -> String {
  let seconds = ms / 1000L
  if seconds < 60L {
    "\{seconds}s"
  } else if seconds < 3600L {
    "\{seconds / 60L}m \{seconds % 60L}s"
  } else {
    "\{seconds / 3600L}h \{(seconds % 3600L) / 60L}m"
  }
}

///|
/// A job whose owning call is still in flight is not settled, however dead its shell looks.
///
/// The window this covers is milliseconds wide and was found the hard way: the shell of a
/// backgrounded command exits the moment the command does, the call that started it is still
/// reading the process table, and what is known at that instant is the shell's pid alone. Settling
/// there recorded "exited on its own" about a command whose child was running — and the record that
/// the panel and `wait` both read was gone.
test "a job whose call is still in flight is left alone" {
  let store = JobStore::new()
  let id = store.start(
    kind="exec",
    label="sleep 30 &",
    session="/a",
    started_at=0L,
    pids=[],
  )
  // The shell is seen, and has already exited.
  store.observe(id, [41], tail="")
  assert_false(store.settle_gone(_pid => false, now=10L))
  assert_true(store.get(id).unwrap().is_live())
  // The call reports what the command left: only now is the list complete, and only now can a
  // settled verdict mean anything.
  store.finish_call(id)
  store.observe(id, [42], tail="")
  assert_false(store.settle_gone(pid => pid == 42, now=11L))
  assert_true(store.get(id).unwrap().is_live())
  // The child goes, and the job settles.
  assert_true(store.settle_gone(_pid => false, now=12L))
  assert_eq(store.get(id).unwrap().status, Completed)
}

///|
/// A record read back from disk has no call in flight, so it is settled by the process table alone.
///
/// The opposite direction of the test above, and the reason the flag is not persisted: after a
/// restart there is no call left to wait for, and a job whose processes are gone must not be stuck
/// claiming to run forever.
test "a job read back from disk settles on the process table" {
  let store = JobStore::new()
  let id = store.start(
    kind="exec",
    label="npm run dev",
    session="/a",
    started_at=0L,
    pids=[77, 78],
  )
  store.finish_call(id)
  let reloaded = parse_job_store(store.to_json().stringify())
  assert_true(reloaded.get(id).unwrap().is_live())
  assert_true(reloaded.settle_gone(_pid => false, now=5L))
  assert_eq(reloaded.get(id).unwrap().status, Completed)
}
