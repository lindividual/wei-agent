///|
/// The regions: the title above the conversation, the figures under the composer, the model picker
/// beside them, the two side panels, the transcript.
///
/// Each of these is something the browser can be sent a patch for, so each is a function from the
/// app's state to a node. Nothing here decides anything about a turn or a request — it renders what
/// `session.mbt` says is true and what `turn.mbt` has produced.
///
/// The one structural rule is what is *not* a region: the composer is not, because replacing it would
/// take whatever the reader is typing with it. The three regions that sit in or beside it are — the
/// figures, the model picker and Stop — which is why each is patched on its own rather than as part
/// of the form around it.

///|
/// Take the process table the job panel filters against.
async fn refresh_live_pids(app : App) -> Unit {
  let pids : Array[Int] = []
  for entry in @platform.process_table() {
    pids.push(entry.0)
  }
  app.live_pids = pids
}

///|
/// Write the job records out, if they have changed since the last write.
///
/// The comparison is what keeps this from being a file write every few seconds: the supervisor
/// refreshes the panel on a timer whether or not anything happened, and a store that is rewritten
/// unchanged on every tick would put the disk and the modification time to work for nothing.
///
/// A failed write is logged and otherwise ignored. The records are a convenience for the next
/// start — losing them costs the ability to find an orphan, not the running process itself — so a
/// full disk must not become a failed turn.
async fn App::save_jobs(self : App) -> Unit {
  let text = self.jobs.to_json().stringify()
  if text == self.saved_jobs {
    return
  }
  try @platform.save_jobs(self.home, self.jobs) catch {
    err => log("could not record background jobs: \{@core.error_text(err)}")
  } noraise {
    _ => self.saved_jobs = text
  }
}

///|
/// Mark last run's jobs that no longer have a process behind them.
///
async fn App::reconcile_jobs(self : App) -> Unit {
  refresh_live_pids(self)
  let lost = self.jobs.reconcile(
    pid => self.still_running(pid),
    @env.now().reinterpret_as_int64(),
  )
  if lost > 0 {
    log("jobs     \{lost} from a previous run are gone; recorded as lost")
  }
  // Written back immediately, so the file never claims a job is running after the start that
  // reconciled it decided otherwise.
  self.save_jobs()
}

///|
/// Whether a pid is one the reader would find if they looked now.
fn App::still_running(self : App, pid : Int) -> Bool {
  for live in self.live_pids {
    if live == pid {
      return true
    }
  }
  false
}

///|
/// The background panel, as HTML: the jobs that are still running.
///
/// A finished job is not passed on at all. The record stays in the store — it is how a restart
/// accounts for a process it did not start, and how a kill still reaches every pid — but the panel
/// answers "what is still running", and a card for work that is over would push the session list
/// down to say nothing. How it ended is on its own line in the log and in the tool result.
fn render_jobs(app : App, now : Int64) -> String {
  let items : Array[@html.JobItem] = []
  for job in app.jobs.list() {
    if !job.is_live() {
      continue
    }
    // Every pid ever seen, minus the ones that are gone: a command is recorded with its own shell
    // and with the `ps` helper that reported it, and neither is what the reader is looking for.
    let pids : Array[Int] = []
    for pid in job.pids {
      if app.still_running(pid) {
        pids.push(pid)
      }
    }
    items.push({
      id: job.id,
      label: job.label,
      kind: job.kind,
      status: job.status.to_string(),
      age_ms: job.age_ms(now),
      pids,
      session: job.session,
    })
  }
  @html.render_jobs(items, now).render()
}

///|
/// The tasks panel, as HTML. Empty when nothing is running.
fn render_tasks(app : App, _shown : Runner) -> String {
  let items : Array[@html.TaskItem] = []
  for runner in app.registry {
    if runner.is_running() {
      items.push({
        path: runner.path,
        label: @html.clip_label(runner.prompt),
        session: session_tag(runner.path),
        phase: runner.phase,
        since: runner.since,
        queued: runner.waiting,
      })
    }
  }
  @html.render_tasks(items).render()
}

///|
/// The session's title, pinned above the conversation.
///
/// What is left of the information bar once its figures followed the input they describe: the
/// model is on the picker under the composer, the tokens and cost are beside it, and the one fact
/// that has to stay at the top is which conversation this is. The path stays one hover away rather
/// than in the line — the reader who needs it is looking for the file, not reading the page.
///
/// The wording is the sidebar's, through `App::session_label` and then `@html.display_label`: the
/// name the reader gave, else the first question, else the words a session with nothing in it is
/// shown under. One rule for both places, because they are the same answer to the same question —
/// a reader who renames a session in the list sees the line above the conversation change with it,
/// and a reader comparing the two is checking that they agree.
///
/// `modified_of` is how the cache is asked, the same way the delete notice asks it: the sidebar has
/// already listed this session by the time the title is built, so the answer is a map lookup rather
/// than a read of the file.
async fn title_node(app : App, shown : Runner) -> @html.Node {
  let label = app.session_label(shown.path, app.labels.modified_of(shown.path))
  @html.render_title(@html.display_label(label), shown.path)
}

