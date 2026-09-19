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
  test_app_in("/tmp/home")
}

///|
/// The same app with a home directory the caller controls, for tests that need skill roots to
/// resolve somewhere they can write.
fn test_app_in(home : String) -> App {
  {
    root: "/tmp/store",
    default_model_id: "deepseek-v4-flash",
    base_url: "https://api.deepseek.com",
    api_key: "k",
    key_source: "environment",
    key_hint: "k",
    env_key: "k",
    env_key_set: true,
    settings: @core.AppSettings::new(),
    settings_lock: @async.Mutex(),
    address: "127.0.0.1:8790",
    flag_max_cost: None,
    flag_max_rounds: None,
    flag_max_seconds: None,
    // The defaults, which is what a process launched with no limit flags and no settings file has.
    limits: @core.choose_limits(None, None, None, @core.AppSettings::new()),
    hub: @server.Hub::new(),
    registry: [],
    jobs: @core.JobStore::new(),
    labels: LabelCache::new(),
    home,
    skills_by_cwd: Map([]),
    live_pids: [42],
    saved_jobs: "",
    displayed: "",
    deleted: None,
    expanded: Map([]),
    // Off by default, which is what a test host is: `can_pick` says whether a dialog can be
    // opened, and there is no dialog in a test run. A test that wants the button sets it.
    can_pick: false,
  }
}

///|
fn runner_at(path : String, replies : Int) -> Runner {
  Runner::new(session_with(replies), path, @core.default_model_id())
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
  // The working directory is deliberately absent from this line: it is on the workspace row's
  // tooltip, and repeating it here buried the number that was worth reading.
  let fresh = runner_at("/store/a.jsonl", 0)
  assert_eq(fresh.status, "new session")
  let opened = runner_at("/store/b.jsonl", 3)
  assert_eq(opened.status, "opened 6 messages")
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
    arguments: Json::object(Map([("command", Json::string("npm run dev"))])),
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
  // The label is the way to the session it names, not just a name for it: the panel exists to say
  // that something is happening somewhere else, and the reader's next move is usually to go and
  // look. Same `data-session` the sidebar's rows carry, so one client handler covers both.
  assert_true(html.contains("data-session=\"/store/a.jsonl\""), msg=html)
  // With nothing running the region is empty, so the panel takes no space at all.
  running.busy = false
  assert_eq(render_tasks(app, idle), "<div id=\"tasks\"></div>")
}

