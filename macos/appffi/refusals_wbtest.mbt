///|
/// The refusal sentences
///
/// Twenty-odd sentences in this package tell a reader why a command did not happen. They are the
/// whole of what a failed command gives back — no error code, no state to inspect, just a line of
/// prose — and for a long time almost none of them had a test. This project has fixed that failure
/// mode once before, elsewhere; it had quietly grown back here.
///
/// They are pure once the facts are handed in, which is the only reason they can be checked at all.

///|
/// Every way a deletion can be refused, and the sentence for each.
///
/// One literal per sentence, deliberately unparameterised: what is being pinned is the *wording*, and
/// a test that built the string from the same constant the code uses would pass while the sentence a
/// reader sees drifted.
test "a deletion is refused in words, one sentence per reason" {
  let ok : Deletion = {
    path: "/store/s.jsonl",
    busy: false,
    live_jobs: 0,
    exists: true,
  }
  assert_eq(refuse_deletion(ok), None)

  let no_path : Deletion = { ..ok, path: "", }
  assert_eq(refuse_deletion(no_path), Some("delete: no session path"))

  let running : Deletion = { ..ok, busy: true, }
  assert_eq(
    refuse_deletion(running),
    Some("cannot delete a session with a turn running — stop it first"),
  )

  let working : Deletion = { ..ok, live_jobs: 1, }
  assert_eq(
    refuse_deletion(working),
    Some("cannot delete a session with a background job still running"),
  )

  let gone : Deletion = { ..ok, exists: false, }
  assert_eq(refuse_deletion(gone), Some("that session is already gone"))
}

///|
/// The order of the four checks is load-bearing, and the case that shows it is a job whose file is
/// gone.
///
/// `npm run dev &` outlives the session that started it. If `exists` were asked first, that session
/// would be refused as "already gone" — a true sentence that sends the reader looking for a file,
/// while the process it should have been told about keeps running with no row on screen pointing at
/// it. `live_jobs` therefore comes first, and this is the only input that can tell the two orders
/// apart.
test "a job that outlived its file is refused for the job, not for the file" {
  let orphan : Deletion = {
    path: "/store/s.jsonl",
    busy: false,
    live_jobs: 2,
    exists: false,
  }
  assert_eq(
    refuse_deletion(orphan),
    Some("cannot delete a session with a background job still running"),
  )
  // And a turn beats a job, for the same shape of reason: stopping the turn is what the reader has to
  // do first, and the job is reachable afterwards.
  let both : Deletion = { ..orphan, busy: true, }
  assert_eq(
    refuse_deletion(both),
    Some("cannot delete a session with a turn running — stop it first"),
  )
  // Nothing named at all beats everything: there is nothing to have a turn or a job.
  let nothing : Deletion = { ..both, path: "", }
  assert_eq(refuse_deletion(nothing), Some("delete: no session path"))
}

///|
/// **No silent refusal.** Every combination of the four facts either allows the deletion or explains
/// itself — there is no input for which the command would do nothing and say nothing, which is the
/// failure a reader experiences as "the button is broken".
test "every refusal names a reason, and every allow is silent" {
  for path in ["", "/store/one.jsonl"] {
    for busy in [false, true] {
      for live_jobs in [0, 1] {
        for exists in [false, true] {
          let d : Deletion = { path, busy, live_jobs, exists, }
          match refuse_deletion(d) {
            Some(reason) =>
              assert_true(reason.length() > 0, msg="a refusal with no words")
            None =>
              // Allowed means all four facts were fine — and the empty path is the one that never is.
              assert_true(path != "" && !busy && live_jobs == 0 && exists)
          }
        }
      }
    }
  }
}

///|
/// Removing a project is refused in words, the same way a deletion is.
///
/// The two sentences here are the ones a reader sees when a project-row delete does not go through, and
/// like `refuse_deletion`'s four they lived inside a method that answered the question and wrote the
/// sentence in the same call — so neither could be asserted.
test "a project removal is refused in words, turn before job" {
  let idle : Array[ProjectLoad] = [{ busy: false, live_jobs: 0, }]
  assert_eq(refuse_project_removal("/tmp", idle), None)
  // A project nobody has open at all is also removable: the loads list is empty, not "unknown".
  assert_eq(refuse_project_removal("/tmp", []), None)

  assert_eq(refuse_project_removal("", idle), Some("remove: no project path"))
  assert_eq(
    refuse_project_removal("/tmp", [{ busy: true, live_jobs: 0, }]),
    Some("a turn is running in this project — stop it first"),
  )
  assert_eq(
    refuse_project_removal("/tmp", [{ busy: false, live_jobs: 3, }]),
    Some("a background job is still running in this project"),
  )
  // **A turn is asked for before a job**, and the input that tells the two apart is a session with
  // both: stopping the turn is what the reader does next, and the job is reachable afterwards.
  assert_eq(
    refuse_project_removal("/tmp", [{ busy: true, live_jobs: 3, }]),
    Some("a turn is running in this project — stop it first"),
  )
  // One busy session anywhere in the project is enough — the row stands for all of them.
  assert_eq(
    refuse_project_removal("/tmp", [
      { busy: false, live_jobs: 0, },
      { busy: true, live_jobs: 0, },
      { busy: false, live_jobs: 0, },
    ]),
    Some("a turn is running in this project — stop it first"),
  )
  // And a job in any of them, likewise.
  assert_eq(
    refuse_project_removal("/tmp", [
      { busy: false, live_jobs: 0, },
      { busy: false, live_jobs: 1, },
    ]),
    Some("a background job is still running in this project"),
  )
}

///|
/// The same no-silent-refusal property as a deletion: every combination either allows it or explains.
test "every project refusal names a reason" {
  let named = ["", "/tmp"]
  let loads : Array[Array[ProjectLoad]] = [
    [],
    [{ busy: false, live_jobs: 0, }],
    [{ busy: true, live_jobs: 0, }],
    [{ busy: false, live_jobs: 2, }],
    [{ busy: true, live_jobs: 2, }],
  ]
  for path in named {
    for load in loads {
      match refuse_project_removal(path, load) {
        Some(reason) =>
          assert_true(reason.length() > 0, msg="a refusal with no words")
        None =>
          assert_true(
            path != "" && load.all(fn(l) { !l.busy && l.live_jobs == 0 }),
            msg="allowed with a turn or a job in it",
          )
      }
    }
  }
}
