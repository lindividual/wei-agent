///|
/// The HTTP surface: what each request means, and what the reader is told when one is refused.
///
/// Every route's decision lives here rather than inside `main`, for one reason: `main` cannot be
/// tested. It parses a command line, binds a port and blocks, so a decision written inside a
/// closure inside it has no interface — nothing can cross the seam to check it. The cost of that
/// was concrete rather than theoretical. Five of the six strings a reader sees when something is
/// refused appeared in exactly one file, the one with no tests, and the model picker failing to
/// unlock when a turn ended broke nothing at all: there was no interface for the state transition
/// to be asserted through.
///
/// What stays in `main` is what belongs to a *process* and not to a module: the task group a turn
/// is spawned into, the port, and the lifetime. `Requests` takes those as parameters — the spawn as
/// a callback, because the task group is generic over its own result type and carries a source
/// location, neither of which this module has any business knowing.
///
/// The seam these tests cross is `@server.Hub`. A refusal *is* a frame: asserting on the frames
/// broadcast is asserting on what the browser is told, which is the whole of that behaviour. So the
/// handlers broadcast rather than returning a description of what to broadcast, and the tests
/// subscribe the way a tab does.

///|
/// The routes, and the state their decisions are made from.
struct Requests {
  app : App
  /// Display changes go through a queue, so two clicks in quick succession happen in the order they
  /// were made rather than in the order their handlers happen to finish.
  displays : @aqueue.Queue[Job]
  /// Start a turn. Called only when the input was a message rather than a command, and only after
  /// the session has been marked as waiting for one.
  spawn : (Runner, String) -> Unit
  /// Run the interrupted turn that is already open, without a new prompt.
  ///
  /// Separate from `spawn` because it is not the same act: `spawn` starts a turn from a message the
  /// reader just typed, while this one continues a turn whose prompt is already in the log. The
  /// difference is exactly the two entries the driver skips, and it is why "Continue" cannot be
  /// spelled as re-sending the prompt.
  resume_turn : (Runner) -> Unit
  /// Open the host's folder chooser and wait for it.
  ///
  /// A parameter for the reason `spawn` is one: the real chooser is a dialog on somebody's screen,
  /// so the decision this file makes — which of the three answers adds a workspace, which one says
  /// something, which one says nothing — would have no interface to be asserted through.
  pick : async () -> @platform.FolderChoice
}

///|
fn Requests::new(
  app : App,
  displays : @aqueue.Queue[Job],
  spawn : (Runner, String) -> Unit,
  resume_turn : (Runner) -> Unit,
  pick : async () -> @platform.FolderChoice,
) -> Requests {
  { app, displays, spawn, resume_turn, pick, }
}

// ── telling the reader ─────────────────────────────────────────────────────

///|
/// Send one patch to every connected tab.
async fn Requests::tell(self : Requests, patch : @html.Patch) -> Unit {
  self.app.hub.broadcast(patch.to_sse())
}

///|
/// Say something on the status line.
///
/// Every refusal in this file goes through here, which is what makes them one set of strings with
/// one shape rather than six `broadcast(Patch::Status(...))` calls that happen to agree today.
async fn Requests::say(self : Requests, text : String) -> Unit {
  self.tell(@html.Patch::Status(text~))
}

///|
/// The regions that change: everything except the text the reader is typing, which no region owns.
async fn Requests::regions(self : Requests) -> Array[@html.Patch] {
  let app = self.app
  let shown = app.shown()
  let sidebar = workspace_items_and_render(app, shown)
  [
    @html.Patch::Replace(
      target="transcript",
      html=transcript_node(app, shown).render(),
    ),
    @html.Patch::Replace(target="sessions", html=sidebar),
    @html.Patch::Replace(target="tasks", html=render_tasks(app, shown)),
    @html.Patch::Replace(
      target="jobs",
      html=render_jobs(app, @env.now().reinterpret_as_int64()),
    ),
    // Which session is on screen changes when the reader switches, and the model picker that
    // shows it lives in the composer — so only the picker is replaced, never the form around it.
    // Replacing the form would take whatever the reader is in the middle of typing with it.
    @html.Patch::Replace(target="title", html=title_node(app, shown).render()),
    picker_patch(app, shown),
    // Stop follows the turn: live while one is running, disabled otherwise. Replaced on its own
    // for the same reason the picker is — rebuilding the composer would replace the textarea.
    stop_patch(shown),
    @html.Patch::Status(text=app.status_line(shown)),
  ]
}

