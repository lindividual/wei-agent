///|
/// The web UI: an agent, its session, and an HTTP server, in one process and one
/// binary.
///
/// The server is the only writer of the document. The browser applies patches and
/// posts prompts; it holds no model of the conversation, so there is nothing for
/// it and the server to disagree about.

///|
/// A one-way flag the running turn polls.
struct AbortFlag {
  mut value : Bool
}

///|
fn field(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
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
/// The assistant output produced after the last user message.
///
/// Only the tail is needed: earlier turns are already on screen, and re-sending
/// them would duplicate the transcript.
fn last_reply(session : @core.Session) -> Array[@html.Piece] {
  let messages = session.context().messages
  let mut start = 0
  for i in 0..<messages.length() {
    match messages[i] {
      @core.User(_) => start = i
      _ => ()
    }
  }
  // Collect the assistant blocks and the tool results that answer them.
  let blocks : Array[@core.Content] = []
  let results : Array[@core.ToolResultMessage] = []
  for i in start..<messages.length() {
    match messages[i] {
      @core.Assistant(assistant) =>
        for block in assistant.content {
          blocks.push(block)
        }
      @core.ToolResult(result) => results.push(result)
      _ => ()
    }
  }
  @html.pair_tools(blocks, results)
}

///|
/// The whole conversation, for the initial page load and for reconnects.
fn render_transcript(session : @core.Session) -> @html.Node {
  let messages = session.context().messages
  let sections : Array[@html.Node] = []
  let mut index = 0
  let mut pending_user : String? = None
  let mut blocks : Array[@core.Content] = []
  let mut results : Array[@core.ToolResultMessage] = []

  fn flush(
    sections : Array[@html.Node],
    index : Int,
    user : String?,
    blocks : Array[@core.Content],
    results : Array[@core.ToolResultMessage],
  ) -> Unit {
    match user {
      None => ()
      Some(text) =>
        sections.push(
          @html.render_exchange(index, text, @html.pair_tools(blocks, results)),
        )
    }
  }

  for message in messages {
    match message {
      @core.User(user) => {
        flush(sections, index, pending_user, blocks, results)
        index += 1
        pending_user = Some(
          match user.content {
            [@core.Text(text), ..] => text
            _ => ""
          },
        )
        blocks = []
        results = []
      }
      @core.Assistant(assistant) =>
        for block in assistant.content {
          blocks.push(block)
        }
      @core.ToolResult(result) => results.push(result)
      _ => ()
    }
  }
  flush(sections, index, pending_user, blocks, results)
  @html.el("div", attrs=[@html.attr("id", "transcript")], children=sections)
}

///|
async fn main raise {
  let home = match @env.get_env_var("HOME") {
    Some(home) => home
    None => abort("HOME is not set")
  }
  let key = match api_key(home) {
    Some(key) => key
    None => abort("no DeepSeek key: set DEEPSEEK_API_KEY or log in with pi")
  }
  let port = 8790

  let cwd = @platform.current_dir()
  let started = @env.now().reinterpret_as_int64()
  let session_id = @core.new_entry_id()
  let session_path = @core.session_file_path(
    "\{home}/.pi-mb/sessions",
    cwd,
    started,
    session_id,
  )
  let header : @core.SessionHeader = {
    id: session_id,
    timestamp: @core.format_iso_utc(started),
    cwd,
    parent_session: None,
    version: Some(3),
  }
  @platform.create_session(session_path, header)

  let tools = @core.builtin_tools()
  let system_prompt = @core.build_system_prompt(cwd, tools)
  let hub = @server.Hub::new()
  let mut session = @core.Session::new(header, [])
  let mut turn = 0
  // Shared with the running turn. A cell rather than a `Ref` so there is nothing
  // to import, and mutable rather than a channel because the check has to be
  // synchronous — it runs inside a read loop.
  let aborting : AbortFlag = { value: false }

  let routes : @server.Routes = {
    page: () => {
      @html.render_page("pi", stylesheet(), client_script(), [
        render_transcript(session),
        composer(),
        @html.render_status(""),
      ]).render()
    },
    prompt: text => {
      aborting.value = false
      turn += 1
      let index = turn
      // The user's own message appears at once; waiting for the turn to finish
      // before showing what was typed reads as a dropped input.
      hub.broadcast(
        @html.append_node(
          "transcript",
          @html.render_exchange_start(index, text),
        ).to_sse(),
      )
      hub.broadcast(@html.Patch::Status(text="working…").to_sse())

      // Streaming text lands in a throwaway container inside the section. When
      // the turn ends, the whole container is replaced by the properly rendered
      // reply — reasoning collapsed, tool calls paired, markdown parsed. The
      // reader sees text appear as it is written and then settle into its final
      // shape, and nothing has to be re-rendered incrementally to get there.
      let stream_root = "streams-\{index}"
      hub.broadcast(
        @html.append_node(
          @html.blocks_id(index),
          @html.el(
            "div",
            attrs=[@html.attr("id", stream_root)],
            children=[],
          ),
        ).to_sse(),
      )

      // A turn makes several model calls when it uses tools, and each one writes
      // its own text. A block is opened lazily, on the first text delta, so a
      // call that only thinks does not leave an empty element behind.
      let mut open_block : @html.StreamBuffer? = None
      let mut stream_seq = 0
      let report : async (@core.StreamEvent) -> Unit = (event) => {
        match event {
          @core.Text(delta~) => {
            let buffer = match open_block {
              Some(existing) => existing
              None => {
                stream_seq += 1
                let id = "stream-\{index}-\{stream_seq}"
                hub.broadcast(
                  @html.append_node(
                    stream_root,
                    @html.el(
                      "div",
                      attrs=[@html.cls("text"), @html.attr("id", id)],
                      children=[],
                    ),
                  ).to_sse(),
                )
                // A small threshold: a short reply is only a few dozen characters, and
                // waiting for 64 of them would mean the reader sees nothing
                // until the turn is over — which is what streaming is for.
                let fresh = @html.StreamBuffer::new(id, threshold=8)
                open_block = Some(fresh)
                fresh
              }
            }
            match buffer.push(delta) {
              Some(patch) => hub.broadcast(patch.to_sse())
              None => ()
            }
          }
          // Reasoning is not streamed: it is collapsed anyway, and pushing it
          // live would put text on screen that the reader is not meant to read.
          @core.Thinking(_) => ()
        }
      }

      let ctx : @agent.AgentContext = {
        session,
        session_path,
        cwd,
        api_key: key,
        base_url: "https://api.deepseek.com",
        model: "deepseek-v4-flash",
        pricing: @core.deepseek_v4_flash_pricing(),
        system_prompt,
        tools,
      }
      let result = @agent.run_turn(
        ctx,
        text,
        @env.now().reinterpret_as_int64(),
        thinking_level="high",
        on_delta=report,
        should_stop=() => aborting.value,
      )
      session = result.session
      // Replace the streamed text with the finished rendering. Doing it in one
      // patch is why the streaming path can be simple: it never has to decide
      // what the final markup looks like.
      hub.broadcast(
        @html.replace_node(
          @html.blocks_id(index),
          @html.el(
            "div",
            attrs=[@html.cls("blocks"), @html.attr("id", @html.blocks_id(index))],
            children=[
              @html.render_reply(index, 0, last_reply(session)),
            ],
          ),
        ).to_sse(),
      )
      let summary = if aborting.value {
        "stopped after \{result.model_calls} model calls"
      } else {
        "model calls \{result.model_calls}, tool calls \{result.tool_calls}"
      }
      hub.broadcast(@html.Patch::Status(text=summary).to_sse())
    },
    abort: () => aborting.value = true,
  }

  log("pi-mb   http://127.0.0.1:\{port}")
  log("cwd     \{cwd}")
  log("session \{session_path}")
  @server.serve(port, hub, routes)
}
