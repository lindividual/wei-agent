///|
/// Running one turn, and saying what happened.
///
/// This is the most intricate part of the package, and it is one turn: acquire the session's slot,
/// build the request, stream the answer into the nodes the live patches target, then replace those
/// temporary nodes with the finished rendering. The stream buffers and the flush timer are here
/// because the reader's experience of a slow model is part of running the turn.
///
/// Two things are worth knowing before reading it. The finish and failure paths both rebuild the
/// blocks from the log rather than from what was streamed, so a failed turn shows what it managed to
/// write; and `Runner::trace` keeps a mirror of what has been sent, so a browser that connects or
/// switches back mid-turn is given the same picture rather than an empty exchange.

///|
/// What the session says on its status line once a turn is over.
///
/// Deliberately *not* the turn's figures. Those belong on the footer under the reply — model calls,
/// tool calls, tokens, cost, cache share — and the footer is now written for a live turn as well as
/// for a reloaded one. Saying them again one line lower put the same numbers on screen twice, which
/// is where a reader stops trusting either copy. What is left here is what the footer cannot say:
/// that the turn was cut short, and by what. A turn that finished normally says nothing, because
/// the answer is the report.
fn status_text(result : @agent.TurnResult, aborted : Bool) -> String {
  if aborted {
    "stopped"
  } else if result.cost_limit_hit {
    // Named as the cost limit rather than as a stalled model: the turn was doing what it was
    // asked, and the reader needs to know a guard stopped it — and which one, and at what bound —
    // to decide whether to raise it or continue. The bound is the one figure the footer does not
    // have.
    "stopped at the $\{@core.format_cost(result.usage.cost.total)} cost limit"
  } else if result.time_limit_hit {
    // The third guard, and the third distinct thing to tell the reader. Unlike the round limit,
    // a turn stopped here was making progress and may be worth resuming with a longer bound.
    "stopped at the time limit"
  } else if !result.settled {
    // The model kept asking for tools until the limit. Said plainly, because the reader is the one
    // who has to decide what to do about it.
    "gave up without a final answer"
  } else {
    ""
  }
}

///|
/// Add a delta to the session's live view.
///
/// The live view is a mirror of what the browser is being sent, kept so that a browser
/// which connects (or switches back) later can be given the same picture. Text and
/// reasoning accumulate into one piece per block, keyed by the same element id the live
/// patches use — which is what lets the snapshot and the stream agree about where the
/// next delta goes.
fn Runner::trace(self : Runner, piece : @html.LivePiece) -> Unit {
  let key = match piece {
    @html.Text(id~, ..) => id
    @html.Thinking(id~, ..) => id
    @html.Tool(id~, ..) => id
    @html.RunningTool(id~, ..) => id
  }
  for i in 0..<self.live.length() {
    let same = match self.live[i] {
      @html.Text(id~, ..) => id == key
      @html.Thinking(id~, ..) => id == key
      @html.Tool(id~, ..) => id == key
      @html.RunningTool(id~, ..) => id == key
    }
    if same {
      // A delta for a block that is already there: replace it, since the live patches
      // carry the whole text rather than an increment. This is also what turns a running tool into
      // a finished one — they share an id, so the finished piece overwrites the running piece here
      // exactly as its block overwrites the running block in the browser.
      self.live[i] = piece
      return
    }
  }
  self.live.push(piece)
}

