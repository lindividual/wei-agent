///|
/// The HTTP surface, tested where it now lives.
///
/// These cross the same seam the server does. A refusal *is* a frame, so the harness subscribes to
/// the hub the way a tab does and asserts on what was broadcast. That is the whole reason this
/// module exists: these five strings used to sit inside closures inside `main`, where nothing could
/// reach them, and the one defect this refactor was chosen for — the model picker not being put
/// back after a refused switch — was invisible to every test in the repository.
///
/// The spawn is a parameter, so a test can see exactly what would have become a turn without
/// starting one. Everything else is the real `App`, the real registry and the real hub.

///|
/// A `Requests` with something to read and something to observe.
struct Harness {
  requests : Requests
  /// The frames a connected tab would receive.
  frames : @aqueue.Queue[String]
  /// The prompts handed to the turn spawner, in order.
  sent : Array[String]
  /// Each call to the resume path, so a test can tell "continued" from "started".
  resumed : Array[Bool]
  /// The chooser's stand-in answer, writable so a test can change it between calls.
  chosen : Ref[@platform.FolderChoice?]
  /// The display queue nothing drains here, so a test can see what was asked for — and, for the
  /// cases where nothing should have been, that nothing was.
  displays : @aqueue.Queue[Job]
  /// The session on screen.
  shown : Runner
  app : App
}

///|
/// The store lives under the scratch home rather than at `test_app_in`'s `/tmp/store`, because
/// these tests open real sessions: the display path asks the filesystem whether a path is there, and
/// a made-up path would exercise the wrong branch.
///
/// The session is written to disk before the harness returns, so `Switch` to it takes the
/// already-open branch — which is the one a reader with a running turn depends on.
async fn harness_in(home : String) -> Harness {
  harness_with(home, false)
}

///|
/// The same harness on a host that can open a folder chooser.
///
/// A fact about the host rather than about a request, so it is a parameter of construction: what
/// depends on it is which controls the sidebar draws, and that is decided when the page is built.
async fn harness_with(home : String, can_pick : Bool) -> Harness {
  let app : App = { ..test_app_in(home), root: "\{home}/store", can_pick, }
  @platform.make_dirs(app.root)
  let (session, path) = create_session(app.root, "/work/one")
  @platform.ensure_session(path, session.header)
  let shown = Runner::new(session, path, @core.default_model_id())
  app.registry.push(shown)
  app.displayed = shown.path
  let (_, frames) = app.hub.subscribe()
  let sent : Array[String] = []
  let resumed : Array[Bool] = []
  // What the folder chooser will answer when the picker route is taken. `None` is a reader who
  // closed the dialog, which is the quiet case and the right default.
  let chosen : Ref[@platform.FolderChoice?] = Ref(None)
  // The displays queue is real but nothing reads it here: what a queued display change *means* is
  // `apply_display`, which the tests below call directly. What the queue itself is asserted on is
  // that a request asked for the right one — a job that never reaches it never happens.
  let displays : @aqueue.Queue[Job] = @aqueue.Queue(
    kind=@aqueue.Kind::Unbounded,
  )
  let requests = Requests::new(
    app,
    displays,
    (runner, text) => {
      ignore(runner)
      sent.push(text)
    },
    runner => {
      ignore(runner)
      resumed.push(true)
    },
    // No dialog in a test run: the harness answers with whatever the test set.
    () => {
      match chosen.val {
        Some(choice) => choice
        None => @platform.FolderChoice::Cancelled
      }
    },
  )
  { requests, frames, sent, resumed, chosen, displays, shown, app, }
}

///|
/// The next queued display change, or `None` when nothing was asked for.
fn Harness::next_job(self : Harness) -> Job? {
  try self.displays.try_get() catch {
    _ => None
  } noraise {
    job => job
  }
}

///|
async fn harness() -> Harness {
  harness_in("_build/requests_test/\{@core.new_entry_id()}")
}

