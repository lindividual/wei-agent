///|
/// Channel id shared with the pi extension's WebSocket endpoint (`/pi`).
const WS_ID : String = "pi"

///|
/// Relative URL: the browser resolves it against the page origin, so this
/// follows the page between ws:// and wss:// automatically.
const WS_URL : String = "pi"

///|
/// One renderable unit of assistant output. `Thinking` and `Tool` are
/// collapsed by default; only `Text` renders expanded.
enum Block {
  Thinking(String)
  Text(String)
  Tool(name~ : String, args~ : String, result~ : String, is_error~ : Bool)
} derive(Eq)

///|
/// One user question plus every assistant block it produced. Anchors are
/// numbered per exchange, matching what the user actually asked.
struct Exchange {
  index : Int
  user : String
  blocks : Array[Block]
} derive(Eq)

///|
struct Model {
  exchanges : Array[Exchange]
  draft : String
  running : Bool
} derive(Eq)

///|
/// WebSocket events are flattened into plain variants because rabbita's own
/// `Event` type carries no `Eq` instance.
enum Msg {
  WsMessage(String)
  WsOpened
  WsClosed
  WsErrored
  Draft(String)
  Submit
} derive(Eq)

// ── JSON accessors ─────────────────────────────────────────────────────────

///|
fn jfield(j : Json, key : String) -> Json? {
  if j is Object(obj) { obj.get(key) } else { None }
}

