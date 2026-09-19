///|
/// One line in, what came out
///
/// `Shell::handle` is the body of the command loop, so these cross the same seam a *keystroke* does.
/// `app_wbtest.mbt` asserts on events built from values; these assert on what a command **decided**,
/// which is where the thirty-six arms and their guards live.
///
/// What is deliberately not here: `Prompt`. That arm spawns a real turn, and `with_task_group` waits
/// for everything it spawned — so testing it in-process would mean making a request to a provider. Its
/// decision (which of the two things a prompt is) is covered where it lives, by `command_of` and
/// `turn_refusal`.

///|
/// Send one command line through the loop, and read back everything the shell said.
///
/// The task group is real because the arm genuinely takes one — a command loop that could not answer
/// `abort` while a turn ran is the bug the spawned turns exist to avoid. Nothing is waited on.
async fn command(shell : Shell, line : String) -> Unit {
  ignore(@async.with_task_group(group => ignore(shell.handle(group, line))))
}

///|
/// `abort` does three things, and the second is the one that was measured.
///
/// The flag is read *between steps* and the step in progress is the tool — so with the flag alone, a
/// reader who pressed Stop during a two-minute test suite watched it run to the end while the status
/// line said "stopping…". `stop_running_tool` is what reaches the child process, and the sentence is
/// what tells the reader that the click landed.
async test "abort sets this session's flag, stops its command, and says so" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  let stopped : Ref[Int] = { val: 0, }
  open.running_tool = Some({
    name: "bash",
    detail: "sleep 60",
    arguments: Json::string("sleep 60"),
    stop: () => stopped.val = stopped.val + 1,
  })
  command(shell, "abort")
  assert_true(open.aborting.val)
  assert_eq(stopped.val, 1)
  // And exactly one sentence: the reader is told the click landed, once.
  let lines = seen()
  inspect(lines.length(), content="1")
  inspect(
    lines[0].stringify(),
    content="{\"kind\":\"status\",\"session\":\"/tmp/s.jsonl\",\"text\":\"stopping…\"}",
  )
}

///|
/// `quit` is the only thing a command can say to the loop, and it stops **every** session.
///
/// Not just the one on screen: this is the process shutting down, and a turn left running in a
/// conversation nobody was looking at would keep the runtime's event loop alive after the window
/// closed. The loop's own `quit` flag is what the returned `Keep` becomes — this asserts the decision,
/// and `serve` is left with one line of consequence.
async test "quit is the answer to the loop, and it stops every session" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  let mut keep = Going
  ignore(@async.with_task_group(group => keep = shell.handle(group, "quit")))
  assert_eq(keep, Quit)
  assert_true(open.aborting.val)
  // Nothing said: quitting is not a fact about a conversation.
  inspect(seen().length(), content="0")
}

///|
/// A model this build does not know is **refused**, and the refusal names what there was to pick.
///
/// The reason it is a branch at all is priced: an unknown id has no pricing and no context window, so
/// accepting one would bill the turn at the default's rates and silently send the wrong prompt. The
/// check is `is_known_model`'s, at the arm — which is exactly the kind of guard that lived only inside
/// a running loop.
async test "an unknown model is refused, and the sentence lists what is available" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  command(shell, "/model deepseek-v9")
  let lines = seen()
  inspect(lines.length(), content="1")
  match lines[0] {
    Object(fields) =>
      match fields.get("text") {
        Some(text) =>
          assert_true(
            text.stringify().contains("unknown model deepseek-v9"),
            msg="the refusal did not name the model that was asked for",
          )
        None => fail("the refusal carries no text")
      }
    _ => fail("the refusal is not an object")
  }
  // The session is left alone: a refused switch must not half-happen.
  inspect(open.model_id, content="deepseek-v4-flash")
}

///|
/// A model this build knows is switched, and **four** facts follow it.
///
/// The count is the rule, not padding. Each of the four is a control the host has already drawn from
/// the old model: the status line names it, the picker ticks it, the composer's picture warning was
/// judged against it, and the thinking menu lists *its* levels — so a tick left from the old model is
/// a level the new one does not have. Sending three of the four is how the window comes to describe a
/// model the session is not on.
async test "switching to a known model says four things, and the last is the level" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  command(shell, "/model deepseek-v4-pro")
  let lines = seen()
  inspect(lines.length(), content="4")
  let kinds : Array[String] = []
  for line in lines {
    match line {
      Object(fields) =>
        match fields.get("kind") {
          Some(String(kind)) => kinds.push(kind)
          _ => fail("an event with no kind")
        }
      _ => fail("an event that is not an object")
    }
  }
  assert_eq(kinds, ["status", "models", "images", "think"])
  // The session moved, and its level was settled against the new model in the same step.
  inspect(open.model_id, content="deepseek-v4-pro")
  inspect(open.think_level, content="high")
}

///|
/// `/think` with a level this model has not got answers **twice**, and the first one says no.
///
/// The refusal and the menu are two events because they are two facts: what was asked for is not
/// happening, and here is the level that is. The second is what keeps the tick from being left on the
/// level the reader typed.
async test "an unknown level is refused in words, then the menu is re-said" {
  let (shell, seen) = test_shell()
  command(shell, "/think bogus")
  let lines = seen()
  inspect(lines.length(), content="2")
  match lines[0] {
    Object(fields) =>
      match fields.get("text") {
        Some(text) =>
          assert_true(
            text.stringify().contains("has no bogus level"),
            msg="the refusal did not name the level that was asked for",
          )
        None => fail("the refusal carries no text")
      }
    _ => fail("the refusal is not an object")
  }
  match lines[1] {
    Object(fields) =>
      match fields.get("kind") {
        Some(String(kind)) => inspect(kind, content="think")
        _ => fail("the menu has no kind")
      }
    _ => fail("the menu is not an object")
  }
}