///|
/// Take the frames broadcast so far.
fn Harness::take(self : Harness) -> Array[String] {
  let out : Array[String] = []
  let mut next = try self.frames.try_get() catch {
    _ => None
  } noraise {
    value => value
  }
  while next is Some(frame) {
    out.push(frame)
    next = try self.frames.try_get() catch {
      _ => None
    } noraise {
      value => value
    }
  }
  out
}

///|
/// Everything broadcast so far, as one string.
///
/// For assertions about *what the reader was told*, which is the unit these tests care about: that a
/// particular sentence reached the status line. Frames are individually visible through `take` for
/// the cases where the shape of the frame matters.
fn Harness::text(self : Harness) -> String {
  self.take().join("\n")
}

///|
/// How many of these frames replace the picker. A count rather than a `contains` because "the
/// picker was put back" and "the picker was put back twice" are different bugs.
fn times_targeting(frames : Array[String], target : String) -> Int {
  let wanted = "\"target\":\"" + target + "\""
  let mut count = 0
  for frame in frames {
    if frame.contains(wanted) {
      count += 1
    }
  }
  count
}

// ── the refusals ───────────────────────────────────────────────────────────

///|
/// The defect this refactor was chosen for.
///
/// A refused switch leaves the `<select>` on whatever the reader clicked, because the browser moved
/// it before the request was sent. Both ways in — the picker and `/model` — must put it back, and
/// before this module existed only the picker did: the command path left a stale control for the
/// next click to disagree with.
async test "a refused model change puts the picker back, from both ways in" {
  let h = harness()
  h.shown.busy = true
  h.requests.change_model("deepseek-v4-pro")
  let from_picker = h.take()
  assert_eq(times_targeting(from_picker, "model-picker"), 1)
  assert_true(
    from_picker
    .join("\n")
    .contains("cannot change the model while a turn is running"),
    msg=from_picker.join("\n"),
  )
  // The same refusal through the composer, which is the path that used to skip it.
  h.shown.busy = true
  h.requests.accept("/model deepseek-v4-pro")
  let from_command = h.take()
  assert_eq(
    times_targeting(from_command, "model-picker"),
    1,
    msg="the command path did not put the picker back: \{from_command.join("\n")}",
  )
}

///|
/// An id this build does not have is refused with the alternatives, rather than forwarded for the
/// provider to reject a turn later — and the picker goes back, because the reader may have reached
/// it through the control rather than by typing.
async test "an unknown model is refused by name, with what there is" {
  let h = harness()
  h.requests.change_model("gpt-9")
  // Drained once: `text` and `take` consume the same queue, so asserting through both would leave
  // the second assertion looking at nothing.
  let frames = h.take()
  let text = frames.join("\n")
  assert_true(text.contains("no such model: gpt-9"), msg=text)
  for id in @core.model_ids() {
    assert_true(text.contains(id), msg="\{id} missing from the list: \{text}")
  }
  assert_eq(times_targeting(frames, "model-picker"), 1)
  // Refused, so nothing was started and no entry was written.
  assert_eq(h.sent.length(), 0)
  assert_eq(h.shown.model_id, "deepseek-v4-flash")
}

///|
async test "a running turn refuses a rename and a model change alike" {
  let h = harness()
  h.shown.busy = true
  h.requests.accept("/name refactor auth")
  let text = h.text()
  assert_true(text.contains("cannot rename while a turn is running"), msg=text)
  // The name was not written, and the reader was told why.
  assert_eq(h.shown.session.name(), None)
}

///|
/// A no-op is not a refusal: clicking the option already selected must say nothing and write
/// nothing, or every stray click would append a log entry.
async test "choosing the model already in use is silent" {
  let h = harness()
  h.requests.change_model("deepseek-v4-flash")
  assert_eq(h.text(), "")
  assert_eq(h.shown.model_id, "deepseek-v4-flash")
}

