///|
/// Code mode against a real process table.
///
/// The pair is only real if the two halves fit: `exec` has to return while the command it started
/// keeps writing, and `wait` has to find that output. Nothing but an actual backgrounded process
/// can tell whether it does — the mechanism is a file descriptor the shell hands to a child, and
/// the file is the only thing that outlives the call.

///|
async test "wait on an id that was never issued lists the live ones" {
  let jobs = @core.JobStore::new()
  ignore(
    jobs.start(kind="exec", label="npm run dev", session="s", started_at=0L, pids=[]),
  )
  let out = execute_tool("wait", @json.parse("{\"id\":\"exec-7\"}"), ".", jobs~)
  let text = output_text(out)
  assert_true(text.contains("No job \"exec-7\""), msg=text)
  assert_true(text.contains("Running: exec-1."), msg=text)
  // A caller with no store at all — which is what a tool layer with no session looks like — gets the
  // empty answer rather than an exception: there are no jobs because there is nowhere to keep them.
  let bare = execute_tool("wait", @json.parse("{\"id\":\"exec-1\"}"), ".")
  assert_true(bare.is_error)
  assert_true(
    output_text(bare).contains("No job is running"),
    msg=output_text(bare),
  )
}

///|
async test "exec refuses a call with both dialects, and one with neither" {
  let both = execute_tool(
    "exec",
    @json.parse("{\"bash\":\"ls\",\"moonbit\":\"async fn main {}\"}"),
    ".",
  )
  assert_true(both.is_error)
  assert_true(output_text(both).contains("not both"))
  let neither = execute_tool("exec", @json.parse("{}"), ".")
  assert_true(neither.is_error)
  assert_true(output_text(neither).contains("Nothing to run"))
}

///|
/// A command that returns before its work does, and a wait that collects the rest.
async test "exec hands a lingering command to wait" {
  let dir = scratch("code-mode-wait")
  let jobs = @core.JobStore::new()
  let id = jobs.start(
    kind="exec",
    label="sh -c 'sleep 0.5; echo late' &",
    session="s",
    started_at=0L,
    pids=[],
  )
  // The same wiring the driver does, spelled out so the test is about the mechanism rather than
  // about a turn: pids as they are found, and the outcome when the call returns.
  let started = execute_tool(
    "exec",
    @json.parse("{\"bash\":\"sh -c 'sleep 0.5; echo late' &\"}"),
    dir,
    jobs~,
    watcher={
      id: Some(id),
      started: pids => jobs.observe(id, pids, tail=""),
      finished: outcome => note_execution(jobs, id, outcome),
    },
  )
  assert_false(started.is_error)
  let head = output_text(started)
  // The model is told, in the result, that something is still running and how to collect it — that
  // is the only way it can know to call `wait` at all. How many processes there are is not asserted:
  // a backgrounded `sh -c` is a subshell plus what it runs, and which of the two the tree walk sees
  // is a race — the assertion is that the command's own processes came back and the id is named.
  assert_true(head.contains("process(es) running"), msg=head)
  // The id is named, not hinted at: a model told only "the job id" goes looking for one.
  assert_true(head.contains("`wait \"exec-1\"`"), msg=head)
  // And the record is live, with somewhere to read from: the point of the whole arrangement.
  let job = match jobs.get(id) {
    Some(job) => job
    None => fail("the job should have been kept")
  }
  assert_true(job.is_live(), msg="the job should still be running")
  assert_true(
    job.output is Some(_),
    msg="the output files should have been kept",
  )

  // The wait returns when the process goes, with what it printed after the call that started it.
  let waited = execute_tool(
    "wait",
    @json.parse("{\"id\":\"exec-1\"}"),
    dir,
    jobs~,
  )
  assert_false(waited.is_error)
  let body = output_text(waited)
  assert_true(body.contains("exec-1 finished"), msg=body)
  assert_true(body.contains("late"), msg=body)
  assert_true(
    job.status is @core.JobStatus::Completed,
    msg="the job should have completed",
  )
  // Read once, and only once: a second wait has nothing new to hand back.
  let again = execute_tool(
    "wait",
    @json.parse("{\"id\":\"exec-1\"}"),
    dir,
    jobs~,
  )
  assert_true(
    output_text(again).contains("(no output)"),
    msg=output_text(again),
  )
}

