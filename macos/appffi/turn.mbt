///|
/// One turn in one session: what it is given, what it does, and what it leaves behind.
///
/// `Shell::run_turn` and what only it uses: the name every row it emits carries, the sentences a turn
/// can end with, the drift it logs, the skills the reader named or the session's directory holds, and
/// the key it sends. The prompt and the window facts it is given are in `events.mbt`, because the
/// `usage` row reports exactly those and one function should answer both.
///
/// Split out of `app.mbt` when that file passed three thousand lines. The seam is the one the command
/// loop had already drawn: `Shell::run_turn` is here, and `Shell::handle` — which decides to call it —
/// is in `app.mbt`. Nothing but text moved: a file in MoonBit is an organisational unit, not a module.

///|
/// The name one row of a turn's stream carries.
///
/// Unique for the whole session, not merely within the turn, and that is the whole point: the host
/// appends a delta to *the row with this id*, so a second turn that named its first block `reply-1`
/// would have its text written into the first turn's row — the previous answer growing, the new one
/// never appearing as a row of its own, and the tool rows overwritten in place. Measured, not
/// imagined: that is what "the thinking and the tools disappear when I send the next prompt" was.
///
/// The web UI names its live blocks the same way (`stream-<turn>-<seq>`, `live-tool-<turn>-<seq>`),
/// for the same reason, and this is that rule with the document taken out.
fn row_id(kind : String, turn : Int, seq : Int) -> String {
  "\{kind}-\{turn}-\{seq}"
}

///|
/// What the line under the composer says between model calls: the turn is waiting on the model.
///
/// A named constant rather than a literal in two places, because two places is enough for them to
/// drift: the turn says it when it starts, and it is what a retry restores before any counts have
/// been reported.
let thinking_status : String = "thinking…"

///|
/// What the line says while a model call is waiting to be tried again.
///
/// A retry is the one stretch of a turn with nothing else to watch: the model has not answered, no
/// tool has run, and the counts have not moved. That silence is what a reader reads as a program
/// that has stopped working, and this is the sentence that fills it.
///
/// `None` is what the driver sends when the call comes back, and `restore` is the line the caller was
/// showing before: the pair is one fact about one line, which is why it is one function rather than
/// two. The line to put back is the caller's to know — it is the counts, written from the progress
/// reports — and it is passed rather than assumed, because restoring a thinner line than the reader
/// was watching would take the numbers away at the moment they are deciding whether to keep waiting.
fn retry_status(attempt : @agent.RetryAttempt?, restore : String) -> String {
  match attempt {
    Some(pending) =>
      "no answer — retrying (\{pending.next} of \{pending.total})"
    None => restore
  }
}

///|
/// What the host should say once a turn is over.
///
/// Deliberately not the turn's figures — those are reported as they happen, and saying them again
/// one line lower puts the same numbers on screen twice, which is where a reader stops trusting
/// either copy. What is left is what the figures cannot say.
fn ending_text(result : @agent.TurnResult, aborted : Bool) -> String {
  if aborted {
    "stopped"
  } else if result.cost_limit_hit {
    "stopped at the cost limit"
  } else if result.time_limit_hit {
    "stopped at the time limit"
  } else if !result.settled {
    "gave up without a final answer"
  } else {
    ""
  }
}