///|
test "the background panel lists what is still running and drops what is not" {
  let app = test_app()
  let live = app.jobs.start(
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
  assert_true(html.contains("data-kill=\"\{live}\""), msg=html)
  assert_true(html.contains("pid 42"), msg=html)
  // The command names the session that started it, and the label is how the reader gets there.
  assert_true(html.contains("data-session=\"/store/a.jsonl\""), msg=html)
  // A finished job is gone from the panel, not kept as a card with nothing to do on it. The record
  // is still there, which is what the reader cannot see and does not need to: a stopped thing has
  // no action left, and the panel is above the list they came to click.
  let finished = app.jobs.start(
    kind="bash",
    label="npm test",
    session="/store/a.jsonl",
    started_at=2000L,
    pids=[43],
  )
  app.jobs.finish(
    finished,
    @core.JobStatus::Completed,
    detail="exit code: 0",
    finished_at=4000L,
  )
  let after = render_jobs(app, 9000L)
  assert_false(after.contains("npm test"), msg=after)
  assert_false(after.contains("completed"), msg=after)
  assert_eq(count_of(after, "data-kill="), 1, msg=after)
  // The record is kept even though nothing draws it: that is how a later kill still reaches the
  // process, and how `jobs.json` can account for it after a restart.
  assert_eq(app.jobs.get(finished).unwrap().status, @core.JobStatus::Completed)
  // Nothing running at all: an empty container, no heading.
  app.jobs.forget(live)
  assert_eq(render_jobs(app, 9000L), "<div id=\"jobs\"></div>")
}

// ── what the figures report ────────────────────────────────────────────────

///|
/// What the real app passes as overhead: a system prompt of a few hundred tokens plus seven tool
/// schemas. Named rather than inlined because it is the same figure in every case here, and the
/// point of the parameter is that it is *not* zero.
const TEST_OVERHEAD : Int = 1300

///|
test "the figures report the session's totals and its remaining context" {
  // Three replies at 100 in / 20 out each: the totals come from the log, so they are the same
  // after a restart as before one.
  let runner = runner_at("/store/a.jsonl", 3)
  let chips = usage_chips(1_000_000, TEST_OVERHEAD, runner)
  let text = render_chips_text(chips)
  assert_true(text.contains("300 in / 60 out"), msg=text)
  assert_true(text.contains("cache"), msg=text)
  // Three replies at $0.0003 each: the figures show the session's total.
  assert_true(text.contains("$0.000900"), msg=text)
  assert_true(text.contains("context"), msg=text)
  // The context chip is a proportion of the window, and the window is the model's — but the meter is
  // only drawn when the proportion is worth drawing. Against a 1M window these few messages are a
  // tenth of a percent, where a meter is an empty rectangle that still draws the eye. The figure is
  // still there; only the meter is not.
  assert_true(text.contains(" / 1M"), msg=text)
  assert_eq(
    count_of(@html.render_usage(chips).render(), "class=\"meter\""),
    0,
    msg="a meter at a tenth of a percent is a lie, not a figure",
  )
  // A window this conversation actually fills most of does get its meter.
  let tight = usage_chips(4_000, TEST_OVERHEAD, runner)
  assert_eq(count_of(@html.render_usage(tight).render(), "class=\"meter\""), 1)
}

///|
/// Nothing spent and nothing said: no chips at all. An empty session used to open on four chips
/// reading `0`, which is the first thing a reader saw and none of it was true of anything yet.
test "a session with no turn behind it shows no usage figures" {
  let fresh = runner_at("/store/fresh.jsonl", 0)
  assert_eq(usage_chips(1_000_000, TEST_OVERHEAD, fresh).length(), 0)
  let used = runner_at("/store/used.jsonl", 2)
  assert_true(usage_chips(1_000_000, TEST_OVERHEAD, used).length() > 0)
}

///|
/// The figures move while a turn runs, not when it ends.
///
/// Each model call's tokens, cache reads and context size are known the moment its response comes
/// back, and the calls of a twenty-round turn are exactly when the reader is watching them: waiting
/// for the outcome would leave the figures of the *previous* turn on screen for the whole of the
/// current one. Both copies exist on purpose — `session` is the transcript's, which must not contain
/// the half-written turn, and `in_flight_session` is the log as it now stands.
test "the chips report the running turn's log, not the committed one" {
  let runner = runner_at("/store/a.jsonl", 1)
  let before = render_chips_text(usage_chips(1_000_000, TEST_OVERHEAD, runner))
  assert_true(before.contains("100 in / 20 out"), msg=before)
  // A second call has come back and is in the log; the turn is still running.
  runner.in_flight_session = Some(session_with(2))
  let during = render_chips_text(usage_chips(1_000_000, TEST_OVERHEAD, runner))
  assert_true(during.contains("200 in / 40 out"), msg=during)
  assert_true(during.contains("$0.000600"), msg=during)
  assert_eq(runner.latest_log().usage().replies, 2)
  // Dropped when the turn ends: what it held is in `session` by then, and a copy left here would
  // answer for a state the session no longer has.
  runner.in_flight_session = None
  let after = render_chips_text(usage_chips(1_000_000, TEST_OVERHEAD, runner))
  assert_true(after.contains("100 in / 20 out"), msg=after)
  assert_eq(runner.latest_log().usage().replies, 1)
}

///|
/// The figures a turn moves get a region of their own.
///
/// They are refreshed several times per turn, and the composer they sit under holds whatever the
/// reader is typing — so a turn updating a number replaces this element and nothing else.
test "the usage chips are their own region" {
  let html = @html.render_usage([@html.chip("cost", "$0.01")]).render()
  assert_true(html.contains("id=\"usage\""), msg=html)
  assert_true(html.contains("$0.01"), msg=html)
  // Rendered even with nothing in it, so a refresh is always a valid replace.
  assert_true(html.contains("<span class=\"usage\" id=\"usage\">"), msg=html)
}

///|
test "the context chip warns when the next turn would compact" {
  let runner = runner_at("/store/a.jsonl", 3)
  // The window is the argument that decides this, so the two cases differ only in it: the model
  // and the conversation are identical, and a small window is what crosses the threshold.
  let warned = @html.render_usage(usage_chips(2000, TEST_OVERHEAD, runner)).render()
  let calm = @html.render_usage(usage_chips(1_000_000, TEST_OVERHEAD, runner)).render()
  // The warning is the whole reason the figure is on the page: it is the one number that changes
  // what happens next.
  assert_true(warned.contains("chip warn"), msg=warned)
  assert_false(calm.contains("chip warn"), msg=calm)
}

///|
/// The title is the one fact from the old bar that stays at the top, and it is the session's label.
///
/// The model moved to the picker under the composer and the figures moved with it, so what is left
/// to answer "which conversation is this?" while a long answer scrolls is this line.
///
/// The wording is the sidebar's rule, asked of a real file: the reader's name for it if there is
/// one, else the first question, else the id. Both halves are asserted here because the point of
/// the rule is that the two places agree.
async test "the title names the session the way the sidebar row does" {
  let home = "_build/app_title_test/\{@core.new_entry_id()}"
  let root = "\{home}/store"
  @platform.make_dirs(root)
  let app = test_app_in(home)
  let (session, path) = create_session(root, "/work/one")
  // The header first: a session is created empty and filled in by whoever appends the first
  // entry, so there is nothing to append to until this line.
  @platform.ensure_session(path, session.header)
  let ask : @core.Entry = {
    id: "u1",
    parent_id: None,
    timestamp: @core.format_iso_utc(0L),
    kind: @core.Message(
      message=@core.User({
        content: [@core.Text("what does this repo do")],
        timestamp: 0L,
      }),
    ),
  }
  @platform.append_text(path, ask.to_line())
  let runner = Runner::new(session, path, app.default_model_id)
  app.registry.push(runner)
  let asked = title_node(app, runner).render()
  assert_true(asked.contains("id=\"title\""), msg=asked)
  assert_true(asked.contains("what does this repo do"), msg=asked)
  // One hover away, because the label is clipped to one line and is not the file.
  assert_true(asked.contains("title=\"\{path}\""), msg=asked)
  assert_eq(
    app.session_label(path, app.labels.modified_of(path)),
    "what does this repo do",
  )
  // A name the reader gave wins, in both places at once.
  @platform.append_text(
    path,
    @core.session_name_entry(Some("the repo tour"), Some("u1"), 0L).to_line(),
  )
  app.labels.forget(path)
  let named = title_node(app, runner).render()
  assert_true(named.contains("the repo tour"), msg=named)
  assert_false(named.contains("what does this repo do"), msg=named)
  assert_eq(
    app.session_label(path, app.labels.modified_of(path)),
    "the repo tour",
  )
}

///|
/// One wording for "nothing has been asked in this session yet".
///
/// The sidebar's row and the line above the conversation both show it, so it is a function rather
/// than a string written twice: a reader comparing the two is checking that they agree.
test "an unnamed, empty session has one name in both places" {
  assert_eq(@html.display_label(""), "New session")
  // Anything that was said, or named, is left exactly as it is.
  assert_eq(@html.display_label("refactor auth"), "refactor auth")
  assert_eq(
    @html.display_label("what does this repo do"),
    "what does this repo do",
  )
}

///|
/// A session with nothing in it is titled with the same words the sidebar row uses.
///
/// Two ways to have no label, and they are different answers on purpose. An open session nobody has
/// typed into gets the plain words — the row in the list says them, so the line above the
/// conversation does too. A session the store knows about but this process has not opened gets its
/// short id, because that is also what the row shows for one, and it at least matches the file on
/// disk.
async test "a session with nothing in it is titled the way its row is" {
  let app = test_app()
  // Open, and empty: the row says "New session", so the title does.
  let fresh = runner_at("/store/fresh.jsonl", 0)
  app.registry.push(fresh)
  let html = title_node(app, fresh).render()
  assert_true(html.contains(">New session</span>"), msg=html)
  // The id is not on the line any more: the plain words are what the row says, and the path stays
  // in the tooltip for the reader who is looking for the file.
  assert_false(html.contains(">fresh<"), msg=html)
  // Not open in this process: the id, which is what the sidebar resolves for a session it has not
  // read either.
  let closed = runner_at(
    "/store/--a--/2026-09-12T13-29-09.716Z_16ce48e4.jsonl", 1,
  )
  let other = title_node(app, closed).render()
  assert_true(other.contains("16ce48e4"), msg=other)
  assert_true(
    other.contains(
      "title=\"/store/--a--/2026-09-12T13-29-09.716Z_16ce48e4.jsonl\"",
    ),
    msg=other,
  )
}

// ── the label cache ────────────────────────────────────────────────────────

///|
test "cached facts are reused only while the file they describe is unchanged" {
  let cache = LabelCache::new()
  assert_true(cache.hit("/a.jsonl", 100L) is None)
  cache.store("/a.jsonl", 100L, { label: "the first question", name: None, })
  // Same modification time: the same answer, and no read.
  assert_eq(
    cache.hit("/a.jsonl", 100L),
    Some({ label: "the first question", name: None, }),
  )
  // The file grew, so what it says may have changed.
  assert_true(cache.hit("/a.jsonl", 200L) is None)
  // Sessions are cached independently.
  assert_true(cache.hit("/b.jsonl", 100L) is None)
}

///|
test "the name in a log is read through the entry decoder" {
  let header : @core.SessionHeader = {
    id: "s",
    timestamp: @core.format_iso_utc(0L),
    cwd: "/work/one",
    parent_session: None,
    version: Some(3),
  }
  let ask : @core.Entry = {
    id: "u1",
    parent_id: None,
    timestamp: @core.format_iso_utc(0L),
    kind: @core.Message(
      message=@core.User({ content: [@core.Text("hi")], timestamp: 0L, }),
    ),
  }
  let named = @core.session_name_entry(Some("refactor auth"), Some("u1"), 0L)
  let log = header.to_line() + ask.to_line() + named.to_line()
  assert_eq(session_name_of(log), Some("refactor auth"))
  // A log nobody has named has no name, and neither has one that does not parse yet.
  assert_eq(session_name_of(header.to_line() + ask.to_line()), None)
  assert_eq(session_name_of("{\"type\":\"message\""), None)
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
  let html = @html.render_usage(chips).render()
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

// ── commands ───────────────────────────────────────────────────────────────

///|
test "only a real /name is a command" {
  match parse_command("/name refactor auth") {
    Some(Name(value)) => assert_eq(value, "refactor auth")
    _ => fail("expected a command")
  }
  // Extra spaces are the reader's, not part of the name.
  match parse_command("  /name   two   spaces  ") {
    Some(Name(value)) => assert_eq(value, "two   spaces")
    _ => fail("expected a command")
  }
  // Bare: report, not clear.
  match parse_command("/name") {
    Some(Name(value)) => assert_eq(value, "")
    _ => fail("expected a command")
  }
  // A slash that is not a command is a message, and goes to the model untouched.
  for
    text in [
      "/namefoo", "/names", "/tmp/some/path is broken", "what is 1/2?", "/Name x",
    ] {
    assert_true(
      parse_command(text) is None,
      msg="\{text} should not be a command",
    )
  }
}

// ── the name in the list and at the top of the page ────────────────────────

///|
async test "a named session is listed by its name, an unnamed one by its first question" {
  let app = test_app()
  // The three answers, in the order the rule prefers them: what the reader called it, what they
  // first asked, and — for a session with neither — the id of the file on disk.
  app.labels.store("/store/a.jsonl", 0L, {
    label: "the first question",
    name: None,
  })
  assert_eq(app.session_label("/store/a.jsonl", 0L), "the first question")
  app.labels.store("/store/a.jsonl", 0L, {
    label: "the first question",
    name: Some("refactor auth"),
  })
  assert_eq(app.session_label("/store/a.jsonl", 0L), "refactor auth")
  assert_eq(app.session_label("/store/b.jsonl", 0L), "b")
}

///|
test "the sidebar shows the reader's name instead of the first question" {
  let app = test_app()
  app.labels.store("/store/a.jsonl", 100L, {
    label: "the first question",
    name: Some("refactor auth"),
  })
  app.labels.store("/store/b.jsonl", 100L, {
    label: "another question",
    name: None,
  })
  // The label the sidebar shows is resolved in `workspace_items`, which reads the store; what is
  // testable here is the decision it applies: the name wins when there is one.
  let named = app.labels.hit("/store/a.jsonl", 100L).unwrap()
  let plain = app.labels.hit("/store/b.jsonl", 100L).unwrap()
  assert_eq(named.name, Some("refactor auth"))
  assert_eq(named.label, "the first question")
  assert_eq(plain.name, None)
}

// ── the jobs panel stops showing dead pids ─────────────────────────────────

///|
test "the job panel shows only the processes that are still there" {
  let app = test_app()
  // Three pids recorded, as a command really is: its shell, the `ps` helper that reported the
  // tree, and the process that was actually started.
  let id = app.jobs.start(
    kind="bash",
    label="npm run dev",
    session="/store/a.jsonl",
    started_at=0L,
    pids=[41, 42, 43],
  )
  // Only 42 is still alive.
  app.live_pids = [42]
  let html = render_jobs(app, 1000L)
  assert_true(html.contains("pid 42"), msg=html)
  assert_false(html.contains("41"), msg=html)
  assert_false(html.contains("43"), msg=html)
  // The record keeps all of them: a kill has to reach everything that was ever part of the job.
  assert_eq(app.jobs.get(id).unwrap().pids, [41, 42, 43])
  // With nothing alive the row says so rather than printing dead pids.
  app.live_pids = []
  assert_false(
    render_jobs(app, 1000L).contains("pid"),
    msg=render_jobs(app, 1000L),
  )
}

///|
/// The transcript says which session it is of, but not in the attribute that means "open this".
///
/// `[data-session]` is the sidebar's switch request. Putting it on the transcript made every click
/// inside the conversation ask the server to switch to it — and since the tag is a short id, which
/// names no file, the server started a *new* session instead: the transcript was replaced by an
/// empty one and the block the reader had just opened was gone.
test "the transcript marks its session without inviting a switch" {
  let messages : Array[@core.ContextMessage] = []
  let html = @html.render_transcript(messages, session="16ce48e4").render()
  assert_true(html.contains("data-shown-session=\"16ce48e4\""), msg=html)
  assert_false(html.contains("data-session="), msg=html)
}

///|
/// Skills are discovered per working directory and remembered.
///
/// The cache is the point of the key: a scan reads files from disk, and a turn must not pay
/// for it twice. The key is the point of the map: a session opened in another repository has
/// its own project-local skills, so the answer cannot be global.
async test "skills are loaded once per working directory" {
  let home = "_build/app_skill_test/\{@core.new_entry_id()}"
  @platform.make_dirs("\{home}/.wei/skills/demo")
  @platform.write_text(
    "\{home}/.wei/skills/demo/SKILL.md",
    "---\nname: demo\ndescription: A skill for tests.\n---\n",
  )
  let app = test_app_in(home)
  // Nothing is known before the first turn asks.
  assert_eq(app.skills_for("/work").length(), 0)
  app.load_skills("/work")
  assert_eq(app.skills_for("/work").length(), 1)
  assert_eq(app.skills_for("/work")[0].name, "demo")
  // A second call is served from the cache rather than rescanning.
  app.load_skills("/work")
  assert_eq(app.skills_for("/work").length(), 1)
  // A directory that has not been looked at is still empty, not another directory's answer.
  assert_eq(app.skills_for("/elsewhere").length(), 0)
}

///|
// ── settings ───────────────────────────────────────────────────────────────

///|
/// A skill switched off in settings does not reach the prompt, and switching it back on does —
/// without a rescan, because the file never moved.
async test "a disabled skill leaves the catalog the model receives" {
  let home = "_build/app_skill_test/\{@core.new_entry_id()}"
  @platform.make_dirs("\{home}/.wei/skills/demo")
  @platform.write_text(
    "\{home}/.wei/skills/demo/SKILL.md",
    "---\nname: demo\ndescription: A skill for tests.\n---\n",
  )
  let app = test_app_in(home)
  app.load_skills("/work")
  assert_true(
    @core.skill_catalog_prompt(app.skills_for("/work")).contains("demo"),
  )
  app.settings = app.settings.with_skill_enabled("demo", false)
  // The panel still lists it — that is the only place it can be turned back on — while the
  // catalog the model gets is empty.
  assert_eq(app.discovered_skills("/work").length(), 1)
  assert_eq(app.skills_for("/work").length(), 0)
  assert_eq(@core.skill_catalog_prompt(app.skills_for("/work")), "")
  // And back on, with no second scan.
  app.settings = app.settings.with_skill_enabled("demo", true)
  assert_eq(app.skills_for("/work").length(), 1)
}

///|
/// The rule this feature is: a workspace's own file wins, the saved text fills in where there is
/// none, and the panel says which of the two is in force. Checked through the real filesystem
/// because the point being pinned is that an edit to `AGENTS.md` reaches the *next* prompt — the
/// one thing a cache here would quietly break.
async test "a workspace AGENTS.md reaches the prompt and the saved text steps aside" {
  let home = "_build/app_agents_test/\{@core.new_entry_id()}"
  let cwd = "_build/app_agents_test/\{@core.new_entry_id()}/project"
  @platform.make_dirs(cwd)
  let app = test_app_in(home)
  app.settings = app.settings.with_agents_md("From the settings panel.")
  let runner : Runner = { ..runner_at("/store/a.jsonl", 0), cwd, }
  // No file yet: the saved text is what the turn sends, and the panel says so.
  assert_true(
    app.system_prompt(runner).contains("From the settings panel."),
    msg=app.system_prompt(runner),
  )
  assert_true(render_settings_panel(app, runner).contains("saved in settings"))
  // Writing the file changes what the next turn sends, without a restart and without a rescan.
  @platform.write_text("\{cwd}/AGENTS.md", "Run moon test before committing.")
  let prompt = app.system_prompt(runner)
  assert_true(prompt.contains("Run moon test before committing."), msg=prompt)
  assert_false(prompt.contains("From the settings panel."), msg=prompt)
  let panel = render_settings_panel(app, runner)
  assert_true(panel.contains("AGENTS.md in this workspace"), msg=panel)
  // The fallback is still in the box, because it still applies everywhere else — and the preview
  // is the file, so the two lines disagree on purpose.
  assert_true(panel.contains("From the settings panel."), msg=panel)
  // Removing it falls back again, which is the case a reader would notice as "my file is being
  // ignored" if the read were cached or the source were read once.
  @platform.write_text("\{cwd}/AGENTS.md", "  ")
  assert_true(
    app.system_prompt(runner).contains("From the settings panel."),
    msg=app.system_prompt(runner),
  )
  // And with neither, the prompt is exactly what it was before any instructions existed.
  app.settings = app.settings.with_agents_md("")
  let bare = app.system_prompt(runner)
  assert_false(bare.contains("From the settings panel."), msg=bare)
  assert_true(bare.contains("## How to work"), msg=bare)
}

///|
/// Saving the instructions reports which source is in force, because the workspace case is the one
/// where a save is invisible: a repository with its own `AGENTS.md` keeps using it.
async test "saving instructions says whether they are the ones being sent" {
  let home = "_build/app_agents_test/\{@core.new_entry_id()}"
  let cwd = "_build/app_agents_test/\{@core.new_entry_id()}/project"
  @platform.make_dirs(cwd)
  let app = test_app_in(home)
  let runner : Runner = { ..runner_at("/store/a.jsonl", 0), cwd, }
  let saved = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyAgentsMd(text="Prefer small diffs."),
  )
  assert_eq(@platform.load_settings(home).agents_md, "Prefer small diffs.")
  assert_true(saved.contains("the next turn in a workspace without"), msg=saved)
  // Standing in a workspace that has its own file, the same save is reported as overruled — the
  // one message that stops "I saved it and nothing changed" reading as a bug.
  @platform.write_text("\{cwd}/AGENTS.md", "Repository rules.")
  let overruled = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyAgentsMd(text="Prefer small diffs."),
  )
  assert_true(overruled.contains("takes precedence"), msg=overruled)
  // Clearing it is said plainly rather than as a save of nothing.
  let cleared = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyAgentsMd(text=""),
  )
  assert_eq(@platform.load_settings(home).agents_md, "")
  assert_true(cleared.contains("cleared"), msg=cleared)
}

