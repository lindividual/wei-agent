///|
/// The UI's own logic, tested without a browser.
///
/// Everything here is the part of the wiring that *decides* something: which session is displayed,
/// what the status line says, what the panels contain, when the context chip turns red, whether a
/// cached label may be reused. The browser check covers the parts that need a real DOM and a real
/// socket; these cover the parts where a wrong answer is a wrong answer, not a rendering detail —
/// and they run in milliseconds instead of a minute.
///
/// Whitebox rather than blackbox: this is the `ui` package's internal wiring, and moving it into a
/// library package to be testable would be a refactor in search of a test rather than a test of the
/// thing that ships.

///|
/// A session with a chosen number of turns, for the pieces that only need a conversation.
fn session_with(replies : Int) -> @core.Session {
  let header : @core.SessionHeader = {
    id: "s",
    timestamp: @core.format_iso_utc(0L),
    cwd: "/work/one",
    parent_session: None,
    version: Some(3),
  }
  let entries : Array[@core.Entry] = []
  let mut parent : String? = None
  for i in 0..<replies {
    let ask = @core.new_entry_id()
    entries.push({
      id: ask,
      parent_id: parent,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("question \{i}")],
          timestamp: 0L,
        }),
      ),
    })
    let answer = @core.new_entry_id()
    entries.push({
      id: answer,
      parent_id: Some(ask),
      timestamp: @core.format_iso_utc(0L),
      kind: @core.Message(
        message=@core.Assistant({
          content: [@core.Text("answer \{i}")],
          api: "openai-completions",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          usage: test_usage(100, 20),
          stop_reason: @core.Stop,
          timestamp: 0L,
          response_id: None,
          response_model: None,
          raw_stop_reason: None,
          error_message: None,
        }),
      ),
    })
    parent = Some(answer)
  }
  @core.Session::new(header, entries)
}

///|
fn test_usage(input : Int, output : Int) -> @core.Usage {
  let cost : @core.Cost = {
    input: 0.0001,
    output: 0.0002,
    cache_read: 0.0,
    cache_write: 0.0,
    total: 0.0003,
  }
  {
    input,
    output,
    cache_read: 0,
    cache_write: 0,
    reasoning: Some(5),
    total_tokens: input + output,
    cost,
  }
}

///|
fn test_app() -> App {
  {
    root: "/tmp/store",
    model: "deepseek-v4-flash",
    context_window: 1000000,
    api_key: "k",
    tools: [],
    hub: @server.Hub::new(),
    registry: [],
    jobs: @core.JobStore::new(),
    labels: LabelCache::new(),
    displayed: "",
  }
}

///|
fn runner_at(path : String, replies : Int) -> Runner {
  Runner::new(session_with(replies), path)
}

// ── the command line ───────────────────────────────────────────────────────

///|
test "the command line has usable defaults" {
  let args = parse_args(["ui"])
  assert_eq(args.port, 8790)
  assert_eq(args.model, "deepseek-v4-flash")
  assert_eq(args.store, "")
  assert_true(args.start is New)
}

///|
test "every documented flag is parsed" {
  let args = parse_args([
    "ui", "--port", "9001", "--model", "deepseek-v4", "--store", "/tmp/s", "--resume",
    "abc123",
  ])
  assert_eq(args.port, 9001)
  assert_eq(args.model, "deepseek-v4")
  assert_eq(args.store, "/tmp/s")
  match args.start {
    Session(value) => assert_eq(value, "abc123")
    _ => fail("expected --resume to be remembered")
  }
  // `-c` is the shorthand for continuing the newest session of this directory.
  assert_true(parse_args(["ui", "-c"]).start is Continue)
  assert_true(parse_args(["ui", "--continue"]).start is Continue)
  // And the last one wins, so `--resume x --new` means a new session.
  assert_true(parse_args(["ui", "--resume", "x", "--new"]).start is New)
}

///|
test "a malformed command line is refused rather than guessed at" {
  // A flag whose value is missing must not silently become the default: starting on the wrong port
  // or against the wrong store is worse than not starting.
  let missing = try {
    ignore(parse_args(["ui", "--port"]))
    false
  } catch {
    _ => true
  } noraise {
    raised => raised
  }
  assert_true(missing, msg="--port without a value should raise")
  let unknown = try {
    ignore(parse_args(["ui", "--nope"]))
    false
  } catch {
    _ => true
  } noraise {
    raised => raised
  }
  assert_true(unknown, msg="an unknown flag should raise")
  let bad_port = try {
    ignore(parse_args(["ui", "--port", "no"]))
    false
  } catch {
    _ => true
  } noraise {
    raised => raised
  }
  assert_true(bad_port, msg="a non-numeric port should raise")
}

// ── small formatting ───────────────────────────────────────────────────────