///|
/// Run one turn in this session, showing it to whoever is watching this session.
///
/// The caller holds the session's turn slot, so everything here can assume nothing else
/// is writing to this session's log.
async fn run_prompt(
  app : App,
  runner : Runner,
  text : String,
  /// Continue the turn already open instead of starting a new one.
  ///
  /// The only difference the caller sees is that the prompt is not sent — it is already in the log
  /// — and the driver is told not to append a user message or open a second turn. Everything else,
  /// including how the reply is streamed and how the transcript is refreshed, is shared, which is
  /// the point: a continued turn should look exactly like a turn.
  continuing? : Bool = false,
) -> Unit {
  runner.turns.acquire()
  defer runner.turns.release()
  runner.waiting -= 1
  let my_epoch = runner.epoch
  // A queued prompt that a stop has already answered does not run at all.
  if runner.waiting < 0 {
    runner.waiting = 0
  }
  if runner.aborting.value && my_epoch != runner.epoch {
    runner.turns.release()
    return
  }
  runner.busy = true
  runner.aborting.value = false
  runner.phase = "waiting for the model"
  runner.since = @env.now().reinterpret_as_int64()
  runner.turn += 1
  runner.live = []
  runner.prompt = text
  let index = runner.turn
  // The tag a client compares against is the session's short id, not its path: 80 bytes of path
  // on every frame of a stream is the largest single cost in the envelope.
  let session = session_tag(runner.path)
  // The sidebar marks a session as running while it is, which is how work in a session
  // nobody is looking at stays visible.
  let refresh_sidebar = async fn() {
    match app.runner(app.displayed) {
      Some(visible) => {
        let html = workspace_items_and_render(app, visible)
        app.hub.broadcast(
          @html.Patch::Replace(target="sessions", html~).to_sse(),
        )
        // A turn starting or ending changes what the *displayed* session's line should
        // say, even when it is a different one that started: that is the difference
        // between "idle" and "1 other session running".
        app.hub.broadcast(
          @html.Patch::Status(text=app.label_for(visible, visible.status)).to_scoped_sse(
            session_tag(visible.path),
          ),
        )
      }
      None => ()
    }
  }
  // The tasks panel is refreshed when the phase changes, not on a timer: the elapsed time in
  // it is counted by the browser, so a second-by-second frame would be paying for a number
  // the page can work out itself.
  let refresh_tasks = async fn() {
    app.hub.broadcast(
      @html.Patch::Replace(target="tasks", html=render_tasks(app, app.shown())).to_sse(),
    )
  }
  let status = async fn(label : String) {
    runner.status = label
    // Only the reader who is looking at this session needs its progress; the sidebar
    // refresh is what tells everyone else that work is happening.
    app.hub.broadcast(
      @html.Patch::Status(text=app.label_for(runner, label)).to_scoped_sse(
        session,
      ),
    )
  }
  // The background panel changes when a command outlives its tool call, which is a turn event;
  // the supervisor task covers the other direction, a process exiting on its own.
  let refresh_jobs = async fn() {
    refresh_live_pids(app)
    // Recorded before the panel is rebuilt, so what is on disk and what is on screen describe the
    // same moment — and so a crash right after this leaves a file that already knows.
    app.save_jobs()
    app.hub.broadcast(
      @html.Patch::Replace(
        target="jobs",
        html=render_jobs(app, @env.now().reinterpret_as_int64()),
      ).to_sse(),
    )
  }
  // The bar's figures are per session and come from the log, so they are recomputed when a
  // turn changes them rather than on every frame — and only the figures are replaced, so a reader
  // typing a key into the settings panel does not lose it because a turn ended or a model call
  // came back.
  let refresh_bar = async fn() {
    app.hub.broadcast(
      @html.Patch::Replace(
        target="usage",
        html=usage_node(app, app.shown()).render(),
      ).to_sse(),
    )
  }
  // The same refresh, only when the committing turn belongs to the session on screen. The bar's
  // figures are the *displayed* session's, so a turn running somewhere else would send the same
  // bytes to every tab on every one of its model calls, and several sessions running at once is
  // exactly when that adds up.
  let refresh_bar_if_shown = async fn() {
    if app.displayed == runner.path {
      refresh_bar()
    }
  }
  // The model picker locks while a turn runs, and that is a change to the *displayed* session's
  // state, so it is refreshed with the other panels rather than only when the model changes. The
  // server refuses a switch either way; this is what stops the reader trying.
  let refresh_picker = async fn() {
    let shown = app.shown()
    app.hub.broadcast(picker_patch(app, shown).to_sse())
  }
  // Stop is on the same footing as the picker: it says whether this session has work to stop, and
  // that changes exactly when a turn starts and ends. Refreshed here rather than only with the
  // other regions, because a turn does not rebuild the page — it replaces the parts it moved.
  let refresh_stop = async fn() {
    app.hub.broadcast(stop_patch(app.shown()).to_sse())
  }
  status("working…")
  refresh_sidebar()
  refresh_tasks()
  refresh_bar()
  refresh_picker()
  refresh_stop()
  refresh_jobs()

  // The reader's message appears at once, then a throwaway container everything the
  // model produces lands in. When the turn ends the container is replaced by the
  // properly rendered reply — reasoning collapsed, tool calls paired, markdown parsed —
  // so the streaming path never has to decide what the final markup looks like.
  app.hub.broadcast(
    @html.append_node(
      "transcript",
      @html.render_exchange_start(index, Some(text)),
    ).to_scoped_sse(session),
  )
  let stream_root = "streams-\{index}"
  app.hub.broadcast(
    @html.append_node(
      @html.blocks_id(index),
      @html.el(Div, attrs=[@html.attr("id", stream_root)], children=[]),
    ).to_scoped_sse(session),
  )

  // A turn makes several model calls when it uses tools, and each one writes its own
  // text. Both containers are opened lazily, on the first delta, so a call that only
  // thinks does not leave an empty text element behind.
  let mut open_text : @html.StreamBuffer? = None
  let mut open_thinking : @html.StreamBuffer? = None
  let mut stream_seq = 0
  let report : async (@core.StreamEvent) -> Unit = event => {
    match event {
      @core.Text(delta~) => {
        let buffer = match open_text {
          Some(existing) => existing
          None => {
            stream_seq += 1
            let id = "stream-\{index}-\{stream_seq}"
            app.hub.broadcast(
              @html.append_node(
                stream_root,
                @html.el(Div, attrs=[@html.cls("text"), @html.attr("id", id)], children=[]),
              ).to_scoped_sse(session),
            )
            // Small: the flush timer above is what bounds latency, so this only has to keep a fast
            // stream from turning every delta into a frame.
            let fresh = @html.StreamBuffer::new(id, threshold=24)
            open_text = Some(fresh)
            fresh
          }
        }
        match buffer.push(delta) {
          Some(patch) => app.hub.broadcast(patch.to_scoped_sse(session))
          None => ()
        }
        runner.trace(@html.Text(id=buffer.id, text=buffer.text))
      }
      @core.Thinking(delta~) => {
        // Reasoning is streamed too, into a collapsed container. Not streaming it was a
        // mistake: with a model that thinks before every tool call, the page then showed
        // nothing at all for minutes, which reads as a hang.
        let buffer = match open_thinking {
          Some(existing) => existing
          None => {
            stream_seq += 1
            let id = "thinking-\{index}-\{stream_seq}"
            app.hub.broadcast(
              @html.append_node(
                stream_root,
                @html.render_thinking_stream(id, "\{id}-body"),
              ).to_scoped_sse(session),
            )
            // Larger than text — a thinking-heavy model sends a lot of it — but the flush timer
            // applies here too, because a block the reader opens mid-stream must not be empty or
            // stale, and reasoning is exactly what a reader opens mid-stream.
            let fresh = @html.StreamBuffer::new("\{id}-body", threshold=64)
            open_thinking = Some(fresh)
            fresh
          }
        }
        match buffer.push(delta) {
          Some(patch) => app.hub.broadcast(patch.to_scoped_sse(session))
          None => ()
        }
        runner.trace(
          @html.Thinking(id=strip_body_suffix(buffer.id), text=buffer.text),
        )
      }
    }
  }

  // Each tool is shown where it happened, so a long turn reads as work being done rather than as
  // silence — and it is shown from the moment it *starts*, not from the moment it is over. A `bash`
  // call can take minutes, and those minutes are exactly when the reader is wondering whether
  // anything is happening at all.
  //
  // One block per tool, with one id, reused across its whole life: `on_tool_process` appends the
  // running block at that id, and the report replaces it. Appending a second block for the result
  // was the earlier shape, and it left a running block behind to sit there for good.
  let mut tool_seq = 0
  // The id the next report belongs to. Set when a tool starts, consumed when it reports. Cleared on
  // the report rather than on the "nothing is running" callback, because the driver announces that
  // the process finished *before* it reports the result — clearing it there would leave every
  // result with nothing to replace and no running block either.
  let mut open_tool : String? = None
  // The fold the finished tools go into, and the finished block still outside it waiting to be filed.
  // Both are ids rather than nodes: the server never holds the block, it only names it, and the
  // browser is the one that moves it.
  //
  // `file_next` is the newest finished tool — left outside while the reader looks at it, and put away
  // when the next tool starts, which is the moment it stops being the newest thing that happened.
  let mut work : String? = None
  let mut file_next : String? = None
  let mut filed = 0
  let on_tool = (event : @agent.ToolEvent) => {
    let call : @core.Content = @core.ToolCall(
      id=event.call_id,
      name=event.name,
      arguments=event.arguments,
    )
    let result : @core.ToolResultMessage = {
      tool_call_id: event.call_id,
      tool_name: event.name,
      content: [@core.Text(event.output)],
      is_error: event.is_error,
      timestamp: 0L,
      details: None,
    }
    // Replacing rather than appending is what folds the block: the finished rendering is the
    // collapsed form of the same block, so the reader who was watching a live one is left with it
    // folded, holding its result. The timer goes with it — deliberately, because a duration is not
    // in the log, so a reloaded transcript could not show one, and a turn that reads one way the
    // moment it finishes and another way after a refresh is the bug this file keeps having to avoid.
    //
    // Opened on the way in, though, and folded by the browser a moment later (`settling`). The
    // result is the thing the reader was waiting for, and handing it over already folded puts it
    // behind a click nobody knows to make.
    match open_tool {
      Some(id) => {
        open_tool = None
        app.hub.broadcast(
          @html.replace_node(
            id,
            @html.render_tool(id, call, Some(result), settling=true),
          ).to_scoped_sse(session),
        )
        // Outside for now, so the reader can see what came back. The next tool to start is what puts
        // it away — see `on_tool_process`.
        file_next = Some(id)
        runner.trace(@html.Tool(id~, call~, result~))
      }
      // A report that was never announced — a driver that reports a tool without publishing one as
      // running. Appended, not patched at a made-up id: the client drops a patch whose target is
      // missing without saying anything (`if (!node) return`), so replacing here would lose the
      // result in exactly the silence this arrangement exists to avoid.
      None => {
        tool_seq += 1
        let id = tool_block_id(index, tool_seq)
        app.hub.broadcast(
          @html.append_node(
            stream_root,
            @html.render_tool(id, call, Some(result)),
          ).to_scoped_sse(session),
        )
        // Filed on the next tool's start like any other, so this path keeps one rule rather than
        // two: the newest finished tool is outside, the rest are in the fold.
        file_next = Some(id)
        runner.trace(@html.Tool(id~, call~, result~))
      }
    }
  }

  // The counts are the cheapest possible "still alive" signal, and the one a reader
  // watches when a turn is taking minutes.
  let on_progress = (calls : Int, tools : Int) => {
    status("working… \{calls} model call(s), \{tools} tool call(s)")
  }

  // Before the prompt is built, because the catalog is part of it. Cheap after the first turn:
  // the scan happens once per working directory.
  app.load_skills(runner.cwd)
  // Resolved once per turn, from this session's own choice. A log naming a model this build does
  // not have still runs — the fallback is the default — because refusing to answer would be a
  // worse outcome than answering on the wrong model.
  let spec = @core.model_spec_for(runner.model_id).0
  let ctx = @agent.AgentContext::new(
    session=runner.session,
    session_path=runner.path,
    cwd=runner.cwd,
    api_key=app.api_key,
    // The workspace's instructions and the skill catalog both ride the prompt's appended sections:
    // each is the empty string when there is nothing to say, so a workspace with no `AGENTS.md`
    // and no skills sends exactly the prompt it sent before either existed.
    system_prompt=app.system_prompt(runner),
    tools=app.tools,
    // The session's model, not the process's: this is the one line that makes the choice mean
    // anything. Its pricing, window and thinking levels all come from the same catalog entry, so
    // a turn cannot be billed at one model's rates while calling another.
    model=spec.id,
    base_url=app.base_url,
    pricing=spec.pricing,
    context_window=spec.context_window,
    jobs=app.jobs,
  )
  // Streaming is batched by size *and* flushed on a short timer, and the timer is what makes the
  // reader's experience of it consistent. Batching alone means a block appears in the DOM when its
  // first delta arrives but stays empty until enough text has piled up — so opening one mid-stream
  // showed nothing, and for reasoning, which arrives in a flood, "enough" was a quarter of a
  // kilobyte. Flushing by time bounds how stale a live block can be without turning every delta
  // into a frame.
  let mut flushing = true
  let flush_open = () => {
    for buffer in [open_text, open_thinking] {
      match buffer {
        Some(existing) =>
          match existing.flush() {
            Some(patch) => app.hub.broadcast(patch.to_scoped_sse(session))
            None => ()
          }
        None => ()
      }
    }
  }
  // A failed turn must not take the process down, and must not leave the session marked
  // as busy: the log is on disk, and the reader needs to see what happened.
  try {
    let result = @async.with_task_group(group => {
      // The timer stops with the turn: `flushing` is the one flag the two share, and the group
      // waits for the ticker rather than leaving it behind.
      ignore(
        group.spawn(() => {
          while flushing {
            @async.sleep(250)
            if flushing {
              flush_open()
            }
          }
        }),
      )
      let finished = @agent.run_turn(
        ctx,
        text,
        @env.now().reinterpret_as_int64(),
        thinking_level="high",
        max_rounds=app.limits.max_rounds.value.to_int(),
        max_cost=app.limits.max_cost.value,
        max_seconds=app.max_seconds,
        continuing~,
        on_delta=report,
        should_stop=() => runner.aborting.value,
        on_tool~,
        on_progress~,
        // Every commit, not just the end of the turn. This is what makes the tokens, the cache
        // reads and the context figure move while the turn runs: each model call's numbers are in
        // the log the moment the response ends.
        on_commit=async fn(in_flight) {
          runner.in_flight_session = Some(in_flight)
          refresh_bar_if_shown()
        },
        on_tool_process=handle => {
          runner.phase = match handle {
            Some(running) => {
              // The block appears now, open, counting. It is appended rather than patched into an
              // existing node because nothing has been sent for this tool yet: a tool is one block
              // from start to finish, and this is its start.
              tool_seq += 1
              let id = tool_block_id(index, tool_seq)
              let since = @env.now().reinterpret_as_int64()
              open_tool = Some(id)
              // A tool starting is what tells the reader the previous one is over and done with, so
              // it is also what puts the previous one away. The instruction travels on this frame
              // rather than in a patch of its own: one frame, one row of the conversation moving.
              let file = file_next
              file_next = None
              match file {
                Some(_) =>
                  // The first finished tool creates the fold, because a fold with nothing in it is a
                  // lie about what the turn has done — it appears when there is a first thing to
                  // put in it, and not a moment before.
                  if work is None {
                    let work_id = @html.live_work_id(index)
                    work = Some(work_id)
                    app.hub.broadcast(
                      @html.append_node(
                        stream_root,
                        @html.render_work(
                          work_id,
                          @html.live_work_label_id(index),
                          @html.live_work_label(filed),
                          [],
                        ),
                      ).to_scoped_sse(session),
                    )
                  }
                None => ()
              }
              app.hub.broadcast(
                @html.append_node(
                  stream_root,
                  @html.render_running_tool(
                    id,
                    running.name,
                    running.arguments,
                    since,
                    file~,
                    file_into=match work {
                      Some(work_id) => work_id
                      None => ""
                    },
                  ),
                ).to_scoped_sse(session),
              )
              // The label counts what is inside the fold, and it is replaced on its own: replacing
              // the fold would take with it the blocks the browser has been moving in.
              match file {
                Some(_) => {
                  filed += 1
                  app.hub.broadcast(
                    @html.replace_node(
                      @html.live_work_label_id(index),
                      @html.render_work_label(
                        @html.live_work_label_id(index),
                        @html.live_work_label(filed),
                      ),
                    ).to_scoped_sse(session),
                  )
                }
                None => ()
              }
              // Recorded as soon as it is sent, so a browser that connects or switches back while
              // the tool is still running is given the same block — same id, same start time, so
              // its clock agrees with the one the browser at the other end is already showing.
              // The driver runs its tools one at a time, so at most one block is open at once;
              // that is what lets a report be matched to its start by order rather than by id.
              runner.trace(
                @html.RunningTool(
                  id~,
                  name=running.name,
                  arguments=running.arguments,
                  since~,
                ),
              )
              "running \{running.name}: \{running.detail}"
            }
            None => "waiting for the model"
          }
          runner.tool = handle
          refresh_tasks()
        },
      )
      flushing = false
      // Whatever the timer had not sent yet, so the snapshot a switch renders is complete.
      flush_open()
      finished
    })
    runner.session = result.session
    runner.in_flight_session = None
    app.hub.broadcast(
      @html.replace_node(
        @html.exchange_id(index),
        // The whole exchange, not just its blocks, and through the same function a reloaded
        // transcript goes through. The footer used to be the only thing written twice — once here
        // and once in `render_exchange` — with the streaming path copying that function's markup by
        // hand, which is exactly the shape of bug where a turn reads one way the moment it finishes
        // and another way after a refresh. There is now one rendering of an exchange, and this is
        // the id it is swapped in at.
        //
        // The consequence is that the fold over the working is closed here whatever the reader did
        // with the live blocks, which is the intended behaviour: a finished turn shows its answer.
        @html.render_exchange(
          index,
          Some(text),
          @html.reply_pieces(result.session.context().messages),
          stats=Some(@html.turn_stats_of(result.session.context().messages)),
        ),
      ).to_scoped_sse(session),
    )
    status(status_text(result, runner.aborting.value))
  } catch {
    err => {
      log("turn failed: \{err}")
      // The live containers are temporary. A turn that failed still wrote what it managed to
      // produce to the log, so the exchange is rebuilt from there — the same rendering a reader
      // gets on reconnect, which is now the same function the successful path uses. Leaving the
      // live nodes in place is what an expandable with nothing in it looks like: they were opened
      // lazily and may never have received a flush.
      app.hub.broadcast(
        @html.replace_node(
          @html.exchange_id(index),
          // A failed turn is still a turn that was paid for, and the reader deciding whether to
          // retry is the one who needs to know what it cost — which is why the figures are here
          // rather than only on the path that succeeded. Rendered from the newest copy of the log:
          // the driver commits every step as it goes, so `session` is behind the file by however
          // far the turn got, and the call that failed the turn is not in it at all.
          @html.render_exchange(
            index,
            Some(text),
            @html.reply_pieces(runner.latest_log().context().messages),
            stats=Some(
              @html.turn_stats_of(runner.latest_log().context().messages),
            ),
          ),
        ).to_scoped_sse(session),
      )
      status("failed: \{err}")
    }
  } noraise {
    _ => ()
  }
  runner.live = []
  runner.prompt = ""
  runner.phase = ""
  runner.tool = None
  runner.busy = false
  // Dropped with the turn: what it held is now in `session`. Left behind it would answer for a
  // state the session no longer has — after a stop, the driver's last commit is the turn being
  // abandoned, which the panel would then keep reporting as if it were still running.
  runner.in_flight_session = None
  refresh_sidebar()
  refresh_tasks()
  refresh_bar()
  // Unlocked again: the turn is over, so the model can be changed for the next one.
  refresh_picker()
  // And there is nothing left to stop in this session.
  refresh_stop()
  refresh_jobs()
}

///|
/// The id a tool's block carries for its whole life.
///
/// One function because two places build it — the block appended when the tool starts, and the
/// block patched in when it reports — and they have to agree exactly. If they drift, the report is
/// patched at an id that is not on the page, and the client drops a patch whose target is missing
/// without saying anything: the tool's output would simply never appear.
fn tool_block_id(index : Int, seq : Int) -> String {
  "live-tool-\{index}-\{seq}"
}

///|
/// Undo the `-body` suffix a reasoning buffer carries, so the live view can key the piece
/// by the id of the element the *container* has.
fn strip_body_suffix(id : String) -> String {
  if id.has_suffix("-body") {
    id[:id.length() - 5].to_owned()
  } else {
    id
  }
}