///|
/// Run one prompt to completion, and say everything that happened.
///
/// The shape is the web UI's `run_turn` with the document taken out. What is left is the part that
/// was never about HTML: build the request from the session's own model and the process's settings,
/// stream, and report.
///
/// `open` is the session this turn belongs to, and it is a parameter rather than `self.shown()` for the
/// reason this whole refactor exists: the reader can switch away mid-answer, send somewhere else, and
/// come back — so a turn has to write *its* session and not "the one on screen". Every emission below
/// One line per turn saying how far each request had to be re-billed, when somebody asked for it.
///
/// The figure a turn reports cannot say what it cost to *send*: a request that is the previous one
/// plus a tail is read from cache almost entirely, and the same request with one message rewritten
/// in the middle is nearly all fresh input at fifty times the price. The turn's own `request_drift`
/// knows the difference, and until this existed nothing outside a test ever saw it -- including the
/// seam between two turns, which is where the trim boundary most often moves and therefore where the
/// expensive rewrites live.
///
/// Written to the same file `WEI_DEBUG` names for `WeiKit.WireLog`, so one variable turns on both
/// halves of a session's evidence, and off unless asked for. One JSON object per line so it can be
/// collected and read back later; a reader of the transcript is never shown it, because a boundary
/// moving is ordinary and a line on every turn would be noise.
async fn Shell::log_drift(
  self : Shell,
  path : String,
  finished : @agent.TurnResult,
) -> Unit {
  if self.debug_log == "" {
    return
  }
  let first : Json = match finished.request_drift {
    [] => Json::null()
    [drift, ..] =>
      Json::object(
        Map([
          ("comparable", Json::boolean(drift.comparable)),
          ("within_turn", Json::boolean(drift.within_turn)),
          ("messages", Json::number(drift.messages.to_double())),
          ("bytes", Json::number(drift.bytes.to_double())),
          ("first_changed", Json::number(drift.first_changed.to_double())),
          (
            "previous_messages",
            Json::number(drift.previous_messages.to_double()),
          ),
          ("changed_bytes", Json::number(drift.changed_bytes.to_double())),
        ]),
      )
  }
  // The worst rewrite of the turn as well, because "the first request was clean" and "nothing in
  // this turn was rewritten" are different answers and only the pair tells them apart.
  let mut worst = 0
  let mut comparable = 0
  for drift in finished.request_drift {
    if drift.changed_bytes > worst {
      worst = drift.changed_bytes
    }
    if drift.comparable {
      comparable += 1
    }
  }
  let line : Json = Json::object(
    Map([
      ("session", Json::string(path)),
      ("at", Json::number(@env.now().reinterpret_as_int64().to_double())),
      ("model_calls", Json::number(finished.model_calls.to_double())),
      ("comparable", Json::number(comparable.to_double())),
      ("worst_changed_bytes", Json::number(worst.to_double())),
      ("first", first),
    ]),
  )
  @platform.append_text(self.debug_log, line.stringify() + "\n") catch {
    _ => ()
  }
}