///|
/// The instructions block sits in the panel the page renders, and the object that reaches the
/// model is built from the same function the panel read.
async test "the panel and the prompt agree about the instructions" {
  let home = "_build/app_agents_test/\{@core.new_entry_id()}"
  let cwd = "_build/app_agents_test/\{@core.new_entry_id()}/project"
  @platform.make_dirs(cwd)
  @platform.write_text("\{cwd}/AGENTS.md", "Panel and prompt agree.")
  let app = test_app_in(home)
  let runner : Runner = { ..runner_at("/store/a.jsonl", 0), cwd, }
  let view = settings_view(app, runner)
  assert_eq(view.instructions_source, "AGENTS.md in this workspace")
  assert_eq(view.instructions_preview, "Panel and prompt agree.")
  assert_true(app.system_prompt(runner).contains(view.instructions_preview))
}

///|
/// The panel renders what the process is actually doing: the session's own working directory, and
/// the skills of *that* directory rather than of wherever the server started.
async test "the settings panel describes the displayed session's workspace" {
  let home = "_build/app_skill_test/\{@core.new_entry_id()}"
  @platform.make_dirs("\{home}/.wei/skills/global-one")
  @platform.write_text(
    "\{home}/.wei/skills/global-one/SKILL.md",
    "---\nname: global-one\ndescription: Everywhere.\n---\n",
  )
  @platform.make_dirs("/tmp/project/.wei/skills/local-one")
  @platform.write_text(
    "/tmp/project/.wei/skills/local-one/SKILL.md", "---\nname: local-one\ndescription: Only in the project.\n---\n",
  )
  let app = test_app_in(home)
  let runner = runner_at("/store/a.jsonl", 0)
  // A session in another repository: the panel must describe *its* workspace, not the one the
  // server was started in.
  let runner : Runner = { ..runner, cwd: "/tmp/project", }
  let html = render_settings_panel(app, runner)
  assert_true(html.contains("global-one"), msg=html)
  assert_true(html.contains("local-one"), msg=html)
  // The store is the one the process was started with, not a guess from the cwd.
  assert_true(html.contains("/tmp/store"), msg=html)
  assert_true(html.contains("deepseek-v4-flash"), msg=html)
  // A key that came from the environment is reported as such, because a saved key that is being
  // ignored is the confusing case.
  assert_true(html.contains("DEEPSEEK_API_KEY is set"), msg=html)
  assert_true(html.contains("from DEEPSEEK_API_KEY"), msg=html)
}