///|
async test "a bare /model and a bare /name report rather than clear" {
  let h = harness()
  h.requests.accept("/model")
  let text = h.text()
  assert_true(text.contains("model: DeepSeek V4 Flash"), msg=text)
  assert_true(text.contains("available:"), msg=text)
  h.requests.accept("/name")
  assert_true(
    h.text().contains("no name"),
    msg="a bare command reports, never clears",
  )
}

///|
async test "an unrecognized settings form is said out loud" {
  let h = harness()
  h.requests.apply_settings("prompt=hello")
  assert_true(h.text().contains("unrecognized settings form"))
}

///|
async test "a workspace path that is not a directory says which one" {
  let h = harness()
  h.requests.add_workspace("/nope/not/a/directory")
  assert_true(h.text().contains("not a directory: /nope/not/a/directory"))
}

///|
/// A picked folder is queued as a workspace, exactly as a typed path is.
///
/// This is the half of the dialog the browser cannot see: it posts and gets nothing back, so what
/// happens next has to be produced here. Both routes have to reach the *same* queue entry — a
/// second way of adding a workspace is a second thing to keep true.
async test "a chosen folder and a typed path ask for the same thing" {
  let home = "_build/requests_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let h = harness_in(home)
  let project = "\{home}/project"
  @platform.make_dirs(project)
  // The chooser hands back an absolute path, and `canonical_dir` resolves it — through a symlink
  // on macOS — so the assertion is against the same resolution the code does, not the spelling.
  let resolved = match @platform.canonical_dir(project) {
    Some(path) => path
    None => fail("the scratch directory must resolve")
  }
  h.chosen.val = Some(@platform.FolderChoice::Chosen(project))
  h.requests.choose_workspace()
  assert_eq(h.next_job(), Some(Workspace(resolved)))
  h.requests.add_workspace(project)
  assert_eq(h.next_job(), Some(Workspace(resolved)))
  // Nothing was said at either step: the confirmation belongs to the job, which is where the
  // workspace is actually written and the session actually opened.
  assert_eq(h.text(), "")
}

///|
/// The queued job is what writes the workspace and opens the session in it.
///
/// The assertion is on the whole reader-visible effect rather than on the call: the directory is in
/// the store (so the row survives a restart), that session is on screen, and the status line names
/// the folder — because the sidebar row shows one path component of a path the reader may not have
/// read carefully.
async test "a queued workspace is written, opened, and named" {
  let home = "_build/requests_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let h = harness_in(home)
  let project = "\{home}/project"
  @platform.make_dirs(project)
  let resolved = match @platform.canonical_dir(project) {
    Some(path) => path
    None => fail("the scratch directory must resolve")
  }
  h.requests.apply_display(Workspace(resolved))
  assert_eq(h.app.shown().cwd, resolved)
  assert_true(
    h.app.shown().path != h.shown.path,
    msg="the old session stayed on screen",
  )
  assert_true(
    h.app.shown().status.contains("workspace added: \{resolved}"),
    msg=h.app.shown().status,
  )
  let listed = @platform.list_workspaces(h.app.root)
  assert_eq(listed.length(), 2, msg="the workspace was not stored")
  // And the regions went out, so a tab showing the old session follows.
  assert_true(h.text().contains("\"target\":\"sessions\""), msg=h.text())
}

///|
/// A closed dialog says nothing at all, and asks for nothing.
///
/// The reader who changed their mind has already been answered by the dialog going away; a status
/// line telling them nothing happened would be the page arguing with them, and a queued workspace
/// would add a directory they just declined.
async test "a closed chooser is silent" {
  let h = harness()
  h.chosen.val = Some(@platform.FolderChoice::Cancelled)
  h.requests.choose_workspace()
  assert_eq(h.text(), "")
  assert_true(h.next_job() is None)
}

///|
/// A host that cannot open a dialog says why, because the path field beside the button is only a
/// useful answer if the reader is told the button could not be used.
async test "a chooser that could not open says why" {
  let h = harness()
  h.chosen.val = Some(
    @platform.FolderChoice::Unavailable(
      "no folder chooser on this host — type a path instead",
    ),
  )
  h.requests.choose_workspace()
  assert_true(h.text().contains("no folder chooser on this host"), msg=h.text())
  assert_true(h.next_job() is None)
}