///|
/// Continuing a turn that is not open is **said**, not silently ignored.
///
/// The host offers this from a notice built on its own copy of the session, which can be out of date —
/// and an error that leaves what it is about on the screen reads as a click that did nothing. So the
/// sentence goes out with the refreshed snapshot: the stale notice cannot outlive the click.
async test "continuing nothing says so, and re-sends the snapshot with it" {
  let (shell, seen) = test_shell()
  command(shell, "continue")
  let lines = seen()
  inspect(lines.length(), content="2")
  match lines[0] {
    Object(fields) =>
      match fields.get("text") {
        Some(text) =>
          inspect(
            text.stringify(),
            content="\"nothing to continue: that turn has already ended\"",
          )
        None => fail("the error carries no text")
      }
    _ => fail("the error is not an object")
  }
  match lines[1] {
    Object(fields) =>
      match fields.get("kind") {
        Some(String(kind)) => inspect(kind, content="session")
        _ => fail("the snapshot has no kind")
      }
    _ => fail("the snapshot is not an object")
  }
}

///|
/// A busy session refuses `continue`, and refuses it **before** anything else happens.
///
/// This is the `handle` half of the `gate` test: the gate's *value* is asserted next to `gate`, and
/// what is asserted here is that the loop obeys it — a refused command leaves no trace but the
/// sentence, which is why the order (gate first, command second) is the rule rather than a style.
async test "a refused command leaves only the sentence saying why" {
  let (shell, seen) = test_shell(busy=true)
  command(shell, "continue")
  let lines = seen()
  inspect(lines.length(), content="1")
  inspect(
    lines[0].stringify(),
    content="{\"kind\":\"error\",\"session\":\"\",\"text\":\"a turn is running here — stop it first\"}",
  )
}

///|
/// The drift log is written when asked for, and says whether a turn's first request was a rewrite.
///
/// This is the whole point of carrying a request across the turn boundary: the seam between two turns
/// is where the trim boundary most often moves — the turn just appended the messages that released it
/// — so the first request of a turn is the one most likely to have rewritten the conversation, and it
/// used to be the one request per turn nothing compared. The log is the only place outside a test
/// that figure is visible, so what it records is what this checks.
///
/// Silent by default: a turn that wrote this unasked would be a file beside the app filling up with
/// ordinary turns. `debug_log` empty is the ordinary case and the first assertion.
async test "the drift log says what a turn's first request cost, when asked" {
  let path = "_build/app_test/drift-\{@core.new_entry_id()}.jsonl"
  @platform.make_dirs("_build/app_test")
  let session = @core.Session::new(
    {
      id: "s",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [],
  )
  let shell = Shell::of(
    {
      home: "/tmp",
      settings: @core.decode_app_settings(""),
      root: "/tmp/sessions",
      start: "/tmp",
      base_url: "https://api.deepseek.com",
      jobs: @core.JobStore::new(),
      pins: [],
      session,
      path: "/tmp/s.jsonl",
      debug_log: path,
    },
    out=_json => (),
  )
  // A turn whose first request was measured against the previous turn's, and which rewrote 4,000
  // bytes of it — the shape a moved trim boundary has.
  let across : @core.RequestDrift = {
    messages: 40,
    bytes: 90_000,
    first_changed: 30,
    previous_messages: 39,
    changed_bytes: 4_000,
    within_turn: false,
    comparable: true,
  }
  let own : @core.RequestDrift = {
    messages: 42,
    bytes: 92_000,
    first_changed: 40,
    previous_messages: 40,
    changed_bytes: 2_000,
    within_turn: true,
    comparable: true,
  }
  let finished : @agent.TurnResult = {
    session,
    replies: [],
    model_calls: 2,
    tool_calls: 1,
    compactions: 0,
    usage: @core.Usage::zero(),
    settled: true,
    cost_limit_hit: false,
    time_limit_hit: false,
    truncated: false,
    request_drift: [across, own],
    last_request: [],
  }
  shell.log_drift("/tmp/s.jsonl", finished)
  let text = @platform.read_text(path)
  assert_true(text.has_suffix("\n"), msg="one JSON object per line")
  // The fields a reader of the log needs: which session, how many requests were comparable, the
  // worst rewrite of the turn, and the first request's own reading including its provenance.
  assert_true(text.contains("\"session\":\"/tmp/s.jsonl\""), msg=text)
  assert_true(text.contains("\"comparable\":2"), msg=text)
  assert_true(text.contains("\"worst_changed_bytes\":4000"), msg=text)
  assert_true(text.contains("\"within_turn\":false"), msg=text)
  assert_true(text.contains("\"changed_bytes\":4000"), msg=text)
  @platform.delete_file(path)
}

///|
/// A shell that was not asked for the log writes nothing, which is what keeps it off in the app.
async test "no debug log means no file" {
  let path = "_build/app_test/should-not-exist-\{@core.new_entry_id()}.jsonl"
  let (shell, _seen) = test_shell()
  let finished : @agent.TurnResult = {
    session: shell.shown().session,
    replies: [],
    model_calls: 1,
    tool_calls: 0,
    compactions: 0,
    usage: @core.Usage::zero(),
    settled: true,
    cost_limit_hit: false,
    time_limit_hit: false,
    truncated: false,
    request_drift: [],
    last_request: [],
  }
  shell.log_drift(path, finished)
  assert_false(@platform.path_exists(path))
}