///|
/// Applying a form computes the disabled set from what the page was showing, so an unchecked box
/// means off and a name the page never showed is not invented.
test "a posted skill set becomes the disabled list the panel was showing" {
  let discovered : Array[@core.Skill] = [
    { name: "alpha", description: "a", path: "/a", },
    { name: "beta", description: "b", path: "/b", },
  ]
  // Everything checked: nothing is off, including a name that was off before.
  assert_eq(
    disabled_after_apply(discovered, ["beta"], ["alpha", "beta"]).length(),
    0,
  )
  // One unchecked: that one is off.
  let off = disabled_after_apply(discovered, [], ["alpha"])
  assert_eq(off.length(), 1)
  assert_eq(off[0], "beta")
  // A name in the previous list that has no file stays off, because the page showed it and the
  // reader left it unchecked.
  let stale : Array[@core.Skill] = []
  let kept = disabled_after_apply(stale, ["gone"], [])
  assert_eq(kept.length(), 1)
  assert_eq(kept[0], "gone")
  // A name the page never showed and the reader never saw is not switched off by omission.
  let unknown = disabled_after_apply(discovered, [], [
    "alpha", "beta", "new-one",
  ])
  assert_eq(unknown.length(), 0)
}

///|
/// Saving a limit changes what the *next* turn runs under, and the message says which values are in
/// force rather than which were typed.
async test "a saved limit is adopted on the next turn, and reported as it will be used" {
  let home = "_build/app_settings_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let app = test_app_in(home)
  let runner = runner_at("/store/a.jsonl", 0)
  // The defaults are in force before anything is saved.
  assert_eq(app.limits.max_cost.source, @core.Default)
  let message = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyLimits(
      max_rounds=Some(40),
      max_cost=Some(0.25),
      max_seconds=Some(1800),
    ),
  )
  assert_true(message.contains("limits saved"), msg=message)
  assert_true(message.contains("0.25"), msg=message)
  assert_true(message.contains("1800"), msg=message)
  // In force immediately: the next turn reads the app's limits, not the file.
  assert_eq(app.limits.max_rounds.value, 40.0)
  assert_eq(app.limits.max_rounds.source, @core.Saved)
  assert_eq(app.limits.max_cost.value, 0.25)
  assert_eq(app.limits.max_cost.source, @core.Saved)
  assert_eq(app.limits.max_seconds.value, 1800.0)
  assert_eq(app.limits.max_seconds.source, @core.Saved)
  // And on disk, so a restart keeps them.
  let reloaded = @platform.load_settings(home)
  assert_eq(reloaded.max_rounds, Some(40))
  assert_eq(reloaded.max_cost, Some(0.25))
  assert_eq(reloaded.max_seconds, Some(1800))
  // Zero is kept as zero rather than treated as "unset": it is how a reader removes the bound,
  // and the status line says so in words rather than printing a bound of zero.
  let off = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyLimits(
      max_rounds=Some(0),
      max_cost=Some(0.0),
      max_seconds=Some(0),
    ),
  )
  assert_eq(app.limits.max_cost.value, 0.0)
  assert_eq(@platform.load_settings(home).max_cost, Some(0.0))
  assert_true(off.contains("no time bound"), msg=off)
  // Clearing all of them goes back to the built-in defaults rather than to no bound, and the file
  // records that the reader has no opinion.
  let cleared = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyLimits(
      max_rounds=None,
      max_cost=None,
      max_seconds=None,
    ),
  )
  // The default is back, and nothing is saved — an empty box is "no opinion", not a bound.
  assert_eq(app.limits.max_rounds.source, @core.Default)
  assert_eq(app.limits.max_cost.value, @core.default_max_cost())
  assert_eq(
    app.limits.max_seconds.value,
    @core.default_max_seconds().to_double(),
  )
  assert_true(@platform.load_settings(home).max_cost is None)
  assert_true(@platform.load_settings(home).max_seconds is None)
  assert_true(cleared.contains("200 calls"), msg=cleared)
  assert_true(cleared.contains("1800s"), msg=cleared)
}

