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
/// Constructing it in one place is what keeps the pricing, the window and the model name from
/// drifting apart: they are three facts about the same model, and a hand-assembled struct can pair
/// the window of one with the pricing of another.
///
/// The defaults are *the catalog's* default model rather than three restated values. A second copy
/// of a number is a second thing to get out of step, and this is the copy a caller that passes
/// nothing gets — so it would have been the one that went stale first. A caller naming a different
/// model passes all three (the UI does, from the session's own choice); the catalog test pins the
/// default entry to the accessors these used to hardcode.
pub fn AgentContext::new(
  session~ : @core.Session,
  session_path~ : String,
  cwd~ : String,
  api_key~ : String,
  system_prompt~ : String,
  tools~ : Array[@core.ToolDef],
  jobs? : @core.JobStore = @core.JobStore::new(),
  model? : String = @core.default_model_id(),
  base_url? : String = "https://api.deepseek.com",
  pricing? : @core.Pricing = @core.default_model().pricing,
  context_window? : Int = @core.default_model().context_window,
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
  /// The call as the model wrote it.
  ///
  /// Carried alongside `detail` rather than instead of it, because the two answer different
  /// questions and the page asks both: `detail` is the one-line form for the sidebar's "what is it
  /// doing", and this is what the tool's own block shows — the same raw arguments the finished
  /// block shows, so a block that is still running looks like one that has finished rather than
  /// like a thinner, separate thing.
  arguments : Json
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
  /// False when a limit stopped the turn rather than the model deciding it was done.
  ///
  /// Reported rather than raised: a model that keeps asking for tools is a thing
  /// the reader should be told about, not a reason to fail the request — and
  /// definitively not a reason to take the process down.
  settled : Bool
  /// True when the cost limit is what stopped it, so the reader is told which guard fired.
  /// A turn can be expensive without making many calls — one large request against a pricier
  /// model costs more than fifty small ones — so the two limits do not imply each other.
  cost_limit_hit : Bool
  /// True when the time limit is what stopped it. Separate from `cost_limit_hit` for the same
  /// reason the two limits are separate: they fail for different reasons and the reader's response
  /// to each is different.
  time_limit_hit : Bool
  /// The model's final answer was cut off at the output token limit rather than finishing.
  ///
  /// Reported because a truncated answer looks exactly like a finished one. The model cannot say
  /// "I was interrupted" — the interruption is the end of what it wrote — so unless the caller
  /// notices the stop reason, the reader is left with a sentence that stops mid-thought.
  truncated : Bool
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
    // Asked of the catalog rather than written down here, so the decision to send an image and the
    // model it is sent to cannot disagree. A model that cannot see gets the placeholder, which is
    // how a pasted screenshot still leaves a trace in the conversation.
    vision: @core.model_sees_images(ctx.model),
  }
  @core.build_deepseek_request(spec)
}

///|
/// How many times one model call is attempted before the turn gives up on it.
///
/// Four means one attempt and three retries. Chosen against the two things being traded off: a
/// connection that is refused fails in under a second, so three retries cost a few seconds and
/// usually save the turn; a run of attempts that each block until the idle timeout costs
/// minutes, which is why the count is small rather than generous.
fn model_attempts() -> Int {
  4
}

///|
/// How long to wait before attempt `n`, counting the first retry as 1.
///
/// Doubling, capped: a brief blip is retried almost at once, and a longer outage is not met with
/// a tight loop that hammers an endpoint which is already unwell. The total wait for three
/// retries is about seven seconds.
fn retry_delay_ms(attempt : Int) -> Int {
  let mut delay = 1000
  let mut i = 1
  while i < attempt {
    delay = delay * 2
    i = i + 1
  }
  if delay > 8000 {
    8000
  } else {
    delay
  }
}