///|
/// A directory that is gone by the time the answer arrives is refused like any other path, rather
/// than opened as a workspace that does not exist.
async test "a picked folder that is no longer there says which" {
  let home = "_build/requests_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let h = harness_in(home)
  let gone = "\{home}/was-there"
  h.chosen.val = Some(@platform.FolderChoice::Chosen(gone))
  h.requests.choose_workspace()
  assert_true(h.text().contains("not a directory: \{gone}"), msg=h.text())
  assert_true(h.next_job() is None)
}

// ── the input path ─────────────────────────────────────────────────────────

///|
/// A message becomes a turn, and the session is marked as waiting for it before the spawn — which is
/// what lets a reader see a queued prompt without racing the turn's own decrement.
async test "a message is counted, then handed to the turn spawner" {
  let h = harness()
  h.requests.accept("hello")
  assert_eq(h.sent, ["hello"])
  assert_eq(h.shown.waiting, 1)
  // Verbatim: nothing is prepended, appended or rewritten on the way through.
  h.requests.accept("  spaced  ")
  assert_eq(h.sent[1], "  spaced  ")
}

///|
async test "a message behind a running turn says so, and stays scoped to its session" {
  let h = harness()
  h.shown.busy = true
  h.requests.accept("second question")
  assert_eq(h.sent, ["second question"])
  assert_eq(h.shown.waiting, 1)
  let text = h.text()
  assert_true(text.contains("queued behind the running turn"), msg=text)
  // Scoped, because every other tab showing a different session must not be told about this one's
  // queue — that is what the frame tag is for.
  assert_true(text.contains("session"), msg=text)
}

///|
/// A `/skill:<name>` naming a skill this session can see is expanded before it reaches the spawner,
/// and one that does not resolve is passed through as typed.
async test "a skill command is expanded on the way to the turn" {
  let home = "_build/requests_test/\{@core.new_entry_id()}"
  @platform.make_dirs("\{home}/.pi/agent/skills/demo")
  @platform.write_text(
    "\{home}/.pi/agent/skills/demo/SKILL.md",
    "---\nname: demo\ndescription: A skill for tests.\n---\n\nBody text here.\n",
  )
  let h = harness_in(home)
  h.requests.accept("/skill:demo do the thing")
  assert_eq(h.sent.length(), 1)
  let expanded = h.sent[0]
  assert_true(expanded.contains("Body text here."), msg=expanded)
  assert_true(expanded.contains("name=\"demo\""), msg=expanded)
  assert_true(expanded.has_suffix("do the thing"), msg=expanded)
  // The frontmatter is gone: it is what the catalog already read.
  assert_false(expanded.contains("description:"), msg=expanded)
  // An unknown name is a message, not an error, and not a lost question.
  h.requests.accept("/skill:not-a-skill hello")
  assert_eq(h.sent[1], "/skill:not-a-skill hello")
}

// ── the two views of the page ──────────────────────────────────────────────

///|
/// `page` and `regions` are two renderings of one state, and the failure mode of keeping them apart
/// is silent: a region present in the first frame but not in the snapshot works until the browser
/// reconnects, and then stops.
///
/// This is the test that keeps them together, and it is why both live in this module.
async test "every region the snapshot replaces exists in the page" {
  let h = harness()
  let page = h.requests.page()
  let patches = h.requests.regions()
  let targets : Array[String] = []
  for patch in patches {
    match patch {
      @html.Replace(target~, ..) => {
        targets.push(target)
        let wanted = "id=\"" + target + "\""
        assert_true(
          page.contains(wanted),
          msg="\{target} is replaced but not in the page",
        )
      }
      _ => ()
    }
  }
  // Named rather than counted: "six replaces" would pass with the wrong six. Every repeatable
  // region is here, and the status line is the eighth frame.
  assert_eq(targets, [
    "transcript", "sessions", "tasks", "jobs", "bar", "model-picker", "stop",
  ])
  assert_eq(patches.length(), 8)
  match patches[7] {
    @html.Status(text~) =>
      assert_true(text != "", msg="the status line is empty")
    _ => fail("the last frame should be the status line")
  }
}