///|
/// Push every region to every tab. What a display change and a model change both end with.
async fn Requests::refresh(self : Requests) -> Unit {
  for patch in self.regions() {
    self.tell(patch)
  }
}

///|
/// Re-render the picker from the session's actual model.
///
/// Needed whenever a model change was refused: the `<select>` has already moved to whatever the
/// reader clicked, and leaving it there shows a model the session does not have. Harmless on the
/// command path, where the picker never moved — which is why *both* refusals do it rather than only
/// the one that needed it, and why the two paths cannot drift apart again.
async fn Requests::put_picker_back(self : Requests, shown : Runner) -> Unit {
  self.tell(picker_patch(self.app, shown))
}

///|
/// Queue a display change, reporting whether it worked.
///
/// Not a broadcast, so not `tell`: the display worker is what reads this, and it is the one place
/// that re-renders afterwards.
fn Requests::show(self : Requests, job : Job) -> Unit {
  ignore(queue_try_put(self.displays, job))
}

// ── the composer ───────────────────────────────────────────────────────────

///|
/// Handle one line from the composer.
///
/// Three outcomes, and the last is what makes this worth a seam: a command is answered here, a
/// `/skill:<name>` naming a discoverable skill is expanded, and anything else goes to the model as
/// it was typed.
async fn Requests::accept(self : Requests, text : String) -> Unit {
  match parse_command(text) {
    Some(Name(value)) => {
      self.rename(value)
      return
    }
    Some(Model(value)) => {
      self.change_model(value)
      return
    }
    None => ()
  }
  let app = self.app
  let shown = app.shown()
  // A `/skill:<name>` naming a skill this session can see is expanded here rather than sent on; an
  // unknown name is left alone and goes to the model, which is what pi does and what keeps a stray
  // `/skill:` from eating a message.
  let to_send = match expand_skill_command(app, shown, text) {
    Some(expanded) => expanded
    None => text
  }
  // Counted before the spawn, because the turn decrements it on its way in: between here and the
  // spawn there is no suspension point, so the count a reader can see is never wrong.
  shown.waiting += 1
  if shown.busy {
    shown.status = "queued behind the running turn"
    self.app.hub.broadcast(
      @html.Patch::Status(text=shown.status).to_scoped_sse(
        session_tag(shown.path),
      ),
    )
  }
  (self.spawn)(shown, to_send)
}

///|
/// `/name <text>`, and `/name` alone, which reports rather than clears.
async fn Requests::rename(self : Requests, value : String) -> Unit {
  let app = self.app
  let shown = app.shown()
  if shown.is_running() {
    // Two writers on one log is the corruption this whole design avoids: the turn is appending
    // entries whose parent is its own leaf, and a rename appended now would hang off a stale one
    // and end up on a branch nobody walks.
    shown.status = "cannot rename while a turn is running"
    self.say(shown.status)
  } else if value == "" {
    // A bare command should not be able to throw away something the reader typed earlier.
    shown.status = match shown.session.name() {
      Some(name) => "name: \{name}"
      None => "this session has no name (use /name <text>)"
    }
    self.say(shown.status)
  } else {
    let entry = @core.session_name_entry(
      Some(value),
      shown.session.leaf_id,
      @env.now().reinterpret_as_int64(),
    )
    // The header goes in with the first entry, the same rule `set_session_model` and the driver's
    // `commit` follow. Naming a session is something a reader does *before* the first prompt as
    // often as after one — and a brand-new session has no file yet, so appending without this
    // writes nothing and, worse, reports nothing: the route has already answered, so the failure
    // goes nowhere a reader can see it. A name typed into an empty session simply did not stick.
    @platform.ensure_session(shown.path, shown.session.header)
    @platform.append_entry(shown.path, entry)
    shown.session = shown.session.add_entries([entry])
    shown.status = "named \{value}"
    // The sidebar row and the title line both change, and both are regions.
    self.refresh()
  }
}

