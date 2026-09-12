///|
/// The agent driver: the loop that turns a prompt into a finished turn.
///
/// This is the only place that spans all three layers — it derives context from
/// the session (`core`), calls the model and the tools (`platform`), and decides
/// what happens next (`core`'s state machine).
///
/// The scheduling decisions themselves are not made here. `AgentState` in `core`
/// owns when a queued message is admitted and what a turn boundary means; this
/// file performs the actions it asks for.

///|
/// Everything a turn needs that does not change while it runs.
pub(all) struct AgentContext {
  session : @core.Session
  /// Where the session is persisted. Appends go here as they happen, so a crash
  /// mid-turn leaves a log that `session_repair` can close.
  session_path : String
  cwd : String
  api_key : String
  base_url : String
  model : String
  pricing : @core.Pricing
  /// The model's context window, from the same catalog as the pricing. The only
  /// thing that turns "the conversation is 400k tokens" into a decision.
  context_window : Int
  system_prompt : String
  tools : Array[@core.ToolDef]
  /// Background work this session has started. It lives with the driver rather than with the UI
  /// because the driver is what starts it, and because a record kept by the tool layer would be
  /// lost the moment the tool call returned.
  jobs : @core.JobStore
}

///|
/// Build a context with the DeepSeek defaults.
///
/// Constructing it in one place is what keeps the pricing, the window and the
/// model name from drifting apart: they are three facts about the same model, and
/// a hand-assembled struct can pair the window of one with the pricing of another.
pub fn AgentContext::new(
  session~ : @core.Session,
  session_path~ : String,
  cwd~ : String,
  api_key~ : String,
  system_prompt~ : String,
  tools~ : Array[@core.ToolDef],
  jobs? : @core.JobStore = @core.JobStore::new(),
  model? : String = "deepseek-v4-flash",
  base_url? : String = "https://api.deepseek.com",
  pricing? : @core.Pricing = @core.deepseek_v4_flash_pricing(),
  context_window? : Int = @core.deepseek_v4_flash_context_window(),
) -> AgentContext {
  {
    session,
    session_path,
    cwd,
    api_key,
    base_url,
    model,
    pricing,
    context_window,
    system_prompt,
    tools,
    jobs,
  }
}

///|
/// A tool that is running, with the means to stop it.
///
/// The process is the reason this exists. A `bash` tool can run for minutes, and an abort
/// that only sets a flag leaves the reader waiting for a command they already asked to stop
/// — the flag is checked between steps, and the step in progress *is* the command. Cancelling
/// the task the tool runs in is what reaches the child: the runtime's process cancellation
/// handler is the only thing that knows about it, and it escalates from `SIGTERM` to a kill.
pub(all) struct ToolHandle {
  name : String
  /// One line of what it is doing, for a reader watching.
  detail : String
  stop : () -> Unit
}

///|
/// A tool that has just finished, reported as it happens.
///
/// The reason this exists at all: a turn can spend minutes in tool rounds, and a page
/// that only learns what happened when the turn ends looks frozen for exactly that
/// long. Reporting each result as it lands is what makes the wait legible.
pub(all) struct ToolEvent {
  name : String
  /// The call and its arguments, as the model wrote them.
  call_id : String
  arguments : Json
  /// The result text, already truncated by the tool.
  output : String
  is_error : Bool
} derive(Eq, Debug)

///|
/// What one turn cost, in the units a reader cares about.
pub(all) struct TurnResult {
  session : @core.Session
  /// Assistant text produced during the turn, in order, across any tool rounds.
  replies : Array[String]
  /// How many model calls the turn took.
  model_calls : Int
  /// How many tool calls were executed.
  tool_calls : Int
  /// How many times the conversation was compacted, which is also how many
  /// extra model calls were spent summarizing.
  compactions : Int
  /// Summed over every model call the turn made, compaction included.
  usage : @core.Usage
  /// False when the round limit stopped the turn rather than the model deciding it
  /// was done.
  ///
  /// Reported rather than raised: a model that keeps asking for tools is a thing
  /// the reader should be told about, not a reason to fail the request — and
  /// definitively not a reason to take the process down.
  settled : Bool
} derive(Debug)

