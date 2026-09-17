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
/// The DeepSeek key, from the environment or the settings file.
async fn api_key(home : String) -> String? {
  match @env.get_env_var("DEEPSEEK_API_KEY") {
    Some(k) if k != "" => Some(k)
    _ =>
      match @platform.load_settings(home).saved_api_key {
        key if key != "" => Some(key)
        _ => None
      }
  }
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
    None =>
      abort(
        "no DeepSeek key: set DEEPSEEK_API_KEY, or save one in the settings panel",
      )
  }

  let spec : @core.RequestSpec = {
    model: @core.default_model_id(),
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
    // From the catalog rather than restated: this binary's whole job is to prove the real chain
    // works, so it must price the call the way every other caller does.
    model=@core.default_model_id(),
    timestamp=@env.now().reinterpret_as_int64(),
    pricing=@core.default_model().pricing,
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
