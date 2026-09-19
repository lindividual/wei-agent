///|
/// The agent entry point.
///
/// One prompt, one turn, tools available. This exists to prove the three layers
/// fit together — context derivation, the model call, tool execution, and the
/// session log — rather than to be the finished program.

///|
/// The prompt, and the mode to run it in.
///
/// `--mode tools|code` is the only flag, because it is the one a reader wants a second run of: the
/// saved setting already applies, and a second look at a prompt in the other mode is the reason to
/// type one. Everything left over is the prompt.
fn parse_args(argv : Array[String]) -> (String, @core.ToolMode?) {
  let words : Array[String] = []
  let mut mode : @core.ToolMode? = None
  let mut index = 1
  while index < argv.length() {
    if argv[index] == "--mode" && index + 1 < argv.length() {
      mode = Some(@core.parse_tool_mode(argv[index + 1]))
      index += 2
      continue
    }
    words.push(argv[index])
    index += 1
  }
  let prompt = if words.is_empty() {
    "List the files in the current directory, then read the first one you find and summarize it in one sentence."
  } else {
    words.join(" ")
  }
  (prompt, mode)
}

///|
async fn main {
  let args = @env.args()
  let (prompt, flag_mode) = parse_args(args)
  let home = match @platform.home_dir() {
    Some(home) => home
    None => abort("HOME is not set")
  }
  let key = match @platform.api_key(home) {
    Some(key) => key
    None =>
      abort(
        "no DeepSeek key: set DEEPSEEK_API_KEY, or save one in the settings panel",
      )
  }

  let cwd = @platform.current_dir()
  let timestamp = @env.now().reinterpret_as_int64()
  let session_id = @core.new_entry_id()
  let root = "\{home}/.wei/sessions"
  let path = @core.session_file_path(root, cwd, timestamp, session_id)
  let header : @core.SessionHeader = {
    id: session_id,
    timestamp: @core.format_iso_utc(timestamp),
    cwd,
    parent_session: None,
    version: Some(3),
  }
  @platform.create_session(path, header)

  // The mode is the saved setting, unless the flag says otherwise — the same precedence the server
  // uses, so a one-shot turn runs what the panel is showing.
  let settings = @platform.load_settings(home)
  let mode = match flag_mode {
    Some(mode) => mode
    None => settings.tool_mode
  }
  let tools = @core.tools_for_mode(mode)
  // Same discovery as the server, so a one-shot CLI turn sees the skills and the instructions a
  // web turn would.
  let skills = @platform.discover_skills(cwd, home)
  let instructions = @core.choose_instructions(
    settings,
    @platform.workspace_agents_md(cwd),
  )
  let system_prompt = @core.build_system_prompt(
    cwd,
    tools,
    mode~,
    instructions=instructions.text,
    skills~,
    // Always empty here, because this entry point always starts a new session and a new session has
    // no earlier calls to have used another mode's tools. It is passed anyway so that the prompt this
    // program sends and the one the server sends are assembled by the same function from the same
    // order — the difference between the two would otherwise be invisible until someone taught this
    // one to resume, and then it would be a turn that ignores a mode change.
    stale_tools=@core.stale_tool_names(
      @core.Session::new(header, []).context(),
      tools,
    ),
  )
  let ctx = @agent.AgentContext::new(
    session=@core.Session::new(header, []),
    session_path=path,
    cwd~,
    api_key=key,
    system_prompt~,
    tools~,
  )

  println("prompt   \{prompt}")
  println("mode     \{mode.to_string()} (\{tools.length()} tools)")
  println("cwd      \{cwd}")
  println("session  \{path}")
  println("")

  let started = @env.now()
  let result = @agent.run_turn(
    ctx,
    prompt,
    timestamp,
    // A session started here is empty — nothing has recorded a level — so this is the build's
    // default, named by the catalog rather than as a literal in a third front end.
    thinking_level=@core.default_thinking_level(),
  )
  let elapsed = @env.now() - started

  println("")
  for reply in result.replies {
    println("── reply ──")
    println(reply)
  }
  println("")
  println(
    "model calls \{result.model_calls}, tool calls \{result.tool_calls}, \{elapsed}ms",
  )
  println("session entries \{result.session.entries.length()}")
  // What each request had in common with the last, which is the other half of what the call
  // cost: the provider reads the shared prefix from cache and charges the rest as fresh input.
  // A turn whose requests are all append-only should show every change at the end of the
  // previous request; a rewrite anywhere earlier is billed from there to the end of the request.
  for i, drift in result.request_drift {
    if !drift.comparable {
      println(
        "request \{i}: \{drift.messages} messages, \{drift.bytes} bytes (first of the turn)",
      )
    } else {
      println(
        "request \{i}: \{drift.messages} messages, \{drift.bytes} bytes, changed \{drift.changed_bytes} from message \{drift.first_changed} of \{drift.previous_messages}\{if drift.appended_only() { " (append-only)" } else { " (REWROTE)" }}",
      )
    }
  }

  // Report what the log actually contains, since that is the artifact everything
  // else is derived from.
  let context = result.session.context()
  // The anchored figure, so this agrees with what the web UI shows and with what the
  // compaction decision uses. The raw heuristic here was what printed "~10 tokens" for a
  // conversation whose request carried 1,300 tokens of prompt and tool schemas.
  let pressure = @core.context_pressure(
    context.messages,
    @core.request_overhead_tokens(system_prompt, tools),
  )
  let (_, report) = @core.trim_context_reporting(
    context.messages,
    @core.TrimPolicy::default(),
  )
  println(
    "context \{context.messages.length()} messages, ~\{pressure.tokens} tokens (heuristic ~\{pressure.estimated}, trimmed to ~\{report.after_tokens})",
  )
}