///|
fn assistant_text(message : @core.Message) -> String {
  match message {
    Assistant(assistant) => {
      let out = StringBuilder()
      for block in assistant.content {
        match block {
          Text(text) => {
            if out.to_string() != "" {
              out.write_string("\n")
            }
            out.write_string(text)
          }
          _ => ()
        }
      }
      out.to_string()
    }
    _ => ""
  }
}

///|
fn tool_calls_of(message : @core.Message) -> Array[@core.Content] {
  match message {
    Assistant(assistant) => {
      let out : Array[@core.Content] = []
      for block in assistant.content {
        match block {
          ToolCall(..) => out.push(block)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
/// The wall clock, as the log records it.
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
/// Append one entry to the session, both in memory and on disk.
///
/// `timestamp` is the moment the entry describes, not the start of the turn: a turn
/// can spend minutes in tool rounds, and a log that claims every entry of it happened
/// at the same instant cannot be read back to see where the time went.
async fn commit(
  session : @core.Session,
  path : String,
  kind : @core.EntryKind,
  timestamp : Int64,
) -> @core.Session {
  let entry : @core.Entry = {
    id: @core.new_entry_id(),
    parent_id: session.leaf_id,
    timestamp: @core.format_iso_utc(timestamp),
    kind,
  }
  // The header goes in with the first entry, not when the session is opened: a
  // session that is opened and never used is not worth a file, and one that leaves a
  // header-only file behind makes the picker harder to read.
  @platform.ensure_session(path, session.header)
  @platform.append_entry(path, entry)
  // Rebuilding the index per append is fine at this size and keeps the in-memory
  // session a faithful copy of the file.
  let entries : Array[@core.Entry] = []
  for existing in session.entries {
    entries.push(existing)
  }
  entries.push(entry)
  @core.Session::new(session.header, entries)
}

///|
/// Build the request body for one model call.
fn request_for(
  ctx : AgentContext,
  session : @core.Session,
  thinking_level : String?,
) -> Json {
  // Trimming is applied here rather than at commit time: the session keeps every
  // byte and only the request is reduced.
  let prepared = session.prepared_context()
  let spec : @core.RequestSpec = {
    model: ctx.model,
    // Summaries and extension messages are not `Message`s, but the model has to
    // see them as turns; `core` owns that mapping because the framing is part of
    // the wire format, not a choice the driver gets to make.
    messages: prepared.messages_for_model(),
    system_prompt: Some(ctx.system_prompt),
    tools: ctx.tools,
    thinking: @core.deepseek_v4_thinking_levels().resolve(thinking_level),
    max_tokens: None,
    temperature: None,
    vision: false,
  }
  @core.build_deepseek_request(spec)
}

///|
/// POST one prepared body and parse the response as it arrives.
///
/// Shared by the reply path and the summarization path: the only difference
/// between them is what the caller does with the finished message.
async fn request_model(
  ctx : AgentContext,
  body : String,
  timestamp : Int64,
  on_delta : async (@core.StreamEvent) -> Unit,
  stopping : () -> Bool,
) -> @core.Message {
  let parser = @core.StreamParser::new(
    api="openai-completions",
    provider="deepseek",
    model=ctx.model,
    timestamp~,
    pricing=ctx.pricing,
  )
  @platform.post_sse(
    "\{ctx.base_url}/chat/completions",
    Map([
      ("Authorization", "Bearer \{ctx.api_key}"),
      ("Content-Type", "application/json"),
    ]),
    body,
    chunk => {
      for event in parser.feed(chunk) {
        on_delta(event)
      }
    },
    should_stop=stopping,
  )
  // A stream the caller stopped reading is recorded as aborted rather than as a
  // truncated response, which is what pi writes for the same event.
  parser.finish(aborted=stopping())
}

///|
/// Call the model once and append the result.
///
/// The response is parsed as it arrives so `on_delta` can report content while
/// the model is still writing. The parser is the same one the one-shot tests
/// exercise — feeding it incrementally is checked to produce an identical message,
/// so streaming does not get a second, unverified implementation.
async fn call_model(
  ctx : AgentContext,
  session : @core.Session,
  thinking_level : String?,
  timestamp : Int64,
  on_delta : async (@core.StreamEvent) -> Unit,
  stopping : () -> Bool,
) -> (@core.Session, @core.Message) {
  let body = request_for(ctx, session, thinking_level)
  let message = request_model(
    ctx,
    body.stringify(),
    timestamp,
    on_delta,
    stopping,
  )
  let updated = commit(
    session,
    ctx.session_path,
    @core.Message(message~),
    // When the response finished, not when the request went out.
    now_ms(),
  )
  (updated, message)
}

///|
/// The text of a tool result, for callers that only show it.
fn tool_output_text(output : @core.ToolOutput) -> String {
  let out = StringBuilder()
  for block in output.content {
    match block {
      Text(text) => {
        if out.to_string() != "" {
          out.write_string("\n")
        }
        out.write_string(text)
      }
      _ => ()
    }
  }
  out.to_string()
}

///|
/// Total the usage of two model calls.
fn add_usage(total : @core.Usage, next : @core.Usage) -> @core.Usage {
  {
    input: total.input + next.input,
    output: total.output + next.output,
    cache_read: total.cache_read + next.cache_read,
    cache_write: total.cache_write + next.cache_write,
    reasoning: None,
    total_tokens: total.total_tokens + next.total_tokens,
    cost: {
      input: total.cost.input + next.cost.input,
      output: total.cost.output + next.cost.output,
      cache_read: total.cost.cache_read + next.cost.cache_read,
      cache_write: total.cost.cache_write + next.cost.cache_write,
      total: total.cost.total + next.cost.total,
    },
  }
}

///|
fn usage_of(message : @core.Message) -> @core.Usage {
  match message {
    Assistant(assistant) => assistant.usage
    _ => @core.Usage::zero()
  }
}

///|
/// Summarize the old half of the conversation when the next request would not
/// fit in the model's window.
///
/// The decision and the cut belong to `core`; this only performs them. The
/// summary is written as a `compaction` entry whose `first_kept_entry_id` leaves
/// the recent tail untouched, which is what makes the compaction reversible in
/// the only sense that matters: the summarized entries are still in the file.
///
/// Returns the same session, unchanged, unless a summary was actually recorded.
async fn compact_if_needed(
  ctx : AgentContext,
  session : @core.Session,
  timestamp : Int64,
) -> (@core.Session, @core.Usage, Bool) {
  let zero = @core.Usage::zero()
  let settings = @core.CompactionSettings::for_window(ctx.context_window)
  // Against the trimmed context, because trimming is free and runs first: if
  // dropping old tool output already brought the request under the threshold,
  // paying for a summary would be paying for nothing.
  let prepared = session.prepared_context()
  let tokens = @core.estimate_context_tokens(prepared.messages)
  if !settings.should_compact(tokens, ctx.context_window) {
    return (session, zero, false)
  }
  let cut = match
    @core.find_cut_point(
      session.context_entries(),
      keep_recent_tokens=settings.keep_recent_tokens,
    ) {
    None => return (session, zero, false)
    Some(cut) => cut
  }
  let summarizing = session.messages_before(cut.first_kept_entry_id)
  if summarizing.is_empty() {
    // Nothing before the cut. A summary here would replace the conversation with
    // a summary of itself.
    return (session, zero, false)
  }
  let messages = @core.context_messages_for_model(summarizing)
  messages.push(
    @core.Message::User({
      content: [@core.Text(@core.summarization_prompt())],
      timestamp,
    }),
  )
  let spec : @core.RequestSpec = {
    model: ctx.model,
    messages,
    // No system prompt and no tools: this call is asked to condense, and the
    // agent's instructions would only invite it to keep working.
    system_prompt: None,
    tools: [],
    thinking: @core.Thinking::Disabled,
    max_tokens: None,
    temperature: None,
    vision: false,
  }
  let body = @core.build_deepseek_request(spec)
  let discard : async (@core.StreamEvent) -> Unit = fn(_event) { () }
  let message = request_model(ctx, body.stringify(), timestamp, discard, () => {
    false
  })
  let prose = assistant_text(message)
  if prose == "" {
    // A failed summarization call must not throw away the history it was meant to
    // replace. Nothing is recorded, and the turn proceeds with a big context —
    // the provider may reject it, which is a visible failure rather than a
    // silent loss.
    return (session, usage_of(message), false)
  }
  // The prose plus what must survive verbatim: file paths, commands, errors, and
  // whatever the agent explicitly asked to keep with a note.
  let summary = @core.assemble_summary(
    prose,
    @core.extract_facts(summarizing),
    session.agent_notes(),
  )
  let updated = commit(
    session,
    ctx.session_path,
    @core.Compaction(
      summary~,
      first_kept_entry_id=cut.first_kept_entry_id,
      tokens_before=cut.tokens_before,
      details=None,
      usage=Some(usage_of(message)),
      from_hook=Some(false),
    ),
    now_ms(),
  )
  (updated, usage_of(message), true)
}

///|
/// Execute every tool call from one assistant message, appending each result.
///
/// Calls run in the order the model asked for them. The scheduler's segmentation
/// is applied for its ordering guarantee, but the calls are executed one at a
/// time: with 88.7% of real batches being a single call, concurrency would add
/// machinery for a case that rarely arises. The segmentation is still worth
/// having, because it is what a future concurrent executor would consult.
async fn run_tools(
  ctx : AgentContext,
  session : @core.Session,
  message : @core.Message,
  timestamp : Int64,
  report : async (ToolEvent) -> Unit,
  /// Told what is running, so a stop can reach it. `None` when nothing is.
  publish : async (ToolHandle?) -> Unit,
) -> (@core.Session, Int) {
  let calls = tool_calls_of(message)
  if calls.is_empty() {
    return (session, 0)
  }
  let plans : Array[@core.ToolCallPlan] = []
  for block in calls {
    let name = match block {
      @core.ToolCall(name~, ..) => name
      _ => ""
    }
    let safe = match @core.builtin_tool(name) {
      Some(tool) => tool.concurrency is @core.Safe
      None => false
    }
    plans.push({ name, is_concurrency_safe: safe, })
  }
  // The shape is not used to reorder execution today; computing it keeps the
  // policy exercised and would be the input to a parallel executor.
  ignore(@core.plan_shape(plans))

  let mut current = session
  let mut executed = 0
  for block in calls {
    let (id, name, arguments) = match block {
      @core.ToolCall(id~, name~, arguments~) => (id, name, arguments)
      _ => ("", "", Json::object(Map([])))
    }
    // Background work is accounted for per session, and dsh's admission rule is adopted whole:
    // past the limit the command is refused with an instruction to clean up, because "start
    // another background job" must not become a way to accumulate processes nobody counts.
    let job_id : String? = if name == "bash" {
      if ctx.jobs.live_count(ctx.session_path) >=
        @core.max_live_jobs_per_session() {
        let refusal = @core.Message::ToolResult({
          tool_call_id: id,
          tool_name: name,
          content: [
            @core.Text(
              "Refused: this session already has \{@core.max_live_jobs_per_session()} processes running in the background. Stop one of them in the sidebar before starting another.",
            ),
          ],
          is_error: true,
          timestamp,
          details: None,
        })
        current = commit(
          current,
          ctx.session_path,
          @core.Message(message=refusal),
          now_ms(),
        )
        continue
      }
      Some(
        ctx.jobs.start(
          kind="bash",
          label=@core.tool_summary(arguments),
          session=ctx.session_path,
          started_at=now_ms(),
          pids=[],
        ),
      )
    } else {
      None
    }
    // Run the tool in a task of its own so that it can be cancelled on its own: cancelling the
    // turn would abandon the partial answer the reader has already seen, and a stop should still
    // leave an aborted turn in the log.
    let output = @async.with_task_group(group => {
      let task = group.spawn(() => {
        try
          @platform.execute_tool(name, arguments, ctx.cwd, watcher={
            started: pids => {
              match job_id {
                Some(id) => ctx.jobs.observe(id, pids, tail="")
                None => ()
              }
            },
            finished: outcome => {
              match job_id {
                Some(id) => {
                  ctx.jobs.observe(id, outcome.children, tail="")
                  if outcome.lingering.is_empty() {
                    // Finished and left nothing behind: not background work, so the record goes.
                    // A panel that listed every tool call would be a log, not an answer.
                    ctx.jobs.forget(id)
                  } else {
                    // Still running, which is the whole point of the record.
                    ctx.jobs.observe(id, outcome.lingering, tail="")
                  }
                }
                None => ()
              }
            },
          })
        catch {
          err =>
            // A cancelled tool is an answer too: the model is told the command was stopped
            // rather than the turn dying with an exception.
            if @async.is_cancellation_error(err) {
              match job_id {
                Some(id) => {
                  // The runtime killed the shell; what the command had already started has to be
                  // killed here, by pid, because nothing else knows about it.
                  //
                  // Protected from cancellation because this *is* the cancellation path: every
                  // await inside a cancelled coroutine raises at once, and killing a process is a
                  // spawn. Without the protection the cleanup itself would be cancelled, leaving
                  // exactly the orphan the record was meant to prevent.
                  let pids = ctx.jobs.request_stop(id)
                  ignore(
                    @async.protect_from_cancel(() => @platform.kill_pids(pids)),
                  )
                  ctx.jobs.finish(
                    id,
                    Killed,
                    detail="stopped before it finished",
                    finished_at=now_ms(),
                  )
                }
                None => ()
              }
              @core.ToolOutput::error("stopped before it finished")
            } else {
              raise err
            }
        } noraise {
          result => result
        }
      })
      publish(
        Some({
          name,
          detail: @core.tool_summary(arguments),
          stop: () => task.cancel(),
        }),
      )
      let finished = task.wait()
      publish(None)
      finished
    })
    report({
      name,
      call_id: id,
      arguments,
      output: tool_output_text(output),
      is_error: output.is_error,
    })
    // A note is a request to persist something, so it becomes a session entry
    // rather than a tool result the model reads back.
    if name == "note" && !output.is_error {
      match output.details {
        Some(Object(fields)) =>
          match fields.get("note") {
            Some(String(text)) =>
              current = commit(
                current,
                ctx.session_path,
                @core.Custom(
                  custom_type=@core.agent_note_type(),
                  data=Some(Json::object(Map([("text", Json::string(text))]))),
                ),
                now_ms(),
              )
            _ => ()
          }
        _ => ()
      }
    }
    executed += 1
    let result_message = @core.Message::ToolResult({
      tool_call_id: id,
      tool_name: name,
      content: output.content,
      is_error: output.is_error,
      timestamp,
      details: output.details,
    })
    current = commit(
      current,
      ctx.session_path,
      @core.Message(message=result_message),
      now_ms(),
    )
  }
  (current, executed)
}

///|
/// Run one turn: send the prompt, then keep going while the model asks for tools.
///
/// The loop is bounded by the model stopping rather than by a step count. A model
/// that never stops would spin forever, which is a real risk with a small model; the
/// bound below makes that a bounded, reported outcome rather than an infinite one.
pub async fn run_turn(
  ctx : AgentContext,
  prompt : String,
  timestamp : Int64,
  thinking_level? : String,
  max_rounds? : Int = 40,
  on_delta? : async (@core.StreamEvent) -> Unit,
  should_stop? : () -> Bool,
  /// Called after each tool finishes, for a caller rendering the turn live.
  ///
  /// Async because rendering means writing to a socket, and the same shape as
  /// `on_delta` for the same reason.
  on_tool? : async (ToolEvent) -> Unit,
  /// Called with the tool that is running, then with `None` when it stops. Async because the
  /// caller usually has to tell someone.
  on_tool_process? : async (ToolHandle?) -> Unit,
  /// Called after each round with (model calls, tool calls) so far.
  on_progress? : async (Int, Int) -> Unit,
) -> TurnResult {
  // Streaming is optional: a caller that only wants the finished turn passes
  // nothing, and a caller rendering live passes the same callback this loop uses.
  let report : async (@core.StreamEvent) -> Unit = match on_delta {
    Some(callback) => callback
    None => fn(_event) { () }
  }
  let stopping = match should_stop {
    Some(check) => check
    None => fn() { false }
  }
  // A caller that does not render live gets a callback that does nothing; the
  // annotation is left off because a body with nothing to await does not need it.
  let tool_report : async (ToolEvent) -> Unit = match on_tool {
    Some(callback) => callback
    None => fn(_event) { () }
  }
  let progress : async (Int, Int) -> Unit = match on_progress {
    Some(callback) => callback
    None => fn(_calls, _tools) { () }
  }
  let publish : async (ToolHandle?) -> Unit = match on_tool_process {
    Some(callback) => callback
    None => fn(_handle) { () }
  }
  let level = thinking_level
  // Record the model and thinking level before anything else. pi derives these
  // from the log rather than from configuration, so a session that does not
  // record them reads back as `off` on whatever model the reader defaults to —
  // the settings would be silently lost on resume.
  let existing = ctx.session.context()
  let mut session = ctx.session
  if existing.model is None {
    session = commit(
      session,
      ctx.session_path,
      @core.ModelChange(provider="deepseek", model_id=ctx.model),
      timestamp,
    )
  }
  let level_name = match level {
    Some(name) => name
    None => "off"
  }
  if existing.thinking_level != level_name {
    session = commit(
      session,
      ctx.session_path,
      @core.ThinkingLevelChange(level=level_name),
      timestamp,
    )
  }
  session = commit(
    session,
    ctx.session_path,
    @core.Message(
      message=@core.User({ content: [@core.Text(prompt)], timestamp, }),
    ),
    timestamp,
  )

  let replies : Array[String] = []
  let mut model_calls = 0
  let mut tool_calls = 0
  let mut compactions = 0
  let mut usage = @core.Usage::zero()
  let mut rounds = 0

  while rounds < max_rounds {
    // Checked before each model call, so a stop requested during a tool round takes
    // effect at the next boundary rather than cutting a tool off mid-write.
    if stopping() {
      break
    }
    // Before the request rather than after the turn: a tool round can double the
    // context, and by then the next request has to fit in what is left.
    let (compacted, spent, happened) = compact_if_needed(
      ctx, session, timestamp,
    )
    if happened {
      compactions += 1
    }
    session = compacted
    usage = add_usage(usage, spent)
    rounds += 1
    let (updated, message) = call_model(
      ctx, session, level, timestamp, report, stopping,
    )
    session = updated
    model_calls += 1
    usage = add_usage(usage, usage_of(message))
    let text = assistant_text(message)
    if text != "" {
      replies.push(text)
    }
    if tool_calls_of(message).is_empty() || stopping() {
      break
    }
    let (after_tools, executed) = run_tools(
      ctx, session, message, timestamp, tool_report, publish,
    )
    session = after_tools
    tool_calls += executed
    // After the round, not before: the counts are what the reader watches to tell
    // "still working on something" from "stuck".
    progress(model_calls, tool_calls)
  }
  // One last report, so a caller that only watches progress sees the finished counts
  // rather than the ones from before the final model call.
  progress(model_calls, tool_calls)
  {
    session,
    replies,
    model_calls,
    tool_calls,
    compactions,
    usage,
    settled: rounds < max_rounds,
  }
}
