///|
/// Channel id shared with the pi extension's WebSocket endpoint (`/pi`).
const WS_ID : String = "pi"

///|
/// Id of the zero-height element parked after the last exchange.
const STREAM_END : String = "stream-end"

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
/// One saved session inside a workspace.
struct Session {
  path : String
  label : String
  modified : Int
} derive(Eq)

///|
/// A directory with at least one saved session, as listed by the extension.
struct Workspace {
  cwd : String
  name : String
  active : Bool
  session_count : Int
  last_session : String
  sessions : Array[Session]
} derive(Eq)

///|
/// Another running pi process serving its own web shell.
struct Instance {
  pid : Int
  cwd : String
  port : Int
  current : Bool
} derive(Eq)

///|
struct Model {
  exchanges : Array[Exchange]
  workspaces : Array[Workspace]
  instances : Array[Instance]
  /// Keys of collapsed blocks the user has opened. Collapsed bodies are kept
  /// out of the DOM entirely — with 60KB tool results, rendering them hidden
  /// costs more than the whole rest of the page.
  expanded : Array[String]
  /// Workspaces whose session list is expanded in the sidebar.
  open_workspaces : Array[String]
  /// Path of the session currently open, for highlighting in that list.
  current_session : String
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
  SwitchWorkspace(String)
  ToggleBlock(String)
  ScrollTo(Int)
  ToggleWorkspace(String)
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
fn jint(j : Json, key : String) -> Int {
  match jfield(j, key) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
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

///|
fn parse_workspace(j : Json) -> Workspace? {
  let cwd = jstr(j, "cwd")
  if cwd == "" {
    return None
  }
  Some({
    cwd,
    name: jstr(j, "name"),
    active: jbool(j, "active"),
    session_count: jint(j, "sessionCount"),
    last_session: jstr(j, "lastSession"),
    sessions: parse_sessions(j),
  })
}

///|
fn parse_sessions(j : Json) -> Array[Session] {
  let out : Array[Session] = []
  for item in jarray(j, "sessions") {
    let path_ = jstr(item, "path")
    if path_ != "" {
      out.push({
        path: path_,
        label: jstr(item, "label"),
        modified: jint(item, "modified"),
      })
    }
  }
  out
}

///|
fn parse_workspaces(j : Json) -> Array[Workspace] {
  let out : Array[Workspace] = []
  for item in jarray(j, "workspaces") {
    match parse_workspace(item) {
      Some(w) => out.push(w)
      None => ()
    }
  }
  out
}

///|
fn parse_instances(j : Json) -> Array[Instance] {
  let out : Array[Instance] = []
  for item in jarray(j, "instances") {
    let pid = jint(item, "pid")
    if pid != 0 {
      out.push({
        pid,
        cwd: jstr(item, "cwd"),
        port: jint(item, "port"),
        current: jbool(item, "current"),
      })
    }
  }
  out
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

///|
/// Build a JSON text frame for the bridge.
fn send_json(fields : Map[String, String]) -> @cmd.Cmd {
  @websocket.send(
    WS_ID,
    @websocket.Payload::Text(@json.to_json(fields).stringify()),
  )
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
                ..model,
                exchanges: apply_history(j),
                workspaces: parse_workspaces(j),
                instances: parse_instances(j),
                current_session: jstr(j, "sessionFile"),
                running: jbool(j, "running"),
              },
              // Instant: on first paint the distance can be tens of
              // thousands of pixels, and animating that is just a delay.
              @nav.scroll_to(STREAM_END),
            )
            // A workspace switch delivers a full snapshot under its own kind.
            "workspace_changed" => (
              {
                ..model,
                exchanges: apply_history(j),
                workspaces: parse_workspaces(j),
                instances: parse_instances(j),
                expanded: [],
                current_session: jstr(j, "sessionFile"),
                running: false,
              },
              @nav.scroll_to(STREAM_END),
            )
            "workspaces" => ({ ..model, workspaces: parse_workspaces(j) }, @cmd.none)
            "turn" => (
              { ..model, exchanges: append_turn(model.exchanges, j) },
              @nav.scroll_to(STREAM_END, behavior=Smooth),
            )
            "status" => ({ ..model, running: jbool(j, "running") }, @cmd.none)
            _ => (model, @cmd.none)
          }
        Err(_) => (model, @cmd.none)
      }
    WsOpened | WsClosed | WsErrored => (model, @cmd.none)
    Draft(s) => ({ ..model, draft: s }, @cmd.none)
    Submit => {
      let text = model.draft.trim().to_string()
      if text == "" {
        (model, @cmd.none)
      } else {
        (
          { ..model, draft: "" },
          send_json({ "kind": "prompt", "text": text }),
        )
      }
    }
    SwitchWorkspace(session) => (
      model,
      send_json({ "kind": "switch", "session": session }),
    )
    ToggleBlock(key) =>
      if model.expanded.contains(key) {
        (
          { ..model, expanded: model.expanded.filter(fn(k) { k != key }) },
          @cmd.none,
        )
      } else {
        ({ ..model, expanded: model.expanded + [key] }, @cmd.none)
      }
    // Instant, not smooth: a jump across a long transcript animates for
    // seconds, and navigation should land immediately.
    ScrollTo(n) => (model, @nav.scroll_to("turn-\{n}"))
    ToggleWorkspace(cwd) =>
      if model.open_workspaces.contains(cwd) {
        (
          {
            ..model,
            open_workspaces: model.open_workspaces.filter(fn(c) { c != cwd }),
          },
          @cmd.none,
        )
      } else {
        ({ ..model, open_workspaces: model.open_workspaces + [cwd] }, @cmd.none)
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
fn block_key(ex_index : Int, i : Int) -> String {
  "\{ex_index}:\{i}"
}

///|
/// A collapsed block renders only its header, so its body never reaches the
/// DOM. Tool results routinely run to tens of KB, and with hundreds of them in
/// one session that difference dominates both parse and layout time.
fn render_block(
  ex_index : Int,
  i : Int,
  b : Block,
  expanded : Array[String],
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  match b {
    Text(text) => @html.div(class="block text", markdown(text))
    Thinking(text) =>
      collapsible(block_key(ex_index, i), expanded, "thinking", "思考", text, emit)
    Tool(name~, args~, result~, is_error~) =>
      collapsible(
        block_key(ex_index, i),
        expanded,
        "tool" + (if is_error { " error" } else { "" }),
        name,
        "\{args}\n──────\n\{result}",
        emit,
      )
  }
}

///|
fn collapsible(
  key : String,
  expanded : Array[String],
  cls : String,
  label : String,
  body : String,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let open = expanded.contains(key)
  @html.div(class="block \{cls}" + (if open { " open" } else { "" }), [
    @html.div(class="head", on_click=emit(ToggleBlock(key)), label),
    if open {
      @html.pre(class="body", @html.code(body))
    } else {
      @html.nothing
    },
  ])
}

///|
fn render_exchange(
  ex : Exchange,
  expanded : Array[String],
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let blocks : Array[@html.Html] = []
  for i, b in ex.blocks {
    blocks.push(render_block(ex.index, i, b, expanded, emit))
  }
  @html.section(id="turn-\{ex.index}", class="exchange", [
    @html.div(class="user", ex.user),
    ..blocks,
  ])
}

///|
/// Workspace list, each row expandable into its own session list, plus the
/// other pi processes serving their own shell.
fn sidebar(model : Model, emit : @cmd.Emit[Msg]) -> @html.Html {
  let rows : Array[@html.Html] = []
  for w in model.workspaces {
    let open = model.open_workspaces.contains(w.cwd)
    rows.push(
      @html.div(class="ws" + (if w.active { " active" } else { "" }), [
        // Name area switches to the newest session; the chevron only expands.
        // Nesting buttons is illegal, hence clickable divs.
        @html.div(
          class="ws-main",
          on_click=emit(SwitchWorkspace(w.last_session)),
          [
            @html.div(class="ws-name", w.name),
            @html.div(class="ws-meta", "\{w.session_count} 会话"),
          ],
        ),
        if w.sessions.length() > 1 {
          @html.div(
            class="ws-toggle",
            on_click=emit(ToggleWorkspace(w.cwd)),
            if open { "▾" } else { "▸" },
          )
        } else {
          @html.nothing
        },
      ]),
    )
    if open {
      for sess in w.sessions {
        rows.push(
          @html.div(
            class="sess" +
            (if sess.path == model.current_session { " current" } else { "" }),
            on_click=emit(SwitchWorkspace(sess.path)),
            sess.label,
          ),
        )
      }
    }
  }
  @html.aside(class="sidebar", [
    @html.div(class="side-title", "工作区"),
    ..rows,
    if model.instances.length() > 1 {
      @html.div(class="side-title", "实例 · \{model.instances.length()}")
    } else {
      @html.nothing
    },
    ..model.instances.map(fn(i) {
      @html.div(class="inst" + (if i.current { " current" } else { "" }), [
        @html.div(class="inst-port", ":\{i.port}"),
        @html.div(class="inst-cwd", i.cwd),
      ])
    }),
  ])
}

///|
/// Shared empty children value: the type cannot be inferred from `[]` alone.
let no_children : Array[@html.Html] = []

///|
fn view(model : Model, emit : @cmd.Emit[Msg]) -> @html.Html {
  @html.div(class="app", [
    sidebar(model, emit),
    @html.nav(class="rail", [
      @html.div(class="rail-title", "#"),
      ..model.exchanges.map(fn(ex) {
        // Deliberately not `href="#turn-N"`: the browser's default jump never
        // fired here, so scrolling is driven explicitly instead.
        @html.button(
          class="dot",
          on_click=emit(ScrollTo(ex.index)),
          "\{ex.index}",
        )
      }),
    ]),
    @html.div(class="chat", [
      @html.div(class="stream", [
        if model.exchanges.length() == 0 {
          @html.div(class="empty", [
            @html.div(class="empty-title", "pi-web-shell"),
            @html.div(class="empty-hint", "在下面输入问题，按发送开始对话。"),
          ])
        } else {
          @html.nothing
        },
        ..model.exchanges.map(fn(ex) { render_exchange(ex, model.expanded, emit) }),
        if model.running {
          @html.div(class="pending", "生成中…")
        } else {
          @html.nothing
        },
        // Scroll target for "go to newest". `nav.scroll_to_bottom` only moves
        // the window, and the transcript scrolls inside `.stream`, so the
        // bottom is reached by scrolling this sentinel into view instead.
        @html.div(id=STREAM_END, class="sentinel", no_children),
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
  {
    exchanges: [],
    workspaces: [],
    instances: [],
    expanded: [],
    open_workspaces: [],
    current_session: "",
    draft: "",
    running: false,
  }
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