///|
/// The bound, from both sides: a wait with no time left says what is true, and a wait that is asked
/// not to wait does not wait.
async test "a wait on something that never exits returns rather than holding the call" {
  let dir = scratch("code-mode-pending")
  let jobs = @core.JobStore::new()
  let id = jobs.start(
    kind="exec",
    label="sleep 30 &",
    session="s",
    started_at=0L,
    pids=[],
  )
  let started = execute_tool(
    "exec",
    @json.parse("{\"bash\":\"/bin/sleep 30 &\"}"),
    dir,
    jobs~,
    watcher={
      id: Some(id),
      started: pids => jobs.observe(id, pids, tail=""),
      finished: outcome => note_execution(jobs, id, outcome),
    },
  )
  assert_false(started.is_error)
  let pending = execute_tool(
    "wait",
    @json.parse("{\"id\":\"exec-1\",\"timeout\":0}"),
    dir,
    jobs~,
  )
  // An error, because "there is nothing yet" is the one answer a caller has to act on rather than
  // read past — and the text says what to do about it.
  assert_true(pending.is_error)
  let text = output_text(pending)
  assert_true(text.contains("is still running after 0ms"), msg=text)
  assert_true(text.contains("Call wait again"), msg=text)
  // The sleep is really there, which is why the call returned: it is stopped here so the test does
  // not leave a process behind.
  let job = match jobs.get(id) {
    Some(job) => job
    None => fail("the job should have been kept")
  }
  assert_true(kill_pids(job.pids) >= 1)
}

///|
/// The `moonbit` dialect reaches the same runner the `script` tool does.
///
/// Run with a name that does not exist rather than a real program: the compilation is slow and is
/// covered by `script_run_test.mbt`, and what is being checked here is the plumbing — that a
/// `@builtin/` name is looked up under the name, and that anything else is handed over as source.
async test "exec runs a program through the same runner as script" {
  let unknown = execute_tool(
    "exec",
    @json.parse("{\"moonbit\":\"@builtin/nope\"}"),
    ".",
  )
  assert_true(unknown.is_error)
  // An unknown `@builtin/` name is a name, not a program to compile: the answer is the list of the
  // ones that exist, rather than a syntax error about the text.
  assert_true(
    output_text(unknown).contains("Unknown script"),
    msg=output_text(unknown),
  )
  assert_true(
    output_text(unknown).contains("@builtin/check"),
    msg=output_text(unknown),
  )
}

///|
/// The empty command is refused before anything is spawned, under either name for it.
async test "a blank command is refused rather than run" {
  let blank = execute_tool("bash", @json.parse("{\"command\":\"  \\n\"}"), ".")
  assert_true(blank.is_error)
  assert_true(output_text(blank).contains("The command is empty"))
  let via_exec = execute_tool("exec", @json.parse("{\"bash\":\" \\t \"}"), ".")
  // Read as a call with nothing in it, which is the other refusal — either way nothing runs.
  assert_true(via_exec.is_error)
  assert_true(output_text(via_exec).contains("Nothing to run"))
}

///|
/// A job whose output was not kept — one read back from a previous run — says so rather than
/// reading whatever now happens to be at that path.
///
/// This is the restart case: the record survives because the process may still be alive, and the
/// files do not, because they belong to the run that made them.
async test "a job without kept output says so rather than reading a stale file" {
  let jobs = @core.JobStore::new()
  let id = jobs.start(
    kind="exec",
    label="npm run dev &",
    session="s",
    started_at=0L,
    pids=[],
  )
  // Ended, and no output attached: exactly what a record read from the job store looks like.
  jobs.finish(id, @core.JobStatus::Completed, detail="lost", finished_at=1L)
  let out = execute_tool("wait", @json.parse("{\"id\":\"exec-1\"}"), ".", jobs~)
  assert_true(out.is_error)
  let text = output_text(out)
  assert_true(text.contains("its output was not kept"), msg=text)
  assert_true(text.contains("earlier run of the server"), msg=text)
}