///|
/// A limit a launch flag pinned is saved but not in force, and the reader is told which flag is in
/// the way — the one case where the panel accepts an edit that does nothing, and the worst one to
/// leave silent.
async test "a flag keeps its precedence over a saved limit, and says so" {
  let home = "_build/app_settings_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let base = test_app_in(home)
  let app : App = {
    ..base,
    flag_max_cost: Some(0.1),
    flag_max_rounds: None,
    flag_max_seconds: Some(60),
    limits: @core.choose_limits(
      None,
      Some(0.1),
      Some(60),
      @core.AppSettings::new(),
    ),
  }
  // The run flags win even before anything is saved.
  assert_eq(app.limits.max_cost.value, 0.1)
  assert_eq(app.limits.max_cost.source, @core.Flag)
  assert_eq(app.limits.max_seconds.value, 60.0)
  assert_eq(app.limits.max_seconds.source, @core.Flag)
  let runner = runner_at("/store/a.jsonl", 0)
  let message = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyLimits(
      max_rounds=Some(40),
      max_cost=Some(5.0),
      max_seconds=Some(1800),
    ),
  )
  // Saved, because the setting is still what a restart without the flags would use.
  let reloaded = @platform.load_settings(home)
  assert_eq(reloaded.max_cost, Some(5.0))
  assert_eq(reloaded.max_rounds, Some(40))
  assert_eq(reloaded.max_seconds, Some(1800))
  // But the cost and seconds limits in force are still the flags', and the call limit — which no
  // flag pinned — is the saved one.
  assert_eq(app.limits.max_cost.value, 0.1)
  assert_eq(app.limits.max_cost.source, @core.Flag)
  assert_eq(app.limits.max_seconds.value, 60.0)
  assert_eq(app.limits.max_seconds.source, @core.Flag)
  assert_eq(app.limits.max_rounds.value, 40.0)
  assert_eq(app.limits.max_rounds.source, @core.Saved)
  assert_true(message.contains("--max-cost"), msg=message)
  assert_true(message.contains("--max-seconds"), msg=message)
  assert_true(message.contains("still in force"), msg=message)
}

///|
/// Saving a key through the panel changes what the next turn sends, and never changes what the
/// environment said — a saved key is a fallback, not an override.
async test "saving a key writes it, adopts it, and reports where it came from" {
  let home = "_build/app_settings_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let app = test_app_in(home)
  // No environment key in this app, so a saved one is what gets used.
  let app2 : App = {
    ..app,
    env_key: "",
    env_key_set: false,
    api_key: "",
    key_source: "none",
    key_hint: "",
  }
  let runner = runner_at("/store/a.jsonl", 0)
  let message = apply_settings_post(
    app2,
    runner,
    @core.SettingsPost::SaveKey(key="sk-panel", clear=false),
  )
  assert_true(message.contains("next turn"), msg=message)
  assert_eq(app2.api_key, "sk-panel")
  assert_eq(app2.key_source, "saved")
  assert_eq(app2.settings.saved_api_key, "sk-panel")
  assert_eq(@platform.load_settings(home).saved_api_key, "sk-panel")
  // Clearing it takes it back out, and says what is in use instead — which here is nothing.
  let cleared = apply_settings_post(
    app2,
    runner,
    @core.SettingsPost::SaveKey(key="", clear=true),
  )
  assert_true(cleared.contains("no key is set"), msg=cleared)
  assert_eq(app2.api_key, "")
  assert_eq(app2.key_source, "none")
  assert_eq(@platform.load_settings(home).saved_api_key, "")
  // With the environment set, the saved key is written and reported as a fallback rather than
  // adopted — the difference between "saved" and "in use" is the whole point of the report.
  let app3 : App = { ..app, env_key: "sk-env", env_key_set: true, }
  app3.set_key(app3.resolve_key())
  assert_eq(app3.key_source, "environment")
  let reported = apply_settings_post(
    app3,
    runner,
    @core.SettingsPost::SaveKey(key="sk-panel", clear=false),
  )
  assert_true(reported.contains("DEEPSEEK_API_KEY is in use"), msg=reported)
  assert_eq(app3.api_key, "sk-env")
  assert_eq(@platform.load_settings(home).saved_api_key, "sk-panel")
}

///|
/// The status line names the cost limit when that is what stopped the turn.
///
/// A turn stopped by a guard is not the same thing as a model that stalled, and the reader
/// deciding whether to raise the limit needs to be told which happened. The money is already
/// spent when this is printed, so it is part of the message rather than a separate figure.
test "the status line says when the cost limit stopped a turn" {
  let session = session_with(1)
  let result : @agent.TurnResult = {
    session,
    replies: [],
    model_calls: 79,
    tool_calls: 60,
    compactions: 0,
    usage: {
      input: 1000,
      output: 200,
      cache_read: 0,
      cache_write: 0,
      reasoning: None,
      total_tokens: 1200,
      cost: {
        input: 0.1,
        output: 0.2,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 1.25,
      },
    },
    settled: false,
    cost_limit_hit: true,
    time_limit_hit: false,
    truncated: false,
    request_drift: [],
    last_request: [],
  }
  let text = status_text(result, false)
  assert_true(text.contains("at the $1.2500 cost limit"), msg=text)
  // A stalled model reads differently, so the two cannot be confused.
  let stalled = status_text({ ..result, cost_limit_hit: false, }, false)
  assert_true(stalled.contains("gave up"), msg=stalled)
  assert_false(stalled.contains("cost limit"), msg=stalled)
}