///|
/// `/model <id>` and the picker both land here.
///
/// One function for the two ways in, which is the point of the seam: the guards are the same set of
/// decisions — is a turn running, is this the model already, does the id exist, what is the reader
/// told, what has to be re-rendered — and two copies of them had already drifted. The picker's
/// route put the control back after a refusal and the command's did not, so a mistyped `/model` left
/// a stale `<select>` behind for the next click to disagree with.
async fn Requests::change_model(self : Requests, id : String) -> Unit {
  let shown = self.app.shown()
  if shown.is_running() {
    // Same reason a rename is refused: a model change is an entry in the log, the running turn is
    // appending off its own leaf, and the turn it was meant for would keep using the old model
    // anyway.
    self.say("cannot change the model while a turn is running")
    self.put_picker_back(shown)
    return
  }
  if id == "" {
    // Bare: report, and list what there is. The reader asking is usually one who does not remember
    // an id, and a list costs nothing next to a failed call.
    self.say(report_model(shown))
    return
  }
  if !@core.is_known_model(id) {
    // Refused rather than forwarded: the id would go into the request as-is, and the provider's
    // rejection arrives a turn later with no hint as to which of the reader's two mistakes it was.
    self.say("no such model: \{id} · \{@core.model_ids().join(", ")}")
    self.put_picker_back(shown)
    return
  }
  if id == shown.model_id {
    // Nothing to do, and no log entry for a no-op: a `<select>` fires `change` on a click that
    // lands on the option already selected.
    return
  }
  set_session_model(shown, id)
  self.refresh()
}

// ── the panels ─────────────────────────────────────────────────────────────

///|
/// Stop a session's work: the turn, the command it is running, and the prompts not yet started.
async fn Requests::abort(self : Requests, path : String) -> Unit {
  let app = self.app
  // Empty means the session on screen, which is what the Stop button next to the composer sends.
  // A path names one, so a background turn can be ended without bringing it on screen first.
  let target = if path == "" {
    app.shown()
  } else {
    match app.runner(path) {
      Some(runner) => runner
      None => app.shown()
    }
  }
  target.stop()
  // The panel and the sidebar both change the moment a stop is asked for, rather than when the
  // turn finally notices.
  self.tell(
    @html.Patch::Replace(target="tasks", html=render_tasks(app, app.shown())),
  )
}

///|
/// Resume the interrupted turn, or close it without resuming.
///
/// Both are answers to the same notice, and both have to leave the log's invariant intact: at most
/// one turn open. Continuing leaves the turn open and runs it to a real ending; dismissing closes
/// it as abandoned. Neither sends a prompt, because the one in flight is already in the log —
/// re-sending it would append a second copy and the model would see the question twice.
async fn Requests::continue_turn(self : Requests, path : String) -> Unit {
  let app = self.app
  let target = if path == "" {
    app.shown()
  } else {
    match app.runner(path) {
      Some(runner) => runner
      None => app.shown()
    }
  }
  // The notice describes the past. Another tab may have answered it, or the reader may have typed a
  // new message and abandoned it that way. Checked here rather than in the driver, because the
  // honest answer to a click on a stale notice is a sentence, not a failed turn.
  if !target.session.turn_in_flight() {
    self.say("nothing to continue: that turn has already ended")
    self.refresh()
    return
  }
  if target.is_running() {
    self.say(
      "this session is already working; stop it first to continue the interrupted turn",
    )
    self.refresh()
    return
  }
  // Counted like a prompt, because it takes the same slot: one turn at a time per session.
  target.waiting += 1
  (self.resume_turn)(target)
}