///|
/// One definition of the page: the initial document and a reconnecting tab's first frame are the
/// same state, so the composer appears once and the things a turn must not disturb are present.
async test "the page carries the composer and the picker exactly once" {
  let h = harness()
  let page = h.requests.page()
  for
    id in [
      "transcript", "sessions", "composer", "prompt", "send", "stop", "status", "model-picker",
      "bar", "tasks", "jobs",
    ] {
    let wanted = "id=\"" + id + "\""
    assert_eq(
      count_of(page, wanted),
      1,
      msg="\{wanted} appears \{count_of(page, wanted)} times",
    )
  }
  // The picker holds the session's model, not the process default's.
  assert_true(page.contains("value=\"deepseek-v4-flash\""), msg=page)
  // And no folder chooser, because this harness stands in for a host that cannot open one: the
  // button has to follow `App.can_pick` all the way out to the document, not merely be decided.
  // The *element*, not the string — the script that handles the click names the id either way.
  assert_false(page.contains("id=\"workspace-pick\""), msg=page)
}

///|
/// A host that *can* open a dialog offers the button, next to the path field it complements.
async test "a host with a chooser offers it in the sidebar" {
  let home = "_build/requests_test/\{@core.new_entry_id()}"
  @platform.make_dirs(home)
  let h = harness_with(home, true)
  let page = h.requests.page()
  assert_true(page.contains("id=\"workspace-pick\""), msg=page)
  // Both ways to add are still there: the chooser cannot serve a reader who is not at this machine,
  // and the field cannot serve one who does not know the path.
  assert_true(page.contains("id=\"workspace-path\""), msg=page)
}

// ── the queued display changes ─────────────────────────────────────────────

///|
/// A display change is applied by the worker, not by the route that asked for it, and the two
/// things that must survive are: an already-open session is displayed as it is (re-reading it would
/// throw away a running turn), and a path that is gone becomes a fresh session rather than nothing.
async test "a queued switch displays the session, and a missing path becomes a new one" {
  let home = "_build/requests_test/\{@core.new_entry_id()}"
  let h = harness_in(home)
  // The session that is already open.
  h.requests.apply_display(Switch(h.shown.path))
  assert_eq(h.app.displayed, h.shown.path)
  // A path nobody has, which is what a deleted file looks like.
  h.requests.apply_display(Switch("\{home}/gone.jsonl"))
  let after = h.app.shown()
  assert_true(after.path != h.shown.path, msg="a fresh session was not opened")
  assert_eq(
    after.cwd,
    h.shown.cwd,
    msg="it stays in the workspace being looked at",
  )
}

///|
async test "a display change refreshes the regions, so the reader sees the new session" {
  let h = harness()
  h.requests.apply_display(New("/work/two"))
  let text = h.text()
  assert_true(text.contains("\"target\":\"transcript\""), msg=text)
  assert_true(text.contains("\"target\":\"sessions\""), msg=text)
  // The picker comes with it, because a new session may be on a different model.
  assert_true(text.contains("\"target\":\"model-picker\""), msg=text)
  assert_eq(h.app.shown().cwd, "/work/two")
}

// ── The interrupted turn ───────────────────────────────────────────────────

///|
/// A session whose turn never finished is continued in place, not restarted.
///
/// This is the whole point of the two routes. "Continue" has to reach the resume path (which sends
/// no prompt, because the one in flight is already in the log); "start fresh" has to close the turn
/// so the notice stops coming back. If either went through the ordinary prompt path the question
/// would be appended a second time and the model would see it twice.
///
/// The log is the assertion in both cases: the status string is what the reader sees, but what
/// makes the notice disappear after a restart is the entry.
async test "an interrupted turn is continued without resending the prompt" {
  let h = interrupted_harness()
  h.requests.continue_turn("")
  // Reached the resume path, and did not send anything as a new prompt.
  assert_eq(h.resumed.length(), 1)
  assert_eq(h.sent.length(), 0)
}