///|
test "a session id is the readable part of a file name" {
  assert_eq(
    short_id("/store/--a--/2026-09-12T13-29-09.716Z_16ce48e4.jsonl"),
    "16ce48e4",
  )
  assert_eq(short_id("plain.jsonl"), "plain")
  assert_eq(short_id("no-extension"), "no-extension")
}

///|
test "a workspace is named by its last path component" {
  assert_eq(workspace_name("/Users/x/src/app"), "app")
  assert_eq(workspace_name("/"), "/")
  assert_eq(workspace_name("relative/path"), "path")
}

///|
test "cost keeps the digits that make it non-zero" {
  // A turn costs a fraction of a cent; rounding to cents would print every turn as $0.00.
  assert_eq(format_cost(0.0), "0.000000")
  assert_eq(format_cost(0.0000345), "0.000035")
  assert_eq(format_cost(0.05), "0.050000")
  assert_eq(format_cost(1.2345), "1.2345")
}

// ── the sessions on screen ─────────────────────────────────────────────────

///|
test "a session is running while it has a turn or a queue" {
  let runner = runner_at("/store/a.jsonl", 1)
  assert_false(runner.is_running())
  runner.waiting = 1
  assert_true(runner.is_running(), msg="a queued prompt is work in flight")
  runner.waiting = 0
  runner.busy = true
  assert_true(runner.is_running())
  // A session that is not running is not "other work" either.
  runner.busy = false
  let app = test_app()
  app.display(runner)
  assert_eq(app.others_running(runner), 0)
}

///|
test "opening a session adds it once and makes it the one on screen" {
  let app = test_app()
  let first = runner_at("/store/a.jsonl", 1)
  let second = runner_at("/store/b.jsonl", 2)
  app.display(first)
  app.display(second)
  assert_eq(app.displayed, "/store/b.jsonl")
  assert_eq(app.registry.length(), 2)
  // Opening one that is already open must not add a second copy: the registry is what the panels
  // read, and duplicates would list the same session twice.
  app.display(first)
  assert_eq(app.registry.length(), 2)
  assert_eq(app.displayed, "/store/a.jsonl")
  assert_eq(app.shown().path, "/store/a.jsonl")
}

///|
test "the status line says what is happening somewhere else" {
  let app = test_app()
  let mine = runner_at("/store/a.jsonl", 1)
  let other = runner_at("/store/b.jsonl", 1)
  app.display(mine)
  other.busy = true
  app.registry.push(other)
  // The background session is visible from here, which is the point: otherwise work out of sight
  // is work the reader cannot account for.
  assert_eq(app.others_running(mine), 1)
  assert_eq(
    app.status_line(mine),
    "\{mine.status} · 1 other session(s) running",
  )
  // Asked from the running session, the idle one is not "other work".
  assert_eq(app.others_running(other), 0)
  other.busy = false
  assert_eq(app.status_line(mine), mine.status)
}

///|
test "a fresh session says so, an opened one says how much" {
  let fresh = runner_at("/store/a.jsonl", 0)
  assert_eq(fresh.status, "new session in /work/one")
  let opened = runner_at("/store/b.jsonl", 3)
  assert_eq(opened.status, "opened 6 messages in /work/one")
}

///|
test "stopping a session asks for everything it has" {
  let runner = runner_at("/store/a.jsonl", 1)
  runner.waiting = 2
  runner.busy = true
  // A running command is reachable through the handle the driver published.
  let mut stopped = false
  runner.tool = Some({
    name: "bash",
    detail: "npm run dev",
    stop: () => stopped = true,
  })
  let epoch = runner.epoch
  runner.stop()
  assert_true(runner.aborting.value)
  // The queued prompts are dropped by the epoch change, and the running command is signalled.
  assert_eq(runner.epoch, epoch + 1)
  assert_true(stopped, msg="the running tool should have been asked to stop")
}

// ── the two panels ─────────────────────────────────────────────────────────

///|
test "the turn panel lists work in flight, and nothing when idle" {
  let app = test_app()
  let running = runner_at("/store/a.jsonl", 1)
  running.busy = true
  running.prompt = "summarise the repository"
  running.phase = "running bash: ls"
  running.since = 1000L
  let idle = runner_at("/store/b.jsonl", 1)
  app.registry.push(running)
  app.registry.push(idle)
  let html = render_tasks(app, running)
  assert_true(html.contains("summarise the repository"), msg=html)
  assert_true(html.contains("running bash: ls"), msg=html)
  // Only the session doing something appears.
  assert_eq(
    count_of(html, "class=\"task\""),
    1,
    msg="an idle session must not be listed as running",
  )
  assert_true(html.contains("data-stop=\"/store/a.jsonl\""), msg=html)
  // With nothing running the region is empty, so the panel takes no space at all.
  running.busy = false
  assert_eq(render_tasks(app, idle), "<div id=\"tasks\"></div>")
}