///|
/// The time limit names itself too, for the same reason the cost limit does: the reader's
/// response differs. A turn cut short by the clock was making progress and may be worth
/// resuming with a longer bound, which is not true of a model that was looping.
test "the status line says when the time limit stopped a turn" {
  let session = session_with(1)
  let result : @agent.TurnResult = {
    session,
    replies: [],
    model_calls: 40,
    tool_calls: 30,
    compactions: 0,
    usage: {
      input: 100,
      output: 50,
      cache_read: 0,
      cache_write: 0,
      reasoning: None,
      total_tokens: 150,
      cost: {
        input: 0.01,
        output: 0.01,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.02,
      },
    },
    settled: false,
    cost_limit_hit: false,
    time_limit_hit: true,
    truncated: false,
    request_drift: [],
    last_request: [],
  }
  let text = status_text(result, false)
  assert_true(text.contains("at the time limit"), msg=text)
  // The three guards are distinguishable; a round-limit stop must not read as a time one.
  let rounds = status_text({ ..result, time_limit_hit: false, }, false)
  assert_true(rounds.contains("gave up"), msg=rounds)
  assert_false(rounds.contains("time limit"), msg=rounds)
}

///|
/// A turn that finished normally leaves the status line empty, because the figures that used to be
/// copied here now live on the footer under the reply — and the footer is written for a live turn as
/// well as for a reloaded one. Two copies of the same numbers is where a reader stops believing
/// either of them.
test "a finished turn says nothing on the status line; its figures are on the footer" {
  let session = session_with(1)
  let result : @agent.TurnResult = {
    session,
    replies: [],
    model_calls: 1,
    tool_calls: 0,
    compactions: 0,
    usage: {
      input: 100,
      output: 384000,
      cache_read: 0,
      cache_write: 0,
      reasoning: None,
      total_tokens: 384100,
      cost: {
        input: 0.01,
        output: 0.5,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.51,
      },
    },
    settled: true,
    cost_limit_hit: false,
    time_limit_hit: false,
    truncated: true,
    request_drift: [],
    last_request: [],
  }
  let text = status_text(result, false)
  assert_eq(
    text,
    "",
    msg="a finished turn should not restate its own figures: \{text}",
  )
  // And what it used to say is still said — on the footer, which carries the counts and the
  // truncation note (pinned in `html/turn_stats_test.mbt`).
  let footer = @html.render_turn_footer(
    "stats-1",
    @html.turn_stats_of(session.context().messages),
  ).render()
  assert_true(footer.contains("model call"), msg=footer)
}

///|
/// A retry says so on the status line, and gives the line back when the call answers.
///
/// Checked as a pair because the two halves are one fact about one line: the reader who is told
/// `no answer — retrying (2 of 4)` has to be told when it is no longer true, or the turn that
/// recovers keeps saying the model has not answered while its answer streams in underneath.
///
/// The counts are in the sentence for the reason the plain `working…` line has none: a reader
/// deciding whether to keep waiting is asking whether anything is still being tried.
test "a retry is said on the status line and taken back" {
  assert_eq(
    retry_status(Some({ next: 2, total: 4, }), working_status),
    "no answer — retrying (2 of 4)",
  )
  // And what it goes back to is the line the caller was showing — the counts when there are any,
  // because a reader who was watching them is the reader deciding whether to keep waiting. Passed in
  // rather than assumed: this function is the pair, not the memory.
  assert_eq(
    retry_status(None, "\{working_status} 3 model call(s), 2 tool call(s)"),
    "\{working_status} 3 model call(s), 2 tool call(s)",
  )
}

///|
/// The limits are flags, and they are optional: an absent flag means "no opinion", which is what
/// lets the panel's saved value win — while a value typed here still wins over that saved value.
///
/// The value matters in a way the other flags do not: these are the only bounds on what an
/// unattended turn can spend or how long it can keep trying, so they have to be settable without
/// editing code — and each has to survive the round trip through the parser as a number, not a
/// string that happens to look like one. Zero is kept distinct from absent, because it is the off
/// switch.
test "the limits are parsed, and zero is distinct from absent" {
  assert_true(parse_args(["ui"]).max_cost is None)
  assert_true(parse_args(["ui"]).max_rounds is None)
  assert_true(parse_args(["ui"]).max_seconds is None)
  assert_eq(parse_args(["ui", "--max-cost", "0.25"]).max_cost, Some(0.25))
  assert_eq(parse_args(["ui", "--max-rounds", "40"]).max_rounds, Some(40))
  assert_eq(parse_args(["ui", "--max-seconds", "1800"]).max_seconds, Some(1800))
  // Zero is the off switch, which is why it cannot be collapsed into "not given".
  assert_eq(parse_args(["ui", "--max-cost", "0"]).max_cost, Some(0.0))
  assert_eq(parse_args(["ui", "--max-rounds", "0"]).max_rounds, Some(0))
  assert_eq(parse_args(["ui", "--max-seconds", "0"]).max_seconds, Some(0))
  // Each flag is independent: setting one does not clear the others.
  let all = parse_args([
    "ui", "--max-cost", "2", "--max-rounds", "7", "--max-seconds", "90",
  ])
  assert_eq(all.max_cost, Some(2.0))
  assert_eq(all.max_rounds, Some(7))
  assert_eq(all.max_seconds, Some(90))
  // A malformed value is refused rather than becoming zero, which would silently mean unlimited —
  // the opposite of what someone typing a limit intends.
  let bad = try {
    ignore(parse_args(["ui", "--max-cost", "cheap"]))
    false
  } catch {
    _ => true
  } noraise {
    raised => raised
  }
  assert_true(bad, msg="a non-numeric cost should raise")
  let bad_seconds = try {
    ignore(parse_args(["ui", "--max-seconds", "soon"]))
    false
  } catch {
    _ => true
  } noraise {
    raised => raised
  }
  assert_true(bad_seconds, msg="a non-numeric number of seconds should raise")
  let negative = try {
    ignore(parse_args(["ui", "--max-cost", "-1"]))
    false
  } catch {
    _ => true
  } noraise {
    raised => raised
  }
  assert_true(negative, msg="a negative cost should raise")
  let negative_seconds = try {
    ignore(parse_args(["ui", "--max-seconds", "-1"]))
    false
  } catch {
    _ => true
  } noraise {
    raised => raised
  }
  assert_true(negative_seconds, msg="a negative number of seconds should raise")
}

// ── the model, per session ─────────────────────────────────────────────────