///|
fn jstr(j : Json, key : String) -> String {
  match jfield(j, key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn jbool(j : Json, key : String) -> Bool {
  match jfield(j, key) {
    Some(True) => true
    _ => false
  }
}

///|
fn jarray(j : Json, key : String) -> Array[Json] {
  match jfield(j, key) {
    Some(Array(a)) => a
    _ => []
  }
}

///|
/// The wire `user` field is null for continuation turns, and a string when
/// the message opens a new exchange.
fn juser(j : Json) -> String? {
  match jfield(j, "user") {
    Some(String(s)) => Some(s)
    _ => None
  }
}

// ── Wire → model ───────────────────────────────────────────────────────────

///|
fn parse_block(j : Json) -> Block? {
  match jstr(j, "kind") {
    "thinking" => Some(Thinking(jstr(j, "text")))
    "text" => Some(Text(jstr(j, "text")))
    "tool" =>
      Some(
        Tool(
          name=jstr(j, "name"),
          args=jstr(j, "args"),
          result=jstr(j, "result"),
          is_error=jbool(j, "isError"),
        ),
      )
    _ => None
  }
}

///|
fn parse_blocks(j : Json) -> Array[Block] {
  let out : Array[Block] = []
  for item in jarray(j, "blocks") {
    match parse_block(item) {
      Some(b) => out.push(b)
      None => ()
    }
  }
  out
}

///|
/// Fold one `turn` message into the exchange list: a non-null `user` opens a
/// new exchange, and any blocks extend the current one.
fn append_turn(exchanges : Array[Exchange], j : Json) -> Array[Exchange] {
  let blocks = parse_blocks(j)
  let mut exs = exchanges
  match juser(j) {
    Some(text) =>
      exs = exs + [{ index: exs.length() + 1, user: text, blocks: [] }]
    None => ()
  }
  if blocks.length() > 0 && exs.length() > 0 {
    let n = exs.length()
    let last = exs[n - 1]
    // Copy rather than mutate: the VDOM relies on value equality to skip
    // unchanged subtrees, so in-place edits would hide updates.
    let merged = {
      index: last.index,
      user: last.user,
      blocks: last.blocks + blocks,
    }
    exs = exs[0:n - 1].to_array() + [merged]
  }
  exs
}

///|
fn apply_history(j : Json) -> Array[Exchange] {
  let mut exs : Array[Exchange] = []
  for turn in jarray(j, "turns") {
    exs = append_turn(exs, turn)
  }
  exs
}

// ── update ─────────────────────────────────────────────────────────────────

///|
fn update(
  model : Model,
  msg : Msg,
  _emit : @cmd.Emit[Msg],
) -> (Model, @cmd.Cmd) {
  match msg {
    WsMessage(text) =>
      match (try? @json.parse(text)) {
        Ok(j) =>
          match jstr(j, "kind") {
            "history" => (
              {
                exchanges: apply_history(j),
                draft: model.draft,
                running: jbool(j, "running"),
              },
              @cmd.none,
            )
            "turn" => (
              {
                exchanges: append_turn(model.exchanges, j),
                draft: model.draft,
                running: model.running,
              },
              @cmd.none,
            )
            "status" => (
              {
                exchanges: model.exchanges,
                draft: model.draft,
                running: jbool(j, "running"),
              },
              @cmd.none,
            )
            _ => (model, @cmd.none)
          }
        Err(_) => (model, @cmd.none)
      }
    WsOpened | WsClosed | WsErrored => (model, @cmd.none)
    Draft(s) => (
      { exchanges: model.exchanges, draft: s, running: model.running },
      @cmd.none,
    )
    Submit => {
      let text = model.draft.trim().to_string()
      if text == "" {
        (model, @cmd.none)
      } else {
        let fields : Map[String, String] = { "kind": "prompt", "text": text }
        let payload = @json.to_json(fields).stringify()
        (
          { exchanges: model.exchanges, draft: "", running: model.running },
          @websocket.send(WS_ID, @websocket.Payload::Text(payload)),
        )
      }
    }
  }
}

// ── view ───────────────────────────────────────────────────────────────────

///|
/// Render markdown through cmark. `safe=true` keeps raw HTML in model output
/// from becoming live DOM.
fn markdown(text : String) -> @html.Html {
  let empty : Array[@html.Html] = []
  match (try? @cmark_html.render(text, safe=true)) {
    Ok(html) =>
      @html.div(class="md", attrs=@html.Attrs::build().inner_html(html), empty)
    Err(_) => @html.div(class="md", text)
  }
}

///|
fn render_block(b : Block) -> @html.Html {
  match b {
    Thinking(text) =>
      @html.details(class="block thinking", [
        @html.summary("思考"),
        @html.div(class="body", text),
      ])
    Tool(name~, args~, result~, is_error~) =>
      @html.details(
        class="block tool" + (if is_error { " error" } else { "" }),
        [
          @html.summary(class="head", name),
          @html.pre(class="args", @html.code(args)),
          if result == "" {
            @html.div(class="result empty", "(无输出)")
          } else {
            @html.pre(class="result", @html.code(result))
          },
        ],
      )
    Text(text) => @html.div(class="block text", markdown(text))
  }
}

///|
fn render_exchange(ex : Exchange) -> @html.Html {
  @html.section(id="turn-\{ex.index}", class="exchange", [
    @html.div(class="user", ex.user),
    ..ex.blocks.map(render_block),
  ])
}

///|
fn view(model : Model, emit : @cmd.Emit[Msg]) -> @html.Html {
  @html.div(class="app", [
    @html.nav(class="rail", [
      @html.div(class="rail-title", "#"),
      ..model.exchanges.map(fn(ex) {
        @html.a(href="#turn-\{ex.index}", class="dot", "\{ex.index}")
      }),
    ]),
    @html.div(class="chat", [
      @html.div(class="stream", [
        ..model.exchanges.map(render_exchange),
        if model.running {
          @html.div(class="pending", "生成中…")
        } else {
          @html.nothing
        },
      ]),
      @html.div(class="composer", [
        @html.textarea(
          class="input",
          value=model.draft,
          rows=3,
          placeholder="问点什么…",
          on_input=emit.map(fn(s) { Draft(s) }),
          "",
        ),
        @html.button(
          class="send",
          disabled=model.running || model.draft.trim() == "",
          on_click=emit(Submit),
          "发送",
        ),
      ]),
    ]),
  ])
}

///|
fn initial() -> Model {
  { exchanges: [], draft: "", running: false }
}

///|
/// `connect` (not `listen`) is what registers the socket under `WS_ID`;
/// `send` only resolves ids created this way.
fn connect_cmd(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @websocket.connect(
    WS_ID,
    WS_URL,
    on_event=emit.map(fn(ev) {
      match ev {
        @websocket.Message(text) => WsMessage(text)
        @websocket.Opened => WsOpened
        @websocket.Closed(_) => WsClosed
        @websocket.Errored => WsErrored
      }
    }),
  )
}

///|
/// Root component builder. `create_state_with_init` must run inside the
/// builder — the runtime assigns it a slot when the app mounts, and creating
/// it outside a build pass leaves that slot unresolved.
fn app() -> @rabbita.Val[@html.Html] {
  let (model, emit) = @rabbita.create_state_with_init(
    init=fn(emit) { (initial(), connect_cmd(emit)) },
    update=update,
  )
  model.map(fn(m) { view(m, emit) })
}

///|
fn main {
  @rabbita.new(app).mount("app")
}