///|
/// POST one prepared body and parse the response as it arrives.
///
/// Shared by the reply path and the summarization path: the only difference
/// between them is what the caller does with the finished message.
///
/// A failed call is retried when trying again could plausibly work, which is most of what makes
/// a turn survive a flaky connection. Three things stop the retry, and each of them is about not
/// making things worse:
///
/// - The endpoint said something permanent (a bad key, a context that is too long). Asking again
///   gets the same answer, so the error is raised as it stands.
/// - The reader has already seen output. A retry replays the response from the beginning, so
///   text the browser has already rendered would be followed by the same text again. Once
///   anything has been emitted, the turn reports the failure instead.
/// - The reader stopped it. Retrying a request nobody is waiting for is work done for its own
///   sake.
async fn request_model(
  ctx : AgentContext,
  body : String,
  timestamp : Int64,
  on_delta : async (@core.StreamEvent) -> Unit,
  stopping : () -> Bool,
) -> @core.Message {
  let url = "\{ctx.base_url}/chat/completions"
  let headers : Map[String, String] = Map([
    ("Authorization", "Bearer \{ctx.api_key}"),
    ("Content-Type", "application/json"),
  ])
  let mut attempt = 1
  while true {
    // A fresh parser per attempt. The previous one may hold half a stream, and feeding a second
    // response into it would splice two answers together into one message.
    let parser = @core.StreamParser::new(
      api="openai-completions",
      provider="deepseek",
      model=ctx.model,
      timestamp~,
      pricing=ctx.pricing,
    )
    // A cell rather than a captured local: the flag is written inside the callback and read
    // after the call returns, and a reference makes that sharing unambiguous.
    let emitted = Ref(false)
    let report : async (@core.StreamEvent) -> Unit = async fn(event) {
      emitted.val = true
      on_delta(event)
    }
    let outcome : Result[@core.Message, String] = try {
      @platform.post_sse(
        url,
        headers,
        body,
        chunk => {
          for event in parser.feed(chunk) {
            report(event)
          }
        },
        should_stop=stopping,
      )
      // A stream the caller stopped reading is recorded as aborted rather than as a
      // truncated response, which is what pi writes for the same event.
      Ok(parser.finish(aborted=stopping()))
    } catch {
      @platform.Transient(message) => Err(message)
      // Permanent, or anything else: not retryable, so it is reported as it is.
      @platform.Permanent(message) => raise Failure::Failure(message)
      err => raise err
    } noraise {
      result => result
    }
    match outcome {
      Ok(message) => return message
      Err(message) => {
        if emitted.val || stopping() || attempt >= model_attempts() {
          // `emitted` is worth saying out loud: the turn did produce output, so the failure is
          // reported as an interruption rather than as a call that never worked.
          let suffix = if emitted.val {
            " (after the response had already started)"
          } else {
            ""
          }
          raise Failure::Failure(
            "\{message}; gave up after \{attempt} attempt(s)\{suffix}",
          )
        }
        @async.sleep(retry_delay_ms(attempt))
        attempt = attempt + 1
      }
    }
  }
  // Unreachable: the loop returns or raises on every path. Present so the function has a
  // definite result for the compiler.
  abort("request_model: retry loop exited")
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
/// Whether the model stopped because it ran out of output budget rather than because it was done.
///
/// Read from the response's own stop reason, which is the only place the difference is recorded.
fn cut_off_at_limit(message : @core.Message) -> Bool {
  match message {
    Assistant(assistant) => assistant.stop_reason is @core.Length
    _ => false
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
  // The anchored figure, not the raw heuristic. The threshold is a hard boundary — crossing it is
  // what buys a summary call — and the heuristic under-counts by about a fifth, so comparing the
  // wrong number against a threshold would compact late. Late is the expensive direction: it is
  // the request that overflows, and an overflow is refused rather than summarized.
  let pressure = @core.context_pressure(
    prepared.messages,
    @core.request_overhead_tokens(ctx.system_prompt, ctx.tools),
  )
  if !settings.should_compact(pressure.tokens, ctx.context_window) {
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
    // The summarizer reads the same conversation as the turn, so it needs the same answer: a
    // conversation with an image in it has to survive summarization as a placeholder rather than
    // being sent to a model that would reject it.
    vision: @core.model_sees_images(ctx.model),
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
            // A tool that failed is an answer too, and for the same reason a cancelled one is:
            // the model is told what went wrong instead of the turn dying with an exception. A
            // single unreadable file — a binary reached by `read`, a decode error in `grep` —
            // used to take the whole turn down with it, leaving the reader with an error and no
            // reply. The exception is reported as the tool's error output, where the model can
            // react to it, and `max_rounds` still bounds a model that keeps retrying.
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
              @core.ToolOutput::error("the tool failed: \{err}")
            }
        } noraise {
          result => result
        }
      })
      publish(
        Some({
          name,
          detail: @core.tool_summary(arguments),
          arguments,
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
///
/// The bound is generous — 200 model calls — because a tool-heavy turn legitimately takes
/// many of them, and stopping one at 40 cut work off in the middle of a task that was
/// going fine. Reaching 200 is no longer "a long turn"; it means the model is looping,
/// which is what the limit is for.
///
/// There are two limits, and the second is the one that actually bounds the bill. A turn can
/// be expensive without being long: one request against a large cached-then-uncached context
/// costs more than fifty small ones, so counting calls does not bound spending. `max_cost`
/// does, using the per-model pricing the turn already sums.
///
/// Both defaults come from measurement rather than taste: over 2280 real turns the median
/// cost was $0.004, the ninetieth percentile $0.036, and the most expensive $0.295 (147 calls,
/// 93M cached prompt tokens). The longest ran 165 calls. So 200 calls and $1 are each about
/// a turn that never happened — the guards catch a runaway, not a large turn.
pub async fn run_turn(
  ctx : AgentContext,
  prompt : String,
  timestamp : Int64,
  thinking_level? : String,
  /// Most model calls one turn may make. `0` disables the bound.
  max_rounds? : Int = 200,
  /// Most one turn may cost, in US dollars. `0.0` disables the bound.
  max_cost? : Double = 1.0,
  /// Most one turn may take, in seconds. `0` disables the bound.
  ///
  /// The third dimension, and the one the other two cannot see: a command can sit for an hour
  /// making no model calls and costing nothing, while the reader waits. Chosen from measurement
  /// over 50,000 real assistant turns: half finished within 2s and 99% within 50s, but the
  /// longest ran 34 minutes. Half an hour is past everything that was measured and still bounds
  /// what a stuck turn can do to the reader's afternoon.
  max_seconds? : Int = 1800,
  /// Continue a turn that a crash left open, instead of starting a new one.
  ///
  /// The difference is one message. A new turn commits the user's prompt and opens a turn; a
  /// resumed one does neither, because the prompt is already in the log and the turn that needs
  /// closing is the one already open. Everything after that is the same loop, which is the point:
  /// the tool results that *were* recorded stay as they are, so the work already done is not done
  /// twice — the same property DBOS gets from checkpointing steps, which we get from the log.
  continuing? : Bool = false,
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
  // A continued turn appends nothing here: the prompt it is carrying is already the last user
  // message in the log, and appending it again would put the question to the model twice.
  if !continuing {
    session = commit(
      session,
      ctx.session_path,
      @core.Message(
        message=@core.User({ content: [@core.Text(prompt)], timestamp, }),
      ),
      timestamp,
    )
  }
  // The turn is opened in the log before any of its work happens. Between this entry and the
  // outcome written at the end, the turn is durably in flight — which is the only way to tell
  // afterwards that it was interrupted, since a turn stopped by a guard and a turn that finished
  // both end at a message.
  //
  // A continued turn skips this: the turn it is continuing was already opened, and a second opening
  // would leave the log claiming two turns in flight.
  if !continuing {
    // Invariant: at most one turn is ever open. A reader who ignores an interrupted turn and
    // simply types again is choosing to move on, so the old turn is closed here rather than left
    // open forever — otherwise the log would claim two turns in flight and the interruption notice
    // would survive the decision to abandon it.
    if session.turn_in_flight() {
      session = commit(
        session,
        ctx.session_path,
        @core.turn_outcome_entry(
          @core.Abandoned,
          0,
          0.0,
          session.leaf_id,
          timestamp,
        ).kind,
        timestamp,
      )
    }
    session = commit(
      session,
      ctx.session_path,
      @core.Custom(
        custom_type=@core.turn_start_type(),
        data=Some(Json::object(Map([("prompt", Json::string(prompt))]))),
      ),
      timestamp,
    )
  }

  let replies : Array[String] = []
  let mut model_calls = 0
  let mut tool_calls = 0
  let mut compactions = 0
  let mut usage = @core.Usage::zero()
  let mut rounds = 0
  let mut cost_limit_hit = false
  let mut time_limit_hit = false
  let mut truncated = false
  // The deadline is read from the clock here rather than derived from the caller's `timestamp`,
  // which is the time an entry is stamped with and not necessarily "now" — a resumed session can
  // pass an older one. Measuring from this moment is the only reading that bounds how long the
  // reader waits.
  let deadline_ms : Int64 = if max_seconds > 0 {
    now_ms() + max_seconds.to_int64() * 1000L
  } else {
    0L
  }

  while true {
    // Checked before each model call, so a stop requested during a tool round takes
    // effect at the next boundary rather than cutting a tool off mid-write.
    if stopping() {
      break
    }
    // Both limits are checked here, before spending anything. A limit of zero means "no
    // limit" rather than "stop immediately", which is why each is guarded by its own test.
    if max_rounds > 0 && rounds >= max_rounds {
      break
    }
    if max_cost > 0.0 && usage.cost.total >= max_cost {
      cost_limit_hit = true
      break
    }
    if deadline_ms > 0L && now_ms() >= deadline_ms {
      time_limit_hit = true
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
    truncated = cut_off_at_limit(message)
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
  // Write down why the turn ended. A turn always records one — including the ordinary case —
  // because "the log has no outcome" has to mean "this turn never finished", and writing nothing
  // on success would make that phrase describe every turn that went well.
  let ending : @core.TurnEnding = if cost_limit_hit {
    @core.CostLimit
  } else if time_limit_hit {
    @core.TimeLimit
  } else if max_rounds > 0 && rounds >= max_rounds {
    @core.RoundLimit
  } else if stopping() {
    @core.Stopped
  } else if truncated {
    @core.Truncated
  } else {
    @core.Completed
  }
  let session = commit(
    session,
    ctx.session_path,
    @core.turn_outcome_entry(
      ending,
      model_calls,
      usage.cost.total,
      session.leaf_id,
      now_ms(),
    ).kind,
    now_ms(),
  )
  {
    session,
    replies,
    model_calls,
    tool_calls,
    compactions,
    usage,
    // Settled means the model was allowed to finish: it stopped asking for tools, or the
    // reader stopped it. A limit is the one case where it did not get to decide.
    settled: !cost_limit_hit &&
    !time_limit_hit &&
    !(max_rounds > 0 && rounds >= max_rounds),
    cost_limit_hit,
    time_limit_hit,
    truncated,
  }
}