///|
/// The picker's region, as one patch. Used by the region snapshot and by the two places that
/// change the picker alone — a successful switch, and a refused one that has to put the control
/// back on what the session is actually running.
fn picker_patch(app : App, shown : Runner) -> @html.Patch {
  let _ = app
  @html.Patch::Replace(
    target="model-picker",
    html=@html.render_model_picker(model_picker(app, shown)).render(),
  )
}

///|
/// Stop's region, as one patch: live while a turn is running in this session, disabled otherwise.
/// Replaced on its own for the same reason the picker is — rebuilding the composer around it would
/// replace the textarea and take whatever the reader is typing with it.
fn stop_patch(shown : Runner) -> @html.Patch {
  @html.Patch::Replace(
    target="stop",
    html=@html.stop_button(shown.is_running()).render(),
  )
}

///|
/// The picker beside the composer.
///
/// Built from the session being displayed, so it shows that session's model rather than the
/// process default's — two sessions on two models is the thing this feature exists for, and a
/// picker that showed one while the other ran would be worse than no picker.
///
/// A session whose log names a model this build does not have is shown with that id as the
/// selected option, listed alongside the known ones. Removing it would silently move the session
/// to a different model on the next click of an unrelated control; leaving it means the reader
/// sees what the log says and can pick a model that exists.
fn model_picker(_app : App, shown : Runner) -> @html.ModelPicker {
  let models = @core.model_catalog()
  if !@core.is_known_model(shown.model_id) {
    let unknown : @core.ModelSpec = {
      ..@core.default_model(),
      id: shown.model_id,
      name: "\{shown.model_id} (unknown)",
    }
    models.insert(0, unknown)
  }
  { current_id: shown.model_id, models, locked: shown.is_running(), }
}

///|
/// Just the usage chips, as the region a turn refreshes.
///
/// Separate from the composer so that a turn moving a number does not rebuild it — and therefore
/// does not touch whatever the reader is typing.
async fn usage_node(app : App, shown : Runner) -> @html.Node {
  @html.render_usage(
    usage_chips(
      @core.model_spec_for(shown.model_id).0.context_window,
      app.overhead_tokens(app.system_prompt(shown)),
      shown,
    ),
  )
}

///|
/// What the session has used and spent, and how full its context is.
///
/// The totals come from the log (`Session::usage`), so they are the same after a restart as
/// before one. They are read from the newest copy of it (`Runner::latest_log`), which during a turn
/// means the calls that have already come back: each one's tokens, cache reads and context are
/// known the moment the response ends, and a twenty-round turn that reported them only at the end
/// would spend the whole turn showing the figures of the previous one. The context figure is the
/// one that changes what happens next: it is compared against the point where compaction would kick
/// in, and marked when that is close.
///
/// The window is passed in rather than looked up here, because it belongs to the session's model
/// and this function should not have to decide which model that is: the caller already did, and
/// passing it keeps the arithmetic testable with a window small enough to cross the threshold.
fn usage_chips(
  window : Int,
  /// Tokens every request carries outside the conversation: the system prompt and the tool
  /// schemas. Passed in rather than computed here because only the caller knows the tools and
  /// the skills, and the context figure is wrong without it.
  overhead : Int,
  shown : Runner,
) -> Array[@html.Node] {
  let session = shown.latest_log()
  let usage = session.usage()
  // Nothing to report yet: no turn has run here. Four chips reading `0` are noise on the one line
  // a reader looks at to see what is open, and they were most of what an empty session showed.
  //
  // The context figure is allowed through earlier than the others, because a window can be nearly
  // full without a turn having run in *this* process — a resumed conversation is exactly that case,
  // and it is the case where the number changes what happens next.
  let has_spend = usage.replies > 0
  let has_conversation = !session.context().messages.is_empty()
  if !has_spend && !has_conversation {
    return []
  }
  // The anchored figure rather than the raw heuristic: the provider reported the true size of the
  // last request, and only what has been appended since has to be guessed. Measured over real
  // sessions, the heuristic alone is 17% low on average and 63% at worst; anchored, it is 0.2%.
  let pressure = @core.context_pressure(
    session.prepared_context().messages,
    overhead,
  )
  let context = pressure.tokens
  let compact_soon = @core.should_compact(
    context,
    window,
    reserve_tokens=@core.CompactionSettings::for_window(window).reserve_tokens,
  )
  let tokens_detail = "input \{usage.input} · output \{usage.output}" +
    (if usage.reasoning > 0 { " · reasoning \{usage.reasoning}" } else { "" }) +
    " · over \{usage.replies} reply/ies"
  let cache_detail = "read \{usage.cache_read} · written \{usage.cache_write}" +
    (match
      @core.format_cache_hit_percent(usage.cache_read, usage.billed_input()) {
      Some(percent) => " · \{percent}% of the prompt came from cache"
      None => ""
    }) +
    " · a cache read is billed at a fraction of fresh input"
  let cost_detail = "input $\{@core.format_cost(usage.cost.input)}" +
    " · output $\{@core.format_cost(usage.cost.output)}" +
    " · cache read $\{@core.format_cost(usage.cost.cache_read)}" +
    " · total $\{@core.format_cost(usage.cost.total)}"
  let chips : Array[@html.Node] = []
  // All three are about what was spent, so all three wait for something to have been spent. They
  // appear together: `cost` without `tokens` would leave the reader asking what was bought.
  if has_spend {
    chips.push(
      @html.chip(
        "tokens",
        "\{@html.compact_number(usage.input)} in / \{@html.compact_number(usage.output)} out",
        detail=tokens_detail,
      ),
    )
    chips.push(
      @html.chip(
        "cache",
        match
          @core.format_cache_hit_percent(usage.cache_read, usage.billed_input()) {
          Some(percent) =>
            "\{@html.compact_number(usage.cache_read)} · \{percent}% hit"
          None => @html.compact_number(usage.cache_read)
        },
        detail=cache_detail,
      ),
    )
    chips.push(
      @html.chip(
        "cost",
        "$\{@core.format_cost(usage.cost.total)}",
        detail=cost_detail,
      ),
    )
  }
  chips.push(
    @html.chip_meter(
      "context",
      "\{@html.compact_number(context)} / \{@html.compact_number(window)}",
      context.to_double() / window.to_double(),
      warn=compact_soon,
      // Honest about where the number came from, because the two are not equally good: an
      // anchored figure is the provider's own count of the last request plus a small delta, while
      // an estimated one is a heuristic that runs about a fifth low. A reader deciding whether to
      // trust the margin deserves to know which they are looking at.
      detail=(if compact_soon {
          "compaction will summarize the older half of this conversation on the next turn"
        } else {
          match pressure.source {
            @core.Provider =>
              "measured: the provider's prompt size for the last request, plus what has been added since"
            @core.Estimated =>
              "estimated from the messages the next request would send; no response has reported a size yet"
          }
        }) +
        " · the system prompt and tool schemas are included (~\{@html.compact_number(overhead)} tokens)",
    ),
  )
  chips
}