///|
/// A bare `/model` reports rather than switching, and says what there is to switch to.
test "a model command reports the session's model and the alternatives" {
  match parse_command("/model") {
    Some(Model(value)) => assert_eq(value, "")
    _ => fail("expected a command")
  }
  match parse_command("/model   deepseek-v4-pro  ") {
    Some(Model(value)) => assert_eq(value, "deepseek-v4-pro")
    _ => fail("expected a command")
  }
  // Not a command: an id is prose until the `/model` prefix says otherwise, and these would
  // otherwise be swallowed.
  for
    text in [
      "/models", "/modeldeepseek", "/tmp/model is broken", "what is 1/model?",
    ] {
    assert_true(
      parse_command(text) is None,
      msg="\{text} should not be a command",
    )
  }
  let runner = runner_at("/store/a.jsonl", 0)
  let report = report_model(runner)
  assert_true(report.contains("deepseek-v4-flash"), msg=report)
  // Every alternative is named, because the reader asking is usually one who cannot remember an id.
  for id in @core.model_ids() {
    assert_true(report.contains(id), msg=report)
  }
}

///|
/// A session's model comes from its own log, so resuming one does not quietly change what it runs
/// on — and a new session takes the flag it was started with.
test "a session's model is read from its log, and a new one takes the flag" {
  let fresh = runner_at("/store/new.jsonl", 0)
  assert_eq(fresh.model_id, "deepseek-v4-flash", msg="the catalog default")
  // A session whose log recorded the pro model comes back on it, even though this process
  // defaults to flash.
  let session = session_with(1)
  let entry = @core.model_change_entry("deepseek", "deepseek-v4-pro", None, 0L)
  let opened = @core.Session::new(session.header, [entry])
  let resumed = Runner::new(opened, "/store/old.jsonl", "deepseek-v4-flash")
  assert_eq(resumed.model_id, "deepseek-v4-pro")
  // A process pointed at another default gives it to a session that recorded nothing. An empty
  // session, because an assistant message is itself a record of the model that produced it — a
  // session whose one reply came from flash is on flash however the process was started.
  let empty = runner_at("/store/flag.jsonl", 0)
  assert_eq(empty.model_id, "deepseek-v4-flash")
  let session_no_entries = session_with(0)
  let pointed = Runner::new(
    session_no_entries, "/store/flag.jsonl", "deepseek-v4-pro",
  )
  assert_eq(pointed.model_id, "deepseek-v4-pro")
  // A session with a reply on flash reads back as flash even when the process default is pro:
  // the log is the record, and the flag only decides what a *new* session starts on.
  let answered = Runner::new(
    session, "/store/answered.jsonl", "deepseek-v4-pro",
  )
  assert_eq(answered.model_id, "deepseek-v4-flash")
}

///|
/// Switching writes a `model_change` entry and adopts it, so the choice survives a restart and
/// the next turn cannot be billed at the old model's rates.
async test "switching a model appends the entry and takes effect" {
  let home = "_build/app_model_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let app = test_app_in(home)
  let shown = runner_at("\{home}/session.jsonl", 0)
  app.registry.push(shown)
  app.displayed = shown.path
  set_session_model(shown, "deepseek-v4-pro")
  assert_eq(shown.model_id, "deepseek-v4-pro")
  assert_true(shown.status.contains("V4 Pro"), msg=shown.status)
  // The entry is in the in-memory session, which is what stops the next turn's `run_turn` from
  // appending a second, contradictory one.
  assert_eq(shown.session.context().model.unwrap().model_id, "deepseek-v4-pro")
  // And on disk, which is what makes it survive the process.
  let reloaded = @platform.load_session(shown.path)
  assert_eq(reloaded.context().model.unwrap().model_id, "deepseek-v4-pro")
  // The picker now shows it, so the control and the session agree.
  assert_eq(model_picker(app, shown).current_id, "deepseek-v4-pro")
}

///|
/// A session whose log names a model this build does not have is still usable, still shows the id
/// its log recorded, and offers the models that exist — rather than silently claiming to run
/// something else.
test "an unknown model in the log is offered back, not hidden" {
  let app = test_app()
  let shown = runner_at("/store/a.jsonl", 0)
  shown.model_id = "deepseek-v9-someday"
  let picker = model_picker(app, shown)
  assert_eq(picker.current_id, "deepseek-v9-someday")
  assert_true(picker.models.length() > @core.model_catalog().length())
  assert_eq(picker.models[0].id, "deepseek-v9-someday")
  // The chip reports the id the log holds, and the fallback is not hidden from the tooltip path.
  let report = report_model(shown)
  assert_true(report.contains("unknown to this build"), msg=report)
}

///|
/// The picker is disabled while a turn runs: the entry would be appended off the turn's own leaf.
test "a running turn locks the picker" {
  let app = test_app()
  let runner = runner_at("/store/a.jsonl", 0)
  assert_false(model_picker(app, runner).locked)
  runner.busy = true
  assert_true(model_picker(app, runner).locked)
  runner.busy = false
  runner.waiting = 1
  assert_true(
    model_picker(app, runner).locked,
    msg="a queued prompt is work in flight",
  )
}

///|
/// A session whose last turn was stopped says so when it is opened again.
///
/// The transcript cannot answer this: a conversation stopped at the cost limit and one that
/// finished both end with a message. After a restart the status line is the only place left that
/// knows, which is why the reason is written to the log rather than kept in memory.
test "opening a session reports why its last turn ended" {
  let cwd = "/work/repo"
  let ending = @core.turn_outcome_entry(@core.CostLimit, 79, 1.25, None, 0L)
  let header : @core.SessionHeader = {
    id: "s",
    timestamp: @core.format_iso_utc(0L),
    cwd,
    parent_session: None,
    version: Some(3),
  }
  let session = @core.Session::new(header, [
    {
      id: "u1",
      parent_id: None,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.Message(
        message=@core.User({ content: [@core.Text("hello")], timestamp: 0L, }),
      ),
    },
    ending,
  ])
  let runner = Runner::new(session, "/store/s.jsonl", "deepseek-v4-flash")
  assert_true(runner.status.contains("cost limit"), msg=runner.status)
  // A session with nothing unusual to report reads the way it always did.
  let plain = @core.Session::new(header, [
    {
      id: "u1",
      parent_id: None,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.Message(
        message=@core.User({ content: [@core.Text("hello")], timestamp: 0L, }),
      ),
    },
  ])
  let quiet = Runner::new(plain, "/store/t.jsonl", "deepseek-v4-flash")
  assert_false(quiet.status.contains("limit"), msg=quiet.status)
}

///|
/// Switching a skill off works in a workspace whose skills have never been scanned.
///
/// This is the bug the browser check hit, and it is worth its own test because the failure is
/// silent and self-erasing: `ApplySkills` derives the new disabled list *from the catalog*, so an
/// unscanned workspace computes an empty list from an empty catalog, discards the reader's change,
/// and then renders a panel that loaded the catalog — showing the skill back on, with no error
/// anywhere. The workspace in this test is one no turn has run in, which is the normal state of a
/// directory that was just added.
async test "a skill can be switched off before any turn has run" {
  let home = "_build/app_skill_apply/\{@core.new_entry_id()}"
  @platform.make_dirs("\{home}/.wei/skills/demo")
  @platform.write_text(
    "\{home}/.wei/skills/demo/SKILL.md",
    "---\nname: demo\ndescription: A skill for tests.\n---\n",
  )
  let app = test_app_in(home)
  // A registry entry, because `app.shown()` is `registry[0]` when nothing is being displayed — and
  // an empty registry is an abort, not a failed assertion.
  let shown = runner_at("/tmp/store/a.jsonl", 1)
  app.display(shown)
  // Deliberately no `load_skills`: nothing has looked at this directory yet, which is exactly the
  // state the panel's Apply used to be reading.
  assert_eq(app.discovered_skills(shown.cwd).length(), 0)
  let message = apply_settings_post(app, shown, @core.ApplySkills(enabled=[]))
  // The change landed, and the message counts the catalog rather than an empty cache.
  assert_true(message.contains("0 skill(s) enabled"), msg=message)
  assert_eq(app.skills_for(shown.cwd).length(), 0)
  assert_eq(app.settings.disabled_skills, ["demo"])
  // The skill is still discoverable — switching it back on must not need the file to be found again.
  assert_eq(app.discovered_skills(shown.cwd).length(), 1)
}