///|
/// Starting fresh closes the turn in the log, which is what makes it stay closed.
///
/// A dismissal kept only in memory would bring the notice straight back on the next start, which is
/// the one moment it matters.
async test "starting fresh records the interrupted turn as abandoned" {
  let h = interrupted_harness()
  assert_true(h.shown.session.turn_in_flight())
  h.requests.dismiss_turn("")
  assert_false(h.shown.session.turn_in_flight())
  assert_eq(h.shown.session.last_turn_ending(), Some(@core.Abandoned))
  // And nothing was started: this is a decision not to run, not a run.
  assert_eq(h.resumed.length(), 0)
  assert_eq(h.sent.length(), 0)
}

///|
/// A click on a notice that is already answered says so instead of failing.
///
/// A notice is a piece of HTML that can be stale: another tab may have answered it, or the reader
/// may have typed a new message, which abandons the turn. Both routes check rather than trusting
/// the click, because the honest answer is a sentence.
async test "answering an already-ended turn is refused with a sentence" {
  let h = harness()
  assert_false(h.shown.session.turn_in_flight())
  h.requests.continue_turn("")
  assert_eq(h.resumed.length(), 0)
  assert_true(h.text().contains("already ended"), msg=h.text())
}

///|
/// A session that is working does not continue an interrupted turn underneath itself.
///
/// One turn at a time per session is the invariant the whole design rests on; resuming into a
/// running turn would put two writers on one log.
async test "a running session refuses to continue an interrupted turn" {
  let h = interrupted_harness()
  h.shown.busy = true
  h.requests.continue_turn("")
  assert_eq(h.resumed.length(), 0)
  assert_true(h.text().contains("already working"), msg=h.text())
}

///|
/// A harness whose session has an open turn: the state a crash leaves behind.
async fn interrupted_harness() -> Harness {
  let h = harness()
  let entry = @core.turn_start_entry(
    "build the thing",
    h.shown.session.leaf_id,
    @env.now().reinterpret_as_int64(),
  )
  @platform.append_entry(h.shown.path, entry)
  h.shown.session = h.shown.session.add_entries([entry])
  h
}

///|
/// Naming a session that has no file yet writes the header with the name.
///
/// A session is created empty and its file appears with the first entry — which is what keeps a
/// store from filling up with header-only files. The catch is that naming is something a reader does
/// *before* the first prompt as often as after one, and an append to a path whose directory does not
/// exist writes nothing while reporting nothing: the route has already answered, so a failure here
/// is invisible. The name simply did not stick, and nothing said so.
async test "renaming a session with no file yet writes one" {
  let h = harness()
  // A session that has never been written, in a directory that does not exist either: the path
  // exists in the registry and nowhere on disk. That is the state of every session between opening
  // it and the first prompt, and the state this was broken in.
  let (fresh, path) = create_session(h.app.root, "/work/fresh")
  let runner = Runner::new(fresh, path, @core.default_model_id())
  h.app.display(runner)
  assert_false(
    @platform.path_exists(path),
    msg="the fixture should start with no file",
  )
  h.requests.rename("deploy triage")
  assert_true(
    @platform.path_exists(path),
    msg="naming a fresh session must leave a log behind",
  )
  assert_eq(runner.session.name(), Some("deploy triage"))
  let written = @platform.read_text(path)
  assert_true(written.contains("deploy triage"), msg=written)
  // The header went in first. `create_session` is what makes the directory, and without it the
  // entry lands alone in a file whose first line is not a header — a log that cannot be loaded.
  assert_true(written.contains("\"session\""), msg=written)
}

// ── deleting a session ─────────────────────────────────────────────────────