///|
/// carries `open.path` so the host can file it under the right transcript.
async fn Shell::run_turn(
  self : Shell,
  open : Open,
  prompt : String,
  continuing? : Bool = false,
) -> Unit {
  open.aborting.val = false
  // Before the first `await`, so that a command arriving during the turn sees it set. The sidebar
  // reads this: it is how a row gets its spinner.
  open.busy = true
  // Cleared by `defer` rather than at the end, and the reason it is a `defer` at all is that the turn
  // can leave by raising: `run_turn` catches its own failure, but a cancellation — the process being
  // asked to quit mid-answer — comes out of it as one. `defer` takes a value and MoonBit has no
  // assignment expression, so the flag is cleared by a closure.
  defer clear_busy(open)
  // A handle from this turn must not outlive it: the next turn's tools are different tools, and a stale one
  // would let Stop cancel work that belongs to a reader's *next* question.
  defer clear_running_tool(open)
  let path = open.path
  // A named skill becomes its own text here, before anything is echoed or written down.
  //
  // Before, because what the model is sent and what the log records have to be the same text: a
  // transcript that showed `/skill:moonbit do X` while the log held a skill block would read one way
  // while the turn ran and another way after a restart, which is the mismatch this file keeps
  // refusing to create anywhere else.
  //
  // Not for a continued turn. That prompt is read back out of the log, where it was already expanded
  // when it was first sent — expanding it again would look for a `/skill:` command in a skill block
  // and, finding none, leave the text alone for the wrong reason.
  let sent = if continuing {
    prompt
  } else {
    match self.expand_skill(open, prompt) {
      Some(expanded) => expanded
      None => prompt
    }
  }
  // The pictures go with the prompt and are taken off the composer here, before the first `await`:
  // they are part of the question being asked, and a reader who sends while the request is going out
  // must not send the same screenshot twice.
  let images : Array[@core.Content] = []
  for attachment in open.attached {
    images.push(
      @core.Content::Image(data=attachment.data, mime_type=attachment.mime_type),
    )
  }
  // Echoed from the same list the request is built from, and echoed here rather than after the
  // clearing below — this is the last moment the turn's pictures exist as a list. The ordering is the
  // point: a host that drew them from `say_images`, which follows, would be drawing a composer that
  // has already been emptied.
  self.say_user(
    path,
    sent,
    continued=continuing,
    images=attached_images(open.attached),
  )
  self.say_status(path, thinking_status)
  open.attached = []
  self.say_images(open)
  let mode = self.settings.tool_mode
  // The session's model, not the process's: this is the one line that makes a resumed session's
  // recorded choice mean anything. Its pricing and window come from the same catalog entry, so a
  // turn cannot be billed at one model's rates while calling another.
  let spec = @core.model_spec_for(open.model_id).0
  let tools = @core.tools_for_mode(mode)
  let context = @agent.AgentContext::new(
    session=open.session,
    session_path=path,
    cwd=open.cwd,
    api_key=self.api_key(),
    // The same function the context figure calls, rather than a second assembly of the same
    // sections: a turn that sent a prompt the estimate did not describe would make the size on the
    // bar a figure about a request nobody sends.
    system_prompt=self.system_prompt(open, tools),
    tools~,
    model=spec.id,
    base_url=self.base_url,
    pricing=spec.pricing,
    context_window=spec.context_window,
    jobs=self.jobs,
  )
  // The two things that change while the turn runs: which block the deltas belong to, and which
  // row a tool report belongs to. Both are ids rather than nodes — the host holds the nodes, and
  // all that crosses is the name of the one to write into.
  //
  // Bumped before anything is named, so that this turn's names cannot be last turn's. The sequences
  // below start at one again, which is exactly why they have to be paired with a turn: `reply-1` is
  // a name two turns would otherwise both choose.
  //
  // Counted per *session*, so two conversations both streaming their first answer both name it
  // `reply-1-1`. That is safe as long as a replay of one can never land in the other's transcript —
  // which is what the `session` on every one of these events is for, and why it is not optional.
  open.turn += 1
  let turn = open.turn
  let mut piece_id = ""
  let mut piece_seq = 0
  let mut piece_kind = ""
  // The text of the block that is still arriving, accumulated from the deltas so that its parse can
  // be sent the moment it stops. A `StringBuilder` rather than `+`: a long answer arrives in hundreds
  // of frames, and repeated concatenation is the quadratic this path exists to avoid.
  let piece_text = StringBuilder()
  // How much text the open block has, counted here rather than asked of the buffer: the two gates on
  // a live frame are about how much has arrived, and reading that off a `StringBuilder` means
  // building the string first.
  let mut piece_length = 0
  // The open block is over: send its parse, and start the next one empty. Called where a block stops
  // being the newest thing that happened — a tool, the other kind of text, or the end of the turn —
  // which are exactly the moments the host stops appending to that row.
  let close_piece = () => {
    // Only the kinds the host draws as markdown: see `draws_markdown`. A finished reasoning block
    // still crosses as text — that is what the peek draws — and the parse it would have carried was
    // the largest single thing on this wire.
    if draws_markdown(piece_kind) {
      self.say_blocks(path, piece_id, piece_text.to_string(), open.live)
    }
    open.live = None
    piece_text.reset()
    piece_length = 0
    piece_kind = ""
  }
  // A tool is one row from start to finish, so the id is chosen when it starts and reused when it
  // reports. The report does not carry the id the start did — it carries the model's `call_id`,
  // which the running handle never had — so the pairing has to be kept here.
  let mut tool_seq = 0
  let mut open_tool : String? = None
  // Bumped by a tool, so the answer that follows one is a new block rather than more text on the
  // block from before the tool call.
  let new_piece = (kind : String) => {
    // Before the id moves: whatever was arriving is finished, and this is the last moment its text is
    // still here.
    close_piece()
    piece_seq += 1
    piece_id = row_id(kind, turn, piece_seq)
    piece_kind = kind
    // A new block is a new parse. The host's row for this id starts with no blocks, so the state has
    // to start with none sent — keeping the previous block's would make the first frame a suffix of
    // a document the host never got the head of.
    //
    // **Only the answer gets one.** Reasoning is drawn as plain text by design, so a live parse of it
    // would be work nobody draws — and `close_piece` reads this back to decide what to diff, so a
    // state for a block that sent nothing live would be a diff against a document the host never got.
    open.live = if kind == "reply" {
      Some({ id: piece_id, sent: [], at_length: 0, at_ms: @env.now(), })
    } else {
      None
    }
    piece_id
  }
  let on_delta : async (@core.StreamEvent) -> Unit = delta => {
    let (kind, text) = match delta {
      @core.Text(delta~) => ("reply", delta)
      @core.Thinking(delta~) => ("thinking", delta)
    }
    let id = if piece_kind == kind { piece_id } else { new_piece(kind) }
    piece_text.write_string(text)
    piece_length += text.length()
    self.say_piece(path, kind, id, text)
    // **Only the answer is rendered live.** Reasoning is drawn on the host as plain text by design —
    // three lines of its tail while it arrives, a summary line once it stops — so a parse of it would
    // be work nobody draws: the reasoning frames were a third of the live traffic in a measured run.
    // Its *finished* parse still goes out, once, because that is the row's record of how to draw
    // itself; see `close_piece`.
    if kind == "reply" {
      self.live_blocks(path, open, piece_text, piece_length, @env.now())
    }
  }
  let on_tool_process : async (@agent.ToolHandle?) -> Unit = handle => {
    // **The handle is kept, not just drawn.** It is the only thing that can stop the command the reader is
    // watching, and `Abort` reads it — see `running_tool`. Set before the row goes out, so a stop that
    // arrives while the row is being drawn still finds it.
    open.running_tool = handle
    match handle {
      Some(running) => {
        tool_seq += 1
        let id = row_id("tool", turn, tool_seq)
        open_tool = Some(id)
        // The next text belongs to a new block. This is the moment the previous one stopped being
        // the newest thing that happened, so this is where its parse goes out.
        close_piece()
        self.say_tool(path, id, running.name, running.detail, false, "", false)
      }
      None => ()
    }
  }
  let on_tool : async (@agent.ToolEvent) -> Unit = report => {
    let id = match open_tool {
      Some(value) => value
      None => {
        // A report that was never announced. Rare, and worth handling rather than dropping: a
        // tool result that never reaches the reader is a turn that looks stalled.
        tool_seq += 1
        row_id("tool", turn, tool_seq)
      }
    }
    open_tool = None
    self.say_tool(
      path,
      id,
      report.name,
      "",
      true,
      report.output,
      report.is_error,
    )
  }
  // The counts are the cheapest possible "still alive" signal, and the one a reader watches when a
  // turn is taking minutes.
  //
  // The last one is kept as well as said, because a retry has to put *something* back and the counts
  // are the most informative thing to put back — the reader who was watching "3 model call(s)" is the
  // reader deciding whether to keep waiting.
  let mut progress_line = thinking_status
  let on_progress : async (Int, Int) -> Unit = (calls, tools_done) => {
    progress_line = "working… \{calls} model call(s), \{tools_done} tool call(s)"
    self.say_status(path, progress_line)
  }
  // Every commit, not just the end of the turn: this is what makes a cost figure move while the
  // turn runs, because each model call's numbers are in the log the moment the response ends.
  //
  // The same callback is where a compaction becomes visible. It happens inside a model call, between
  // two deltas, and the reader is told by a row in the conversation — at the point where their own
  // words stopped being what the model was sent. `compactions` counted rather than a flag, because a
  // long turn can compact twice and a flag would report the first and swallow the second.
  let mut compactions = compaction_state(open.session).0
  let on_commit : async (@core.Session) -> Unit = committed => {
    open.session = committed
    let (count, summary) = compaction_state(committed)
    if count > compactions {
      compactions = count
      self.say_note(path, summary, "context compacted")
    }
  }
  let limits = @core.choose_limits(None, None, None, self.settings)
  let started = @env.now().reinterpret_as_int64()
  let finished = @agent.run_turn(
    context,
    sent,
    started,
    thinking_level=open.think_level,
    max_rounds=limits.max_rounds.value.to_int(),
    max_cost=limits.max_cost.value,
    max_seconds=limits.max_seconds.value.to_int(),
    // Never `continuing`, and the reason is the sentence this shell is built on: the reader types a
    // prompt, and a prompt is a new turn. Inferring it from the log — "the session has a turn open,
    // so this must be a resume" — has no way to tell an interrupted turn the reader wants to continue
    // from one they have moved on from, and it guessed wrong in the worst direction: after a turn
    // failed on a network error, the log kept its open turn, the next prompt was read as a resume,
    // and the reader's words were never sent at all. Measured, not imagined: typed text appeared
    // nowhere in the request.
    //
    // A new turn closes whatever was open as abandoned, which is what the web UI does when a reader
    // ignores the interrupted-turn notice and simply types. Continuing is offered there as a button
    // and belongs here as one too, if it is wanted — a decision the reader makes, not one the shell
    // makes for them.
    continuing~,
    // The last request this session sent, so this turn's first one is measured against it rather
    // than against nothing. `None` for a session that has not sent one yet.
    previous_request=if open.previous_request.is_empty() {
      None
    } else {
      Some(open.previous_request)
    },
    prompt_images=images,
    on_delta~,
    should_stop=() => open.aborting.val,
    on_tool~,
    on_tool_process~,
    on_progress~,
    // The status line while a call is being retried, and the line it goes back to when the answer
    // lands: the driver passes `None` for the second half, so this one callback is the whole
    // exchange rather than an event and a matching clean-up event.
    on_retry=attempt => {
      self.say_status(path, retry_status(attempt, progress_line))
    },
    on_commit~,
  ) catch {
    err => {
      // The block that was arriving stopped here, mid-sentence. Its parse still goes out: a turn that
      // failed partway through is exactly when a reader reads back what the model had said, and
      // plain text with a table in it is where a half-answer looks broken rather than cut short.
      close_piece()
      // Named, because a turn that fails in the background is a turn nobody is watching: the message
      // says which conversation it was about, or the reader sees a failure on screen that happened
      // somewhere else.
      // `ends_turn=true`: this is the one error that *is* the end of a turn, and the host needs to be
      // told rather than left to guess. It guessed before — any error cleared its "running" flag — and
      // the cost was that a message about a jobs file (written on a timer, beside the turn) took the
      // Stop button away from a reader whose turn was still going. See `say_error`.
      self.say_error(
        "the turn failed: \{@core.error_text(err)}",
        session=path,
        ends_turn=true,
      )
      self.say_status(path, "failed")
      // The spend still moved — a request that was refused, or a stream that died halfway, was paid
      // for — so the totals are re-sent. `last_turn` is deliberately not updated: a turn that did not
      // finish has no figures of its own to report, and describing half a turn as the last one would
      // be the one place this line lies.
      self.say_usage(open)
      // A turn that failed is one the reader can still carry on: the log keeps it open, so the work it
      // did is in front of the model and `continue` re-sends the question it had been asked. The notice
      // that asks the reader to choose goes out **now**, with the error, rather than at the next switch
      // — a notice that arrives ten minutes later, when the reader has moved on, is a notice that
      // arrives for no reason.
      //
      // `busy` is cleared by hand first: the line below answers "is anything running this turn", and
      // the `defer` that would otherwise have cleared the flag has not run yet.
      clear_busy(open)
      self.say_turn_ended(open, "failed")
      return
    }
  }
  open.session = finished.session
  // Kept for the next turn's first request to be measured against. This is the write that makes the
  // seam between turns visible: without it every turn's first request is incomparable, and that is
  // where the trim boundary most often moves.
  open.previous_request = finished.last_request
  self.log_drift(path, finished)
  // The last block of the turn, which no tool and no new block ever closed.
  close_piece()
  // Kept for the line under the composer, and sent as part of the usage snapshot: what this turn
  // cost is a fact about a turn that is now over, and the next one will replace it.
  open.last_turn = {
    usage: finished.usage,
    model_calls: finished.model_calls,
    tool_calls: finished.tool_calls,
    cost: finished.usage.cost.total,
    present: true,
  }
  let aborted = open.aborting.val
  self.say_end(
    path,
    ending_text(finished, aborted),
    finished.model_calls,
    finished.tool_calls,
    finished.usage.cost.total,
  )
  self.say_usage(open)
  // The turn is closed in the log, so the snapshot the host is drawing from is out of date — and it
  // is out of date in the direction of a decision that no longer exists. `say_turn_ended` sends that
  // snapshot when the reader is watching this session, and a notice-banner fact when they are not:
  // a turn that ends in a conversation nobody has open is exactly the case that used to move the
  // window, and it is now the case the window is told about without being moved.
  self.say_turn_ended(open, if aborted { "stopped" } else { "finished" })
}