///|
/// The pruner leaves a live job's output alone and removes an old one.
///
/// Bounded by age rather than cleared, because the directory is the machine's and a second server
/// starting up must not delete the first one's live job output. The two cases are told apart by when
/// the file was last written, so that is what this checks.
async test "old job output is pruned, recent output is kept" {
  let dir = tree_dir()
  @platform.make_dirs(dir)
  let fresh = "\{dir}/job-\{@core.new_entry_id()}.out"
  let stale = "\{dir}/job-\{@core.new_entry_id()}.out"
  @platform.write_text(fresh, "still being waited on")
  @platform.write_text(stale, "from a run that is over")
  // The only way to make a file old without waiting a day. `mtime` is read back from the file
  // system, so the check is about the ages the pruner sees, not about a mock.
  ignore(
    @process.collect_output("/usr/bin/touch", ["-t", "202001010000", stale]),
  )
  let now = @env.now().reinterpret_as_int64()
  @platform.clear_job_outputs(now)
  assert_true(
    @platform.path_exists(fresh),
    msg="a recent output file was deleted",
  )
  assert_false(@platform.path_exists(stale), msg="an old output file was kept")
  try @fs.remove(fresh) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// The race the `call_open` flag exists for, end to end.
///
/// A backgrounded command's shell exits within milliseconds while the tool call that started it is
/// still reading the process table. Let the supervisor's own settle loop run at that moment and the
/// job is recorded as "exited on its own" — the record gone, and with it the only handle on the
/// process that is actually running. This is the shape that failed on the first of three attempts
/// before the flag existed, so the check is that a tick landing *during* the call does nothing.
///
/// The predicate is the strongest verdict a tick could reach — "nothing in the table is alive" — and
/// it is computed from the store rather than from `ps` so that the check is about the settle rule and
/// not about how fast a process table can be read. If the rule is immune to the strictest input, it
/// is immune to the real one.
async test "a supervisor tick during the call does not settle a backgrounded command" {
  let dir = scratch("code-mode-race")
  let jobs = @core.JobStore::new()
  let id = jobs.start(
    kind="exec",
    label="sh -c 'sleep 1; echo RACE-OK' &",
    session="s",
    started_at=0L,
    pids=[],
  )
  let started = execute_tool(
    "exec",
    @json.parse("{\"bash\":\"sh -c 'sleep 1; echo RACE-OK' &\"}"),
    dir,
    jobs~,
    watcher={
      id: Some(id),
      started: pids => {
        jobs.observe(id, pids, tail="")
        // Between the pids being found and the command returning: the window.
        ignore(
          jobs.settle_gone(_pid => false, now=@env.now().reinterpret_as_int64()),
        )
      },
      finished: outcome => note_execution(jobs, id, outcome),
    },
  )
  assert_false(started.is_error)
  let job = match jobs.get(id) {
    Some(job) => job
    None => fail("the job record should have been kept")
  }
  assert_true(job.is_live(), msg="a tick during the call settled it early")
  // And it is still collectable, which is what the record is for.
  let waited = execute_tool(
    "wait",
    @json.parse("{\"id\":\"exec-1\"}"),
    dir,
    jobs~,
  )
  assert_true(output_text(waited).contains("RACE-OK"), msg=output_text(waited))
}

///|
/// A job that printed more than one call can hand back is delivered in pieces.
///
/// The shape this exists for is a backgrounded server writing a log. Without the read position
/// advancing by what was actually handed over, the second wait would return the same first 32KB
/// forever; without the ceiling, one wait would put the whole log into the conversation.
///
/// The command sleeps before printing, and that is the point rather than padding. Output written
/// before the call returns is already in that call's own result — the shell's file is read at the
/// end of it — so what `wait` has to deliver is the output that arrives afterwards. The sleeping
/// shape is also the real one: something that is started, and then starts talking.
async test "output larger than one digest comes back in pieces, each line once" {
  let dir = scratch("code-mode-chunks")
  let jobs = @core.JobStore::new()
  let started_at = @env.now().reinterpret_as_int64()
  let id = jobs.start(
    kind="exec",
    label="seq 1 12000 &",
    session="s",
    started_at~,
    pids=[],
  )
  // 12,000 lines of decimal numbers is about 70KB: more than the 32KB one call can hand back, and
  // less than the file system will hold on to without noticing.
  let started = execute_tool(
    "exec",
    @json.parse("{\"bash\":\"sh -c 'sleep 0.3; seq 1 12000' &\"}"),
    dir,
    jobs~,
    watcher={
      id: Some(id),
      started: pids => jobs.observe(id, pids, tail=""),
      finished: outcome => note_execution(jobs, id, outcome),
    },
  )
  assert_false(started.is_error)
  let first = execute_tool(
    "wait",
    @json.parse("{\"id\":\"exec-1\"}"),
    dir,
    jobs~,
  )
  let head = output_text(first)
  assert_true(head.contains("call wait again"), msg=head)
  // The chunk starts at the beginning of the output and ends on a line, so the second read resumes
  // where this one stopped rather than inside a number.
  assert_true(head.contains("1\n"), msg=head)
  let second = execute_tool(
    "wait",
    @json.parse("{\"id\":\"exec-1\"}"),
    dir,
    jobs~,
  )
  let tail = output_text(second)
  assert_true(tail.contains("12000"), msg=tail)
  assert_false(tail.contains("call wait again"), msg=tail)
  // Neither chunk repeats the other: the first line is in the first chunk and not in the second.
  assert_false(tail.contains("\n1\n"), msg=tail)
}