///|
/// A session with a turn in flight is not deleted out from under it.
///
/// The turn would keep appending to a name nothing lists, and the reader would have no row to stop
/// it from. Same shape as the rename guard, for the same reason.
async test "a running turn refuses a delete" {
  let h = harness()
  h.shown.busy = true
  h.requests.delete(h.shown.path)
  let text = h.text()
  assert_true(
    text.contains("cannot delete a session while a turn is running"),
    msg=text,
  )
  assert_true(
    @platform.path_exists(h.shown.path),
    msg="nothing should have moved",
  )
}

///|
/// A session with a live background job is kept, because the job is what would be orphaned: it
/// would go on running with no row anywhere to find it from.
async test "a live background job refuses a delete" {
  let h = harness()
  ignore(
    h.app.jobs.start(
      kind="bash",
      label="sleep 300",
      session=h.shown.path,
      started_at=@env.now().reinterpret_as_int64(),
      pids=[4242],
    ),
  )
  h.requests.delete(h.shown.path)
  let text = h.text()
  assert_true(
    text.contains("cannot delete a session with a background job still running"),
    msg=text,
  )
  assert_true(
    @platform.path_exists(h.shown.path),
    msg="nothing should have moved",
  )
}

///|
/// A workspace with more sessions than the sidebar shows offers the rest, and taking the offer
/// lists them.
///
/// The cap is what keeps opening a page from replaying a store, and the offer is what keeps the cap
/// from being a dead end: before this, a session past the tenth in its workspace was unreachable
/// from the UI — the sidebar said it existed and nothing on the page could open it.
async test "a workspace offers the sessions past its cap, and lists them when asked" {
  let h = harness()
  let cwd = h.shown.cwd
  // Twelve more beside the one the harness opened: thirteen, of which the cap shows ten.
  for i in 0..<12 {
    let (session, path) = create_session(h.app.root, cwd)
    @platform.ensure_session(path, session.header)
    ignore(i)
  }
  let capped = h.requests.page()
  assert_eq(count_of(capped, "data-session="), 10)
  assert_true(capped.contains("Show 3 more"), msg=capped)
  // Matched with the `=` on it: the client script carries the bare selector `[data-more]`, so a
  // search for the word alone passes whether or not the button is there.
  assert_eq(count_of(capped, "data-more=\""), 1)
  // Nothing was said out loud, and no region moved: browsing is not an event.
  assert_eq(h.text(), "")
  // Asking for the rest is a request, not a page-local trick — the list belongs to the server, and
  // a reader in a second tab has to get the same answer.
  h.requests.more(cwd)
  assert_eq(h.app.expanded.get(cwd), Some(true), msg="the flag was not set")
  let listed = h.requests.page()
  assert_eq(count_of(listed, "data-session="), 13)
  assert_eq(count_of(listed, "data-more=\""), 0)
  // The region went out, so a tab already showing the folded list follows along.
  assert_true(h.text().contains("\"target\":\"sessions\""), msg=h.text())
}

///|
/// Deleting the session on screen is allowed, and the page moves to another one.
///
/// Refusing it would have been smaller, but "you cannot delete this one, switch first" is a rule
/// the reader learns for no benefit — the page can show something else.
async test "deleting the session on screen moves the display instead of refusing" {
  let h = harness()
  let (other, other_path) = create_session(h.app.root, "/work/one")
  @platform.ensure_session(other_path, other.header)
  h.app.registry.push(Runner::new(other, other_path, @core.default_model_id()))
  let doomed = h.shown.path
  h.requests.delete(doomed)
  assert_false(
    @platform.path_exists(doomed),
    msg="the session on screen should have been deleted",
  )
  assert_true(
    h.app.displayed != doomed,
    msg="the display must move off a path that no longer exists",
  )
  assert_true(@platform.path_exists(h.app.displayed), msg=h.app.displayed)
}