///|
/// The key this process should send, resolved at the moment of the turn so that saving one means
/// the next turn uses it rather than the next process.
fn Shell::api_key(self : Shell) -> String {
  match resolve_key(self.settings) {
    Some(choice) => choice.key
    None => ""
  }
}

// ── skills ─────────────────────────────────────────────────────────────────
//
// upstream's `/skill:<name>`: the reader naming a skill rather than hoping the model picks it. The catalog
// in the system prompt tells the model what exists; this is the same text arriving because the
// *reader* decided it was relevant, which matters when a one-line description is not enough to
// persuade anyone.
//
// The syntax, the expansion and the framing are `core`'s and `platform`'s, shared with the web UI
// and tested there. What is here is only who decides to call them.

///|
/// The skills of a session's working directory, discovering them once per directory.
///
/// Keyed by directory rather than by session, because it is a fact about a *project*: two sessions open
/// in one repository must see the same skills, and discovering them twice would be two scans that could
/// disagree.
async fn Shell::skills_here(self : Shell, cwd : String) -> Array[@core.Skill] {
  match self.skills.get(cwd) {
    Some(cached) => return cached
    None => ()
  }
  let found = @platform.discover_skills(cwd, self.home)
  self.skills.set(cwd, found)
  found
}

///|
/// The skills a turn may actually use: discovered, minus the ones switched off.
///
/// Filtered at read time rather than at scan time, so turning one off takes effect on the next turn
/// without a rescan — and so the settings panel, which has to list what is off in order to turn it
/// back on, still sees everything.
async fn Shell::enabled_skills(
  self : Shell,
  cwd : String,
) -> Array[@core.Skill] {
  @core.enabled_skills(self.skills_here(cwd), self.settings.disabled_skills)
}