///|
/// Close the interrupted turn without resuming it.
///
/// Writing an outcome rather than doing nothing is the whole point: a turn left open is one that
/// every later start will announce again, so "start fresh" has to be recorded to actually be fresh.
async fn Requests::dismiss_turn(self : Requests, path : String) -> Unit {
  let app = self.app
  let target = if path == "" {
    app.shown()
  } else {
    match app.runner(path) {
      Some(runner) => runner
      None => app.shown()
    }
  }
  if !target.session.turn_in_flight() {
    self.say("nothing to dismiss: that turn has already ended")
    self.refresh()
    return
  }
  target.dismiss()
  self.refresh()
}

///|
/// Stop a background job, by id.
async fn Requests::kill_job(self : Requests, id : String) -> Unit {
  let app = self.app
  // Ask, then insist: the status shows "stopping" until the processes are actually gone, which is
  // what tells a reader whether a process is ignoring SIGTERM.
  let pids = app.jobs.request_stop(id)
  ignore(@platform.kill_pids(pids))
  app.jobs.finish(
    id,
    @core.JobStatus::Killed,
    detail="stopped from the panel",
    finished_at=@env.now().reinterpret_as_int64(),
  )
  self.tell(
    @html.Patch::Replace(
      target="jobs",
      html=render_jobs(app, @env.now().reinterpret_as_int64()),
    ),
  )
}

///|
/// Add a directory as a workspace, and open a session in it.
///
/// The write and the session are the queued job, not this function: a workspace can arrive from a
/// typed path or from a dialog, and both have to land in the order they were asked for.
async fn Requests::add_workspace(self : Requests, path : String) -> Unit {
  match @platform.canonical_dir(path) {
    None =>
      // Said on the status line rather than raised: the reader typed a path, and the useful answer
      // is which path was wrong.
      self.say("not a directory: \{path}")
    Some(cwd) => self.show(Workspace(cwd))
  }
}

///|
/// Open the host's folder chooser, and add whatever it returns.
///
/// The same ending as `add_workspace`, reached from a dialog rather than from the keyboard. Three
/// outcomes and only one of them is a workspace: a closed dialog says nothing at all, because the
/// reader who changed their mind has already been answered.
async fn Requests::choose_workspace(self : Requests) -> Unit {
  match (self.pick)() {
    Cancelled => ()
    // The reader is owed a reason: the path field under the button is the way forward, and it only
    // reads as one if they are told the button could not be used.
    Unavailable(why) => self.say(why)
    Chosen(path) =>
      match @platform.canonical_dir(path) {
        // Possible, and worth saying: a chooser hands back a path, and something can remove the
        // directory between the dialog closing and this line.
        None => self.say("not a directory: \{path}")
        Some(cwd) => self.show(Workspace(cwd))
      }
  }
}

///|
/// One POST from the settings panel.
async fn Requests::apply_settings(self : Requests, body : String) -> Unit {
  let app = self.app
  let shown = app.shown()
  match @core.parse_settings_post(body) {
    None => self.say("unrecognized settings form")
    Some(post) => {
      // Held across the write and the render, so two tabs saving at once cannot both read the old
      // settings, edit them and write back — which loses one of the two edits and is exactly the
      // failure the session log had before it went append-only.
      app.settings_lock.acquire()
      let message = apply_settings_post(app, shown, post)
      app.settings_lock.release()
      // The panel is re-rendered from what is now in effect rather than from what was submitted,
      // and it goes to every tab: a second browser must not keep showing a skill the first one just
      // switched off. Only the body is replaced, so the `<details>` the reader has open stays open.
      self.tell(
        @html.Patch::Replace(
          target="settings-body",
          html=render_settings_body(app, shown),
        ),
      )
      self.say(message)
    }
  }
}