///|
/// The tag a client compares scoped frames against.
///
/// One producer, because the contract is a string equality spanning two files and two languages: the
/// transcript advertises this string in `data-shown-session`, and every scoped frame has to carry the
/// *same* one or the client drops it. Dropping is silent — the frame is well-formed and is simply not
/// for this page — so a mismatch does not look like an error, it looks like a corner of the screen
/// that never changes.
///
/// The short id and not the path, because 80 bytes of path on every frame of a stream is the largest
/// single cost in the envelope. That is exactly what makes `to_scoped_sse(shown.path)` look right and
/// be always wrong.
///
/// (The sidebar shows this id too, for a session nobody has named. Same string, different reason: one
/// is what the reader reads, this is what the browser matches.)
fn session_tag(path : String) -> String {
  short_id(path)
}

///|
/// The id part of a session file name: `…_ab12cd34.jsonl` becomes `ab12cd34`.
fn short_id(path : String) -> String {
  let name = match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
  let stem = if name.has_suffix(".jsonl") {
    name[:name.length() - 6].to_owned()
  } else {
    name
  }
  match stem.rev_find("_") {
    Some(index) => stem[index + 1:].to_owned()
    None => stem
  }
}

///|
/// The whole conversation as it stands, including a turn that is still running.
fn transcript_node(app : App, shown : Runner) -> @html.Node {
  let extra : Array[@html.Node] = []
  if shown.busy {
    // A reader who switches back to a running turn should see its work rather than an
    // empty exchange — including before the first delta arrives, since the question is
    // not in the committed conversation yet either. The container carries the ids the
    // live patches target, so the output keeps arriving into the same nodes.
    let running = @html.render_running_exchange(
      shown.turn,
      shown.prompt,
      shown.live,
    )
    extra.push(running)
  } else if shown.session.turn_in_flight() {
    // The turn never finished, and nothing is running now. The notice offers the two ways out,
    // and it is only shown when the session is idle: offering "continue" next to a turn that is
    // already running would be offering something the reader cannot have.
    extra.push(
      @html.render_interrupted(
        match shown.session.in_flight_prompt() {
          Some(prompt) if prompt != "" => @html.clip_label(prompt, limit=120)
          _ => "(the prompt was not recorded)"
        },
      ),
    )
  }
  @html.render_transcript(
    shown.session.context().messages,
    // The same tag the scoped frames carry: the browser compares them, so they have to agree.
    session=session_tag(shown.path),
    extra~,
    limit=app.depth_of(shown),
  )
}