///|
/// Expand a `/skill:<name>` prompt into the skill's own text, or `None` when the text is not that.
///
/// `None` covers three cases the caller treats identically — not a skill command, no such name, and
/// a file that has since been deleted — and all three send the text on as the reader typed it. That
/// is upstream's behaviour, and it is what keeps a stray `/skill:` from eating a message.
async fn Shell::expand_skill(
  self : Shell,
  open : Open,
  text : String,
) -> String? {
  let (name, args) = match @core.skill_command_parts(text) {
    Some(parts) => parts
    None => return None
  }
  @platform.expand_skill_command(self.enabled_skills(open.cwd), name, args)
}

///|
/// What a bare `/skill` answers with.
///
/// Asked of the *enabled* skills, because the question is "what can I use here" and a name that is
/// switched off would be an answer that does nothing when tried.
fn skill_list_text(skills : Array[@core.Skill]) -> String {
  let out = StringBuilder()
  for skill in @core.dedup_skills(skills) {
    if out.to_string() != "" {
      out.write_string("\n")
    }
    if skill.description == "" {
      out.write_string("/skill:\{skill.name}")
    } else {
      out.write_string("/skill:\{skill.name} — \{skill.description}")
    }
  }
  out.to_string()
}

///|
/// Answer the reader who typed `/skill` on its own: what is here, rather than a turn.
///
/// No turn, and deliberately: the question is about this machine rather than about the conversation,
/// so there is nothing to ask the model and nothing to spend. It lands as a row in the transcript
/// because that is where the reader is looking, and it is labelled so it cannot be taken for an
/// answer somebody gave.
async fn Shell::list_skills(self : Shell, open : Open) -> Unit {
  let skills = self.enabled_skills(open.cwd)
  if skills.length() == 0 {
    self.say_status(
      open.path,
      "no skills here — a skill is a directory with SKILL.md in ~/.wei/skills or .wei/skills",
    )
    return
  }
  self.say_note(open.path, skill_list_text(skills), "skills")
}