///|
/// Carry out one queued display change.
///
/// Deliberately logs nothing. `log` writes to stderr, and a stderr write from a task that is
/// running concurrently with others aborts the process under `moon test` — so a `log` call anywhere
/// in a tested module makes that module's tests unrunnable, which is a steep price for a
/// convenience. The worker that reads this queue logs instead; it lives in `main`, where nothing
/// tests it and where a process concern belongs.
async fn Requests::apply_display(self : Requests, job : Job) -> Unit {
  let app = self.app
  match job {
    Switch(path) =>
      if @platform.path_exists(path) {
        // An already-open session is displayed as it is. Re-reading it from disk would throw away
        // the state of a turn that may be running in it.
        let runner = match app.runner(path) {
          Some(existing) => existing
          None => Runner::new(open_path(path), path, app.default_model_id)
        }
        app.display(runner)
      } else {
        // The file is gone — deleted from a shell, or a path from a stale tab — so a fresh session
        // in the workspace the reader was looking at is the useful answer rather than nothing.
        let (session, fresh) = create_session(app.root, shown_cwd(app))
        app.display(Runner::new(session, fresh, app.default_model_id))
      }
    New(dir) => {
      let (session, path) = create_session(app.root, dir)
      app.display(Runner::new(session, path, app.default_model_id))
    }
    Workspace(dir) => {
      // Recorded before the session exists, so a workspace whose session fails to open is still a
      // workspace: the row is what makes the directory reachable again.
      @platform.write_workspace(@core.session_dir_for(app.root, dir), {
        cwd: dir,
        title: None,
      })
      let (session, path) = create_session(app.root, dir)
      let runner = Runner::new(session, path, app.default_model_id)
      // The status line, rather than a message broadcast before the display: anything said here
      // would be replaced by the refresh at the end of this function. On the session because the
      // line belongs to it — and it has to survive that refresh to be worth saying at all, since
      // the row that appears in the sidebar shows one path component.
      runner.status = "workspace added: \{dir}"
      app.display(runner)
    }
  }
  // Nothing is stopped to get here: the session that was on screen keeps running, in its own slot,
  // out of sight.
  self.refresh()
}

///|
/// Show every session a workspace holds, past the cap.
///
/// Kept for the life of the process rather than re-folded on the next display change: the gesture
/// that would fold it back — closing the workspace — is the browser's, and this number is only ever
/// reached by a reader who asked for it.
async fn Requests::more(self : Requests, cwd : String) -> Unit {
  if cwd == "" {
    return
  }
  self.app.expanded.set(cwd, true)
  self.refresh()
}

// ── the page ───────────────────────────────────────────────────────────────

///|
/// The whole document.
///
/// `page` and `regions` are two views of the same state, and both live here so that there is one
/// definition of what the page is: the initial HTML and the frames a reconnecting tab receives are
/// the same regions, and a region added to one and forgotten in the other is a bug that only shows
/// up after a reconnect.
async fn Requests::page(self : Requests) -> String {
  let app = self.app
  let shown = app.shown()
  // The command list names the workspace's skills, and a directory whose skills have never been
  // scanned would come out as a directory with none. Either way the list is built before the page
  // that shows it.
  app.load_skills(shown.cwd)
  // The sidebar holds the regions with different reasons to change: what is running, what exists,
  // and the settings panel. That last one is not a region at all — it is drawn once here, pinned to
  // the bottom left corner of the window by the stylesheet, and it survives every refresh because
  // nothing replaces the sidebar. On a narrow screen, where the sidebar is the folded header, it
  // joins the list instead of the corner.
  let sidebar = @html.render_sidebar([
    @html.raw(render_tasks(app, shown)),
    @html.raw(render_jobs(app, @env.now().reinterpret_as_int64())),
    @html.raw(workspace_items_and_render(app, shown)),
    @html.raw(render_settings_panel(app, shown)),
  ])
  let column = @html.el(Div, attrs=[@html.cls("column")], children=[
    title_node(app, shown),
    transcript_node(app, shown),
    @html.render_status(app.status_line(shown)),
    @html.composer(
      model_picker(app, shown),
      shown.is_running(),
      command_hints(app, shown),
      // The figures, drawn by the same function the turn refreshes them with: one renderer for
      // `#usage`, so the first frame and every later one are the same node.
      usage_chips(
        @core.model_spec_for(shown.model_id).0.context_window,
        app.overhead_tokens(app.system_prompt(shown)),
        shown,
      ),
    ),
  ])
  let body = @html.el(Div, attrs=[@html.cls("layout")], children=[
    sidebar, column,
  ])
  @html.render_page("pi", @html.stylesheet(), client_script(), [body]).render()
}

