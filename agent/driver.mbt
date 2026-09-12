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
  system_prompt : String
  tools : Array[@core.ToolDef]
}

///|
pub(all) struct TurnResult {
  session : @core.Session
  /// Assistant text produced during the turn, in order, across any tool rounds.
  replies : Array[String]
  /// How many model calls the turn took.
  model_calls : Int
  /// How many tool calls were executed.
  tool_calls : Int
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
/// Append one entry to the session, both in memory and on disk.
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
    messages: prepared.messages.map(message => {
      match message {
        @core.User(m) => @core.Message::User(m)
        @core.Assistant(m) => @core.Message::Assistant(m)
        @core.ToolResult(m) => @core.Message::ToolResult(m)
        // Summaries and notes are not `Message`s; a compaction summary reaches the
        // model as a user-visible turn only after it is recorded as one.
        _ =>
          @core.Message::User({
            content: [@core.Text(summary_text(message))],
            timestamp: 0L,
          })
      }
    }),
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
fn summary_text(message : @core.ContextMessage) -> String {
  match message {
    @core.CompactionSummary(summary~, ..) => summary
    @core.BranchSummary(summary~, ..) => summary
    @core.Custom(content~, ..) => content.stringify()
    _ => ""
  }
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
    body.stringify(),
    (chunk) => {
      for event in parser.feed(chunk) {
        (on_delta)(event)
      }
    },
    should_stop=stopping,
  )
  let message = parser.finish()
  let updated = commit(
    session,
    ctx.session_path,
    @core.Message(message~),
    timestamp,
  )
  (updated, message)
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
  for block in calls {
    let (id, name, arguments) = match block {
      @core.ToolCall(id~, name~, arguments~) => (id, name, arguments)
      _ => ("", "", Json::object(Map([])))
    }
    let output = @platform.execute_tool(name, arguments, ctx.cwd)
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
                timestamp,
              )
            _ => ()
          }
        _ => ()
      }
    }
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
      timestamp,
    )
  }
  (current, calls.length())
}

///|
/// Run one turn: send the prompt, then keep going while the model asks for tools.
///
/// The loop is bounded by the model stopping rather than by a step count. A model
/// that never stops would spin forever, which is a real risk with a small model;
/// the bound below exists so that failure is a bounded one.
pub async fn run_turn(
  ctx : AgentContext,
  prompt : String,
  timestamp : Int64,
  thinking_level? : String,
  max_rounds? : Int = 40,
  on_delta? : async (@core.StreamEvent) -> Unit,
  should_stop? : () -> Bool,
) -> TurnResult {
  // Streaming is optional: a caller that only wants the finished turn passes
  // nothing, and a caller rendering live passes the same callback this loop uses.
  let report : async (@core.StreamEvent) -> Unit = match on_delta {
    Some(callback) => callback
    None => async fn(_event) { () }
  }
  let stopping = match should_stop {
    Some(check) => check
    None => fn() { false }
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
  let mut rounds = 0

  while rounds < max_rounds {
    // Checked before each model call, so a stop requested during a tool round takes
    // effect at the next boundary rather than cutting a tool off mid-write.
    if stopping() {
      break
    }
    rounds += 1
    let (updated, message) = call_model(
      ctx,
      session,
      level,
      timestamp,
      report,
      stopping,
    )
    session = updated
    model_calls += 1
    let text = assistant_text(message)
    if text != "" {
      replies.push(text)
    }
    if tool_calls_of(message).is_empty() || stopping() {
      break
    }
    let (after_tools, executed) = run_tools(ctx, session, message, timestamp)
    session = after_tools
    tool_calls += executed
  }
  if rounds >= max_rounds {
    abort("turn did not settle after \{max_rounds} rounds")
  }
  { session, replies, model_calls, tool_calls, }
}