///|
/// Undo puts it back, and the offer does not outlive the click.
async test "undo restores the session and clears the offer" {
  let h = harness()
  let doomed = h.shown.path
  h.requests.delete(doomed)
  assert_true(h.app.deleted is Some(_), msg="the offer should be up")
  h.requests.undo_delete(doomed)
  assert_true(@platform.path_exists(doomed), msg="undo should restore the file")
  assert_true(h.app.deleted is None, msg="a used offer should be gone")
}

///|
/// Deleting the last session in a workspace must not leave it on screen.
///
/// This is the case that was broken, and it is broken in a way that only shows up in the empty
/// workspace: the replacement is chosen *before* the file moves — deliberately, so the registry is
/// never empty when `shown()` looks at it — and asking the store for "the newest session here" at
/// that moment hands back the session being deleted, because it is still the newest file. The page
/// then keeps rendering it, and goes on rendering it after a reload, since the runner stays in
/// memory. With a second session in the same workspace the store returns that one instead, which is
/// why an ordinary test does not catch it.
async test "deleting the only session in a workspace does not leave it on screen" {
  let h = harness()
  // Nothing else in this workspace: the registry's only other runner is in a different cwd, and the
  // store has exactly one file.
  let doomed = h.shown.path
  h.requests.delete(doomed)
  assert_false(@platform.path_exists(doomed), msg="the file should be gone")
  let shown = h.app.shown()
  assert_true(
    shown.path != doomed,
    msg="the page must not still be showing the deleted session",
  )
  assert_true(
    @platform.path_exists(shown.path) || shown.session.entries.is_empty(),
    msg="the replacement must be a real session or a fresh one: \{shown.path}",
  )
}

// ── the tag a client matches against ───────────────────────────────────────

///|
/// Every scoped frame must be tagged with the id the transcript advertises.
///
/// The client decides whether a frame is for the page it is showing with one string comparison:
/// `frame.session === transcript.dataset.shownSession`. The transcript's tag is a *short id* — the
/// 8-character one, not the path — so a scoped frame tagged with anything else is not "sometimes
/// applied": it is dropped, always, silently, forever, and the only way to notice is that some
/// corner of the page never changes.
///
/// That is exactly what happened. Two frames were tagged with the full path — the sidebar's update
/// to the *displayed* session's status line, and the "queued behind the running turn" notice — so
/// the first left "1 other session(s) running" on screen after the other session had finished, and
/// the second never appeared at all. A refresh hid it, because a reload does not go through the tag.
///
/// This is the test that was missing: the frames and the page were asserted separately, each
/// internally consistent, and nothing compared them to each other.
async test "scoped frames carry the tag the transcript advertises" {
  let h = harness()
  let page = h.requests.page()
  // The prefix length is taken from the prefix itself rather than written as a number: an
  // off-by-one here reads as "the server tagged it differently", which is the opposite of the
  // truth and sends the next reader into the wrong file.
  let prefix = "data-shown-session=\""
  let advertised = match page.find(prefix) {
    Some(at) => {
      let rest = page[at + prefix.length():]
      match rest.find("\"") {
        Some(end) => rest[:end].to_owned()
        None => fail("unterminated data-shown-session: \{page}")
      }
    }
    None => fail("the page does not advertise a session tag")
  }
  // A queued prompt is the cheapest scoped frame to produce: no turn has to run.
  h.shown.busy = true
  h.requests.accept("a second question while the first is running")
  let frames = h.take()
  let mut scoped = 0
  for frame in frames {
    match frame.find("\"session\":\"") {
      Some(at) => {
        scoped += 1
        let rest = frame[at + 11:]
        let tagged = match rest.find("\"") {
          Some(end) => rest[:end].to_owned()
          None => fail("unterminated session tag: \{frame}")
        }
        assert_eq(
          tagged,
          advertised,
          msg="a scoped frame is tagged \{tagged}, but the client compares against \{advertised} — it would be dropped",
        )
      }
      None => ()
    }
  }
  assert_true(scoped > 0, msg="expected at least one scoped frame")
}