///|
/// The transport's view: one closure per route, each a line.
///
/// Deliberately thin. Everything a route *decides* is a method above, so the tests cross the seam
/// at the methods rather than by standing up a socket — and what is left here is the mapping from a
/// URL to a decision, which is the one part `server/http_test.mbt` already covers.
fn Requests::routes(self : Requests) -> @server.Routes {
  {
    page: () => self.page(),
    regions: () => self.regions(),
    prompt: text => self.accept(text),
    abort: path => self.abort(path),
    switch_session: path => self.show(Switch(path)),
    new_session: dir => self.show(New(dir)),
    set_model: id => self.change_model(id),
    continue_turn: path => self.continue_turn(path),
    dismiss_turn: path => self.dismiss_turn(path),
    kill_job: id => self.kill_job(id),
    add_workspace: path => self.add_workspace(path),
    choose_workspace: () => self.choose_workspace(),
    // The same rename the `/name` command reaches, so a name arrives by whichever route the reader
    // took and lands in the log identically.
    rename: name => self.rename(name),
    delete_session: path => self.delete(path),
    earlier: () => self.earlier(),
    undo_delete: path => self.undo_delete(path),
    more: cwd => self.more(cwd),
    settings: body => self.apply_settings(body),
  }
}

// ── deleting a session ─────────────────────────────────────────────────────

///|
/// Take one session out of the store, and remember it so it can be put back.
///
/// Three refusals, and they are all the same shape: a session that something else is still using
/// must not vanish from under it. A turn still running in it would keep appending to a name nothing
/// lists; a background job it started would keep running with no row to find it on. Neither is
/// about the file — they are about the state that outlives the file.
///
/// Deleting *the session on screen* is allowed, and it moves the display to whatever is newest
/// afterwards. Refusing it would have been the smaller change, but "you cannot delete this one,
/// switch first" is a rule the reader has to learn for no benefit; the page is perfectly capable of
/// showing something else.
async fn Requests::delete(self : Requests, path : String) -> Unit {
  let app = self.app
  // Read before the file moves, and through the same function the row uses, so the notice names the
  // session exactly as the row it was clicked on did.
  let label = app.session_label(path, app.labels.modified_of(path))
  match app.runner(path) {
    Some(runner) =>
      if runner.is_running() {
        self.say("cannot delete a session while a turn is running in it")
        return
      } else {
        ()
      }
    None => ()
  }
  if app.jobs.live_count(path) > 0 {
    self.say("cannot delete a session with a background job still running")
    return
  }
  if !@platform.path_exists(path) {
    self.say("that session is already gone")
    self.refresh()
    return
  }
  // The replacement is decided and *installed* before the deleted session leaves the registry.
  //
  // The order matters more than it looks: `App::shown` falls back to `registry[0]`, so an empty
  // registry makes every subsequent refresh panic — and the display worker that would otherwise
  // refill it runs asynchronously, long after this returns. Resolving the next session first keeps
  // "there is always something on screen" true at every point in between.
  let replacement = if app.displayed == path {
    Some(next_session_after(app, path))
  } else {
    None
  }
  // `Array` is not assignable, and this is the only place the registry shrinks.
  let kept : Array[Runner] = []
  for runner in app.registry {
    if runner.path != path {
      kept.push(runner)
    }
  }
  app.registry = kept
  @platform.delete_session(path)
  app.labels.forget(path)
  match replacement {
    Some(runner) => app.display(runner)
    None => ()
  }
  app.deleted = Some({ path, label, at: @env.now().reinterpret_as_int64(), })
  self.refresh()
}

