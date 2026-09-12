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
async fn main {
  let args = @env.args()
  let prompt = if args.length() > 1 {
    args[1]
  } else {
    "List the files in the current directory, then read the first one you find and summarize it in one sentence."
  }
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

  let tools = @core.builtin_tools()
  let ctx = @agent.AgentContext::new(
    session=@core.Session::new(header, []),
    session_path=path,
    cwd~,
    api_key=key,
    system_prompt=@core.build_system_prompt(cwd, tools),
    tools~,
  )

  println("prompt   \{prompt}")
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

  // Report what the log actually contains, since that is the artifact everything
  // else is derived from.
  let context = result.session.context()
  let usage = @core.estimate_context_tokens(context.messages)
  let (_, report) = @core.trim_context_reporting(
    context.messages,
    @core.TrimPolicy::default(),
  )
  println(
    "context \{context.messages.length()} messages, ~\{usage} tokens (trimmed to ~\{report.after_tokens})",
  )
}
