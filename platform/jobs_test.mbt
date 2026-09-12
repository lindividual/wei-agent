///|
/// Background commands against a real process table.
///
/// These spawn actual processes, so they are the only way to know that the parts fit: the shell's
/// own dump, the subtree walk, liveness, and the kill that has to reach a process whose parent is
/// long gone.

///|
/// A pid that is gone by the time it is checked.
async fn dead_pid() -> Int {
  let (_, out, _) = @process.collect_output("/bin/sh", ["-c", "echo $$"])
  let pid = parse_table("\{out.text().trim()} 1")[0].0
  // The shell has exited; give the kernel a moment to reap it.
  @async.sleep(100)
  pid
}

///|
test "a subtree is every descendant, not just the children" {
  //   1 ── 2 ── 4
  //     └─ 3
  let table : Array[(Int, Int)] = [(1, 0), (2, 1), (3, 1), (4, 2), (5, 99)]
  assert_eq(subtree(table, 1), [2, 3, 4])
  assert_eq(subtree(table, 2), [4])
  assert_eq(subtree(table, 99), [5])
  // A cycle must not spin: the walk is bounded by what it has already seen.
  assert_eq(subtree([(2, 3), (3, 2)], 2), [3])
}

///|
test "a process table line is two numbers, and anything else is skipped" {
  // A line that is not two numbers is skipped rather than guessed at: `ps` always prints both
  // columns, so a single number means the output was not what we think it is.
  let parsed = parse_table("  100   1\n  200 100\n\nnot a process\n  300   \n")
  assert_eq(parsed, [(100, 1), (200, 100)])
}

///|
/// The case the whole mechanism exists for: a command that returns immediately and leaves a
/// process behind.
async test "a backgrounded command is reported as lingering" {
  let outcome = exec_managed(
    // `sleep 60 &` returns at once; the sleep is still there afterwards.
    "/bin/sleep 60 & echo started",
    cwd=".",
    timeout_ms=5000,
  )
  assert_false(outcome.result.timed_out)
  assert_eq(outcome.result.stdout.trim(), "started")
  assert_true(
    outcome.lingering.length() >= 1,
    msg="lingering=\{outcome.lingering.length()}, children=\{outcome.children.length()}",
  )
  // And it is really running: that is the thing a reader would otherwise have to remember.
  for pid in outcome.lingering {
    assert_true(pid_alive(pid), msg="pid \{pid} should be alive")
  }
  let killed = kill_pids(outcome.lingering)
  assert_true(killed >= 1, msg="expected to kill at least one process")
  for pid in outcome.lingering {
    assert_false(pid_alive(pid), msg="pid \{pid} should be gone")
  }
}

///|
/// A command that finishes cleanly leaves nothing behind, so it must not be reported as
/// background work.
async test "a foreground command leaves nothing lingering" {
  let outcome = exec_managed("/bin/echo hi", cwd=".", timeout_ms=5000)
  assert_eq(outcome.result.exit_code, 0)
  assert_eq(outcome.result.stdout.trim(), "hi")
  assert_true(
    outcome.lingering.is_empty(),
    msg="lingering=\{outcome.lingering.length()}",
  )
}

///|
/// The command's own exit status has to survive the extra bookkeeping the wrapper adds.
async test "the exit code is the command's, not the wrapper's" {
  let outcome = exec_managed("/bin/sh -c 'exit 7'", cwd=".", timeout_ms=5000)
  assert_eq(outcome.result.exit_code, 7)
  let missing = exec_managed(
    "/definitely/not/a/command",
    cwd=".",
    timeout_ms=5000,
  )
  assert_true(missing.result.exit_code != 0, msg="\{missing.result.exit_code}")
}

///|
/// A timeout is reported as one, and the shell is not left behind.
async test "a timed out command is stopped" {
  let outcome = exec_managed("/bin/sleep 30", cwd=".", timeout_ms=600)
  assert_true(outcome.result.timed_out)
  assert_false(pid_alive(outcome.shell_pid), msg="the shell should be gone")
}

///|
/// Killing is patient before it is forceful, and harmless when the process is already gone.
async test "killing a dead pid does nothing" {
  let pid = dead_pid()
  assert_false(pid_alive(pid))
  assert_eq(kill_pids([pid]), 0)
  assert_eq(kill_pids([0, -1]), 0)
}
