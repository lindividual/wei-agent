///|
/// A minimal DeepSeek client, used to prove the pieces work end to end.
///
/// This is a smoke test, not the eventual entry point: it sends one prompt,
/// prints the reply and the billing breakdown, and stops. Its value is that it
/// exercises the real path — request built by `core`, sent by `platform`,
/// response parsed back by `core` — against the live API rather than a fixture.
///
///   moon run cli -- "explain what a monad is in one sentence"

///|
fn field(j : Json, key : String) -> Json? {
  match j {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
fn string_field(j : Json, key : String) -> String? {
  match field(j, key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// Read the DeepSeek key from pi's credential store, falling back to the
/// environment so the tool works outside a configured pi install.
async fn api_key(home : String) -> String? {
  let from_env = @env.get_env_var("DEEPSEEK_API_KEY")
  match from_env {
    Some(k) if k != "" => return Some(k)
    _ => ()
  }
  let path = "\{home}/.pi/agent/auth.json"
  if !@fs.exists(path) {
    return None
  }
  let store = @json.parse(@fs.read_file(path).text())
  let provider = match field(store, "deepseek") {
    Some(p) => p
    None => return None
  }
  string_field(provider, "key")
}

///|
fn print_usage(usage : @core.Usage) -> Unit {
  let reasoning = match usage.reasoning {
    Some(n) => n.to_string()
    None => "absent"
  }
  println(
    "tokens  input=\{usage.input} cache_read=\{usage.cache_read} output=\{usage.output} reasoning=\{reasoning}",
  )
  println("cost    $\{usage.cost.total}")
}

///|
async fn main {
  let args = @env.args()
  let prompt = if args.length() > 1 {
    args[1]
  } else {
    "Reply with exactly: ready"
  }
  let home = match @env.get_env_var("HOME") {
    Some(h) => h
    None => abort("HOME is not set")
  }
  let key = match api_key(home) {
    Some(k) => k
    None => abort("no DeepSeek key: set DEEPSEEK_API_KEY or log in with pi")
  }

  let spec : @core.RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [
      @core.User({
        content: [@core.Text(prompt)],
        timestamp: @env.now().reinterpret_as_int64(),
      }),
    ],
    system_prompt: Some("You are a coding agent. Answer concisely."),
    tools: [],
    // Reasoning on, at the level the catalog actually supports.
    thinking: @core.deepseek_v4_thinking_levels().resolve(Some("high")),
    max_tokens: None,
    temperature: None,
    // deepseek-v4-flash declares text-only input.
    vision: false,
  }
  let body = @core.build_deepseek_request(spec)

  println("→ POST https://api.deepseek.com/chat/completions")
  println("  request \{body.stringify().length()} bytes")

  let started = @env.now()
  let response = @platform.post_json(
    "https://api.deepseek.com/chat/completions",
    headers=Map([
      ("Authorization", "Bearer \{key}"),
      ("Content-Type", "application/json"),
    ]),
    body=body.stringify(),
  )
  let elapsed = @env.now() - started
  println(
    "← HTTP \{response.status} in \{elapsed}ms, \{response.body.length()} bytes",
  )

  if response.status != 200 {
    println(response.body)
    abort("request failed with status \{response.status}")
  }

  let message = @core.parse_deepseek_stream(
    response.body,
    api="openai-completions",
    provider="deepseek",
    model="deepseek-v4-flash",
    timestamp=@env.now().reinterpret_as_int64(),
    pricing=@core.deepseek_v4_flash_pricing(),
  )

  match message {
    @core.Assistant(assistant) => {
      println("")
      for block in assistant.content {
        match block {
          @core.Thinking(thinking~, ..) => {
            println("── thinking ──")
            println(thinking)
          }
          @core.Text(text) => {
            println("── reply ──")
            println(text)
          }
          @core.ToolCall(id~, name~, arguments~) => {
            println("── tool call \{name} (\{id}) ──")
            println(arguments.stringify())
          }
          @core.Image(..) => ()
        }
      }
      println("")
      println("stopReason  \{assistant.stop_reason}")
      match assistant.raw_stop_reason {
        Some(raw) => println("rawReason   \{raw}")
        None => ()
      }
      print_usage(assistant.usage)
    }
    _ => abort("expected an assistant message")
  }
}
