///|
/// The agent entry point.
///
/// One prompt, one turn, tools available. This exists to prove the three layers
/// fit together — context derivation, the model call, tool execution, and the
/// session log — rather than to be the finished program.

///|
fn field(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
/// The DeepSeek key, from the environment or pi's credential store.
async fn api_key(home : String) -> String? {
  match @env.get_env_var("DEEPSEEK_API_KEY") {
    Some(key) if key != "" => return Some(key)
    _ => ()
  }
  let path = "\{home}/.pi/agent/auth.json"
  if !@platform.path_exists(path) {
    return None
  }
  let store = @json.parse(@platform.read_text(path))
  let provider = match field(store, "deepseek") {
    Some(value) => value
    None => return None
  }
  match field(provider, "key") {
    Some(String(key)) => Some(key)
    _ => None
  }
}

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
  let home = match @env.get_env_var("HOME") {
    Some(home) => home
    None => abort("HOME is not set")
  }
  let key = match api_key(home) {
    Some(key) => key
    None => abort("no DeepSeek key: set DEEPSEEK_API_KEY or log in with pi")
  }

  let cwd = @platform.current_dir()
  let timestamp = @env.now().reinterpret_as_int64()
  let session_id = @core.new_entry_id()
  let root = "\{home}/.pi-mb/sessions"
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
  let system_prompt = @core.build_system_prompt(cwd, tools, mode~, sections=[
    instructions.text,
    @core.skill_catalog_prompt(skills),
  ])
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
  let result = @agent.run_turn(ctx, prompt, timestamp, thinking_level="high")
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