///|
/// The `/` hints offer only the skills that are on.
///
/// A switched-off skill cannot be invoked, so listing it offers a command that does nothing — and
/// the reader has just switched it off, which makes the hint the one place the switch visibly did
/// not take.
async test "command hints list enabled skills only" {
  let home = "_build/app_hints_test/\{@core.new_entry_id()}"
  @platform.make_dirs("\{home}/.wei/skills/demo")
  @platform.write_text(
    "\{home}/.wei/skills/demo/SKILL.md",
    "---\nname: demo\ndescription: A skill for tests.\n---\n",
  )
  let app = test_app_in(home)
  let shown = runner_at("/tmp/store/a.jsonl", 1)
  app.display(shown)
  app.load_skills(shown.cwd)
  let insertions = () => {
    let out : Array[String] = []
    for hint in command_hints(app, shown) {
      out.push(hint.insert)
    }
    out
  }
  assert_true(insertions().contains("/skill:demo "), msg=insertions().join(","))
  app.settings = app.settings.with_skill_enabled("demo", false)
  assert_false(
    insertions().contains("/skill:demo "),
    msg=insertions().join(","),
  )
  // The commands that are not skills are always there: this filters the catalog, not the list.
  assert_true(insertions().contains("/name "))
  assert_true(insertions().contains("/model "))
}

///|
/// Switching the tool mode changes what the next turn is given, and what the prompt describes.
///
/// The pair is the whole point: the request carries a tool schema and a prompt that names the same
/// tools, and a mode that changed one of them would describe a tool the model does not have. The
/// prompt is built from the mode the turn read, not from a second read of the setting, so the two
/// cannot come from different values.
async test "a saved tool mode changes the tools and the prompt of the next turn" {
  let home = "_build/app_mode_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let app = test_app_in(home)
  let runner = runner_at("/store/a.jsonl", 0)
  // The default is the eight tools, and the prompt says so.
  assert_eq(app.tools().length(), 8)
  let before = app.system_prompt(runner)
  assert_true(before.contains("- read:"), msg=before)

  let message = apply_settings_post(
    app,
    runner,
    @core.SettingsPost::ApplyToolMode(mode="code"),
  )
  assert_true(message.contains("code mode"), msg=message)
  assert_true(message.contains("2 tools"), msg=message)
  // In force immediately for the next turn: two tools, and a prompt that no longer names the file
  // tools or tells the model to reach for them.
  assert_eq(app.tools().length(), 2)
  assert_eq(app.tools()[0].name, "exec")
  let after = app.system_prompt(runner)
  assert_true(after.contains("- exec:"), msg=after)
  assert_false(after.contains("- read:"), msg=after)
  assert_false(
    after.contains("For a single file, `read` is cheaper"),
    msg=after,
  )
  // Persisted, so a restart keeps it — and an unreadable value in the file is the default mode
  // rather than a broken process.
  assert_eq(@platform.load_settings(home).tool_mode, @core.ToolMode::Code)
  @platform.write_text(@platform.settings_path(home), "{\"tool_mode\":\"cod\"}")
  assert_eq(
    @platform.load_settings(home).tool_mode,
    @core.ToolMode::Tools,
    msg="an unknown mode reads as the default",
  )
  // And back, so the round trip is checked in both directions.
  ignore(
    apply_settings_post(
      app,
      runner,
      @core.SettingsPost::ApplyToolMode(mode="tools"),
    ),
  )
  assert_eq(app.tools().length(), 8)
  assert_eq(@platform.load_settings(home).tool_mode, @core.ToolMode::Tools)
}

///|
/// The prompt tells the next turn when the conversation it is continuing used other tools.
///
/// This is the measured failure: a session that ran in tools mode, resumed into code mode, emitted
/// `bash` 165 times in one turn — its own history was full of `bash` — while a fresh session in the
/// same mode reached for `exec` on the first call. The section is derived from the conversation the
/// model can see, so a session that switched modes is told, and one that never switched sends
/// exactly the bytes it sent before this existed (the prompt is the cache prefix, and a section that
/// always fired would invalidate every session on upgrade).
async test "a session that used another mode's tools is told so in the prompt" {
  let home = "_build/app_mode_prompt_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let app = test_app_in(home)
  // A conversation with two `bash` calls in it, as a tools-mode session would have.
  let entries : Array[@core.Entry] = [
    {
      id: "e1",
      parent_id: None,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.Message(
        message=@core.Assistant({
          content: [
            @core.ToolCall(
              id="c1",
              name="bash",
              arguments=Json::object(Map([])),
            ),
          ],
          api: "openai-completions",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          usage: @core.Usage::zero(),
          stop_reason: @core.ToolUse,
          timestamp: 0L,
          response_id: (None : String?),
          response_model: (None : String?),
          raw_stop_reason: (None : String?),
          error_message: (None : String?),
        }),
      ),
    },
  ]
  let header : @core.SessionHeader = {
    id: "s",
    timestamp: @core.format_iso_utc(0L),
    cwd: "/work/one",
    parent_session: None,
    version: Some(3),
  }
  let runner = Runner::new(
    @core.Session::new(header, entries),
    "/store/a.jsonl",
    @core.default_model_id(),
  )
  app.display(runner)
  // In tools mode the prompt names `bash` and says nothing about a change.
  let tools_prompt = app.system_prompt(runner, mode=@core.ToolMode::Tools)
  assert_true(tools_prompt.contains("- bash:"), msg=tools_prompt)
  assert_false(tools_prompt.contains("## Tools changed"), msg=tools_prompt)
  // In code mode it names `exec`, and it says what became of the `bash` calls already in the
  // conversation — including where the command goes now.
  let code_prompt = app.system_prompt(runner, mode=@core.ToolMode::Code)
  assert_true(code_prompt.contains("- exec:"), msg=code_prompt)
  assert_true(code_prompt.contains("## Tools changed"), msg=code_prompt)
  assert_true(
    code_prompt.contains("Earlier calls in this conversation used `bash`"),
    msg=code_prompt,
  )
  assert_true(code_prompt.contains("`exec`'s `bash` field"), msg=code_prompt)
  // It is the last section: nothing but the change notice follows it.
  let change = code_prompt.find("## Tools changed").unwrap()
  assert_false(code_prompt[change:].contains("## Workspace"), msg=code_prompt)
  // And the two halves of one turn agree: the same mode builds the schema, so the tools the prompt
  // names are the tools the request carries.
  assert_eq(@core.tools_for_mode(@core.ToolMode::Code).length(), 2)
}
