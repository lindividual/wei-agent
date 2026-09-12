///|
/// Rendering the conversation.
///
/// Two decisions shape everything here.
///
/// First, reasoning and tool calls are collapsed by default using the native
/// `<details>` element. The alternative — tracking which blocks are open in a
/// model — was worth several hundred lines in the client-side version of this UI,
/// and it bought nothing: the browser already knows how to remember that.
///
/// Second, nothing here holds state. A render call takes data and returns a
/// string; the question "what is on screen" is answered by asking the server.

///|
/// A short alias so `text(...)` stays available as a value name.
pub fn txt(value : String) -> Node {
  text(value)
}

///|
/// Render markdown, falling back to escaped text if the parser refuses.
///
/// A malformed document should degrade to showing the source, not to showing
/// nothing and not to taking the turn down.
pub fn markdown_or_text(source : String) -> Node {
  try @cmark_html.render(source, safe=true) catch {
    _ => text(source)
  } noraise {
    html => raw(html)
  }
}

///|
/// One content block.
///
/// `id` lets a later patch target this block, which is how the streaming text
/// gets replaced with rendered markdown when it finishes.
pub fn render_block(id : String, block : @core.Content) -> Node {
  match block {
    @core.Text(source) =>
      el("div", attrs=[cls("text"), attr("id", id)], children=[
        markdown_or_text(source),
      ])
    @core.Thinking(thinking~, ..) =>
      el("details", attrs=[cls("thinking"), attr("id", id)], children=[
        el("summary", children=[txt("thinking")]),
        el("div", attrs=[cls("body")], children=[markdown_or_text(thinking)]),
      ])
    @core.ToolCall(name~, arguments~, ..) =>
      el("details", attrs=[cls("tool"), attr("id", id)], children=[
        el("summary", children=[txt(name)]),
        el("pre", attrs=[cls("args")], children=[txt(arguments.stringify())]),
      ])
    @core.Image(..) =>
      el("div", attrs=[cls("image")], children=[txt("(image attachment)")])
  }
}

///|
/// A tool call together with the result that answered it.
///
/// Both live inside one `<details>` because that is how a reader thinks about
/// them: the call and what came back are one event, not two.
pub fn render_tool(
  id : String,
  call : @core.Content,
  result : @core.ToolResultMessage?,
) -> Node {
  let (name, arguments) = match call {
    @core.ToolCall(name~, arguments~, ..) => (name, arguments.stringify())
    _ => ("tool", "")
  }
  let children : Array[Node] = [
    el("summary", children=[txt(name)]),
    el("pre", attrs=[cls("args")], children=[txt(arguments)]),
  ]
  match result {
    Some(r) => {
      let classes = if r.is_error { "result error" } else { "result" }
      let body : Array[Node] = []
      for block in r.content {
        match block {
          @core.Text(source) =>
            body.push(el("pre", attrs=[cls(classes)], children=[txt(source)]))
          _ => ()
        }
      }
      if body.is_empty() {
        body.push(
          el("pre", attrs=[cls(classes)], children=[txt("(no output)")]),
        )
      }
      children.push(el("div", attrs=[cls("result-body")], children=body))
    }
    // No result yet: the tool is running, or the process died before it finished.
    // Either way the call is worth showing.
    None =>
      children.push(
        el("div", attrs=[cls("pending")], children=[txt("running…")]),
      )
  }
  el("details", attrs=[cls("tool"), attr("id", id)], children~)
}

///|
/// One unit of assistant output.
pub fn render_piece(id : String, piece : Piece) -> Node {
  match piece {
    Plain(block~) => render_block(id, block)
    Tool(call~, result~) => render_tool(id, call, result)
  }
}

///|
/// A user message plus everything the assistant produced in response.
pub fn render_exchange(
  index : Int,
  user : String,
  pieces : Array[Piece],
) -> Node {
  let blocks : Array[Node] = []
  for i in 0..<pieces.length() {
    blocks.push(render_piece("b\{index}-\{i}", pieces[i]))
  }
  el("section", attrs=[cls("exchange"), attr("id", "exchange-\{index}")], children=[
    el("div", attrs=[cls("user")], children=[markdown_or_text(user)]),
    el("div", attrs=[cls("blocks")], children=blocks),
  ])
}

///|
/// The page shell.
///
/// `style` and `client` are inlined rather than served as separate files: the
/// whole point of this design is one binary with no build step and no asset
/// directory to get out of sync.
pub fn render_page(
  title : String,
  style : String,
  client : String,
  body : Array[Node],
) -> Node {
  el("html", attrs=[attr("lang", "en")], children=[
    el("head", children=[
      el("meta", attrs=[attr("charset", "utf-8")]),
      el("meta", attrs=[
        attr("name", "viewport"),
        attr("content", "width=device-width, initial-scale=1"),
      ]),
      el("title", children=[txt(title)]),
      el("style", children=[raw(style)]),
    ]),
    el("body", children=[frag(body), el("script", children=[raw(client)])]),
  ])
}

// ── Incremental rendering ──────────────────────────────────────────────────
//
// The transcript is built up in two steps per turn: the user's message appears
// as soon as it is sent, and the reply is appended into the same section when the
// turn finishes. Appending rather than replacing the section is what keeps
// scroll position and any `<details>` the reader opened exactly as they were.

///|
pub fn exchange_id(index : Int) -> String {
  "exchange-\{index}"
}

///|
pub fn blocks_id(index : Int) -> String {
  "exchange-\{index}-blocks"
}

///|
/// The user's message plus an empty container for the reply to land in.
pub fn render_exchange_start(index : Int, user : String) -> Node {
  el("section", attrs=[cls("exchange"), attr("id", exchange_id(index))], children=[
    el("div", attrs=[cls("user")], children=[markdown_or_text(user)]),
    el("div", attrs=[cls("blocks"), attr("id", blocks_id(index))]),
  ])
}

///|
/// The reply, ready to be appended inside a section's blocks container.
///
/// `start` offsets the block ids so a second append into the same section cannot
/// collide with the first.
pub fn render_reply(index : Int, start : Int, pieces : Array[Piece]) -> Node {
  let nodes : Array[Node] = []
  for i in 0..<pieces.length() {
    nodes.push(render_piece("b\{index}-\{start + i}", pieces[i]))
  }
  frag(nodes)
}

///|
/// A status line for the reader — shown while a turn runs, so a slow model does
/// not look like a frozen page.
pub fn render_status(text_value : String) -> Node {
  el("div", attrs=[cls("status"), attr("id", "status")], children=[
    txt(text_value),
  ])
}