///|
/// Something to look at once the displayed session is gone.
///
/// Three answers in order of cost: another session already open in the same workspace, the newest
/// one saved there, and finally a brand-new one. The last is not a fallback for a bug — it is the
/// honest answer in an empty store, where the page still has to have a session because everything
/// it renders is in terms of one.
///
/// The doomed path is excluded explicitly, and that is the whole point of this being its own
/// function. It runs *before* the file moves, so asking the store for the newest session there
/// hands back the very session being deleted — it is still the newest file, because it is still a
/// file. The page then keeps rendering a conversation the list has already dropped, and goes on
/// doing it after a reload, since the runner is still in memory. Excluding it here is what makes
/// the order of operations above safe.
async fn next_session_after(app : App, path : String) -> Runner {
  let cwd = shown_cwd(app)
  for runner in app.registry {
    if runner.path != path && runner.cwd == cwd {
      return runner
    }
  }
  for stored in @platform.list_sessions(@core.session_dir_for(app.root, cwd)) {
    if stored.path != path {
      return Runner::new(
        open_path(stored.path),
        stored.path,
        app.default_model_id,
      )
    }
  }
  let (session, created) = create_session(app.root, cwd)
  Runner::new(session, created, app.default_model_id)
}

///|
/// Show more of the conversation: raise the displayed session's render window one step.
///
/// A request the reader makes, not something scrolling does. Scroll-driven loading needs a notion of
/// "what has already been loaded" that has to stay true across refreshes, reconnects and switches
/// between sessions, and that state is where the bugs live — the transcript is a function of the
/// session plus this one number, and the number only changes here.
///
/// The whole transcript is replaced rather than prepended to. Prepending would be cheaper, but it
/// means two ways to produce the same region — the snapshot and the incremental path — and they
/// drift. The reader's place is kept by the browser's own scroll anchoring, which is exactly the
/// case it exists for.
async fn Requests::earlier(self : Requests) -> Unit {
  let app = self.app
  let shown = app.shown()
  shown.depth += transcript_window_step()
  self.refresh()
}

///|
/// Put the last deleted session back.
///
/// No guard worth having: the rename either finds the file or does not, and a session already back
/// is a no-op. The name is not reassigned to anything else — nothing in this program creates a file
/// called `<something>.deleted` — so putting it back cannot overwrite a different conversation.
async fn Requests::undo_delete(self : Requests, _path : String) -> Unit {
  let app = self.app
  let now = @env.now().reinterpret_as_int64()
  // Freshness is asked the same way the rendering asks it. The notice is drawn with a deadline and
  // taken off screen by the page when it passes, so a click arriving after that is a click on a
  // button that is no longer there — a stale tab, or a request replayed. Putting the file back
  // anyway would be a restore nobody asked for.
  let live = match app.deleted {
    Some(notice) => @html.still_undoable(notice, now)
    None => false
  }
  match app.deleted {
    Some(notice) if live => {
      @platform.restore_session(notice.path)
      app.labels.forget(notice.path)
    }
    _ => ()
  }
  // Cleared whatever happened: the offer is for the click that just happened, and an Undo button
  // that outlives its usefulness has to be explained.
  app.deleted = None
  self.refresh()
}