///|
test "the background panel separates live jobs from finished ones" {
  let app = test_app()
  let id = app.jobs.start(
    kind="bash",
    label="npm run dev",
    session="/store/a.jsonl",
    started_at=1000L,
    pids=[42],
  )
  let html = render_jobs(app, 6000L)
  assert_true(html.contains("npm run dev"), msg=html)
  assert_true(html.contains("running"), msg=html)
  assert_true(html.contains("5s"), msg="the elapsed time is shown: \{html}")
  assert_true(html.contains("data-kill=\"\{id}\""), msg=html)
  assert_true(html.contains("pid 42"), msg=html)
  // A finished job keeps its record — the reader wants to see how it ended — but offers no Kill.
  app.jobs.finish(
    id,
    @core.JobStatus::Completed,
    detail="exit code: 0",
    finished_at=4000L,
  )
  let done = render_jobs(app, 9000L)
  assert_false(done.contains("data-kill"), msg=done)
  assert_true(done.contains("completed · exit code: 0"), msg=done)
  assert_true(done.contains("class=\"task done\""), msg=done)
  // Nothing at all when there is nothing to say.
  app.jobs.forget(id)
  assert_eq(render_jobs(app, 9000L), "<div id=\"jobs\"></div>")
}

// ── what the bar reports ───────────────────────────────────────────────────

///|
test "the bar reports the session's totals and its remaining context" {
  let app = test_app()
  // Three replies at 100 in / 20 out each: the totals come from the log, so they are the same
  // after a restart as before one.
  let runner = runner_at("/store/a.jsonl", 3)
  let chips = usage_chips(app, runner)
  let text = render_chips_text(chips)
  assert_true(text.contains("300 in / 60 out"), msg=text)
  assert_true(text.contains("cache"), msg=text)
  // Three replies at $0.0003 each: the bar shows the session's total.
  assert_true(text.contains("$0.000900"), msg=text)
  assert_true(text.contains("context"), msg=text)
  // The context chip is a proportion of the window, and the window is the model's.
  assert_eq(
    count_of(@html.render_bar([], right=chips).render(), "class=\"meter\""),
    1,
  )
}

///|
test "the context chip warns when the next turn would compact" {
  let app = test_app()
  // A window small enough that the estimate crosses the compaction threshold.
  let small : App = { ..app, context_window: 2000, }
  let runner = runner_at("/store/a.jsonl", 3)
  let warned = @html.render_bar([], right=usage_chips(small, runner)).render()
  let calm = @html.render_bar([], right=usage_chips(app, runner)).render()
  // The warning is the whole reason the figure is on the bar: it is the one number that changes
  // what happens next.
  assert_true(warned.contains("chip warn"), msg=warned)
  assert_false(calm.contains("chip warn"), msg=calm)
}

///|
test "the bar names the session by id and keeps the path one hover away" {
  let app = test_app()
  let runner = runner_at(
    "/store/--a--/2026-09-12T13-29-09.716Z_16ce48e4.jsonl", 1,
  )
  let html = bar_node(app, runner).render()
  assert_true(html.contains("16ce48e4"), msg=html)
  assert_true(
    html.contains(
      "title=\"/store/--a--/2026-09-12T13-29-09.716Z_16ce48e4.jsonl\"",
    ),
    msg=html,
  )
  assert_true(html.contains("deepseek-v4-flash"), msg=html)
}

// ── the label cache ────────────────────────────────────────────────────────

///|
test "a cached label is reused only while the file it describes is unchanged" {
  let cache = LabelCache::new()
  assert_true(cache.hit("/a.jsonl", 100L) is None)
  cache.store("/a.jsonl", 100L, "the first question")
  // Same modification time: the same answer, and no read.
  assert_eq(cache.hit("/a.jsonl", 100L), Some("the first question"))
  // The file grew, so what it says may have changed.
  assert_true(cache.hit("/a.jsonl", 200L) is None)
  // Sessions are cached independently.
  assert_true(cache.hit("/b.jsonl", 100L) is None)
}

// ── helpers for reading rendered HTML ──────────────────────────────────────

///|
fn count_of(text : String, needle : String) -> Int {
  let mut count = 0
  let mut rest = text
  while true {
    match rest.find(needle) {
      Some(index) => {
        count += 1
        rest = rest[index + needle.length():].to_owned()
      }
      None => break
    }
  }
  count
}

///|
/// The visible text of a chip list, so a test can talk about what a reader sees.
fn render_chips_text(chips : Array[@html.Node]) -> String {
  let html = @html.render_bar([], right=chips).render()
  let out = StringBuilder()
  let mut in_tag = false
  for c in html {
    if c == '<' {
      in_tag = true
    } else if c == '>' {
      in_tag = false
    } else if !in_tag {
      out.write_char(c)
    }
  }
  out.to_string()
}
