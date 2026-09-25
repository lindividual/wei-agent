///|
/// MCP: tools from servers the reader configures, loaded on demand.
///
/// The problem this solves is the token budget. A tool declared in the request costs its schema in
/// *every* request, forever, whether the turn uses it or not. The built-in set can afford that — it
/// is eight tools and the descriptions are prompt text worth paying for — but a plugin ecosystem
/// cannot: a GitHub MCP server is three dozen tools and a few thousand tokens a turn, spent on the
/// turns that never touch GitHub. So the schemas do not go in the request at all.
///
/// What goes in the request is a **catalog** — one line per server, plus its tools' names — and a
/// single **gateway** tool. The model reads the catalog and pulls the schemas it wants through the
/// gateway when a task matches one. That is the same shape as a skill's catalog (`core/skill.mbt`):
/// cheap names always present, expensive bodies read on demand, and once a body is in the
/// transcript it stays there — so a server is paid for once, in the turn that uses it.
///
/// **The choice of what to pull is the model's, and that is the point.** A host-side heuristic that
/// matched keywords in the prompt would be an open loop: a miss is silent, the model never learns
/// the server exists, and nothing in the system can observe the miss. The model has the whole
/// conversation and is the better judge of relevance, so the host's job is only to say what is
/// reachable and to correct a call that reaches for something that is not.
///
/// A second consequence is structural: because the server's tools arrive as an *argument* of the
/// gateway rather than as declarations of their own, this turn's tool set stays whatever
/// `tools_for_mode` returned, plus one. `has_tool` needs no change, and no server can shadow `bash`
/// or collide with another server's tool name.
///
/// Everything here is pure — frames, handshake, catalog, refusals — so it is testable against fixed
/// bytes, which is where the protocol's decisions belong. The connection that carries them is
/// `platform/mcp*.mbt`.

// ── The protocol ───────────────────────────────────────────────────────────

///|
/// The MCP revision this client asks for.
///
/// `2024-11-05` rather than the newest revision because support for it is the widest, and because
/// nothing here needs a later one: tools, `tools/list` and `tools/call` have been stable across
/// every revision. A server answers with the revision it will speak and the client decides whether
/// to continue (see `parse_initialize_result`); refusing over a version string would trade a
/// working session for a formality.
pub fn mcp_protocol_version() -> String {
  "2024-11-05"
}

///|
/// The client name and version a server sees in `initialize`.
pub fn mcp_client_name() -> String {
  "wei"
}

///|
pub fn mcp_client_version() -> String {
  "0.1.0"
}

///|
/// A JSON-RPC request. `id` is a number because we only ever send our own.
pub fn mcp_request(id : Int, rpc_method : String, params : Json) -> Json {
  json_obj([
    ("jsonrpc", Json::string("2.0")),
    ("id", Json::number(id.to_double())),
    ("method", Json::string(rpc_method)),
    ("params", params),
  ])
}

///|
/// A JSON-RPC notification: same shape, no `id`, no reply expected.
pub fn mcp_notification(rpc_method : String, params : Json) -> Json {
  json_obj([
    ("jsonrpc", Json::string("2.0")),
    ("method", Json::string(rpc_method)),
    ("params", params),
  ])
}

///|
/// The `initialize` request.
///
/// `capabilities` is empty on purpose. The optional client features — `roots`, `sampling`,
/// `elicitation` — each promise something this client does not do yet, and announcing one would be
/// telling a server to ask for something that never comes back. A server that needs one of them
/// checks the capabilities and knows not to.
pub fn mcp_initialize_request(id : Int) -> Json {
  mcp_request(
    id,
    "initialize",
    json_obj([
      ("protocolVersion", Json::string(mcp_protocol_version())),
      ("capabilities", Json::object(Map([]))),
      (
        "clientInfo",
        json_obj([
          ("name", Json::string(mcp_client_name())),
          ("version", Json::string(mcp_client_version())),
        ]),
      ),
    ]),
  )
}

///|
/// The notification that ends the handshake. Sent after `initialize` is answered, before anything
/// else, because a server is allowed to reject every later request until it has seen this one.
pub fn mcp_initialized_notification() -> Json {
  mcp_notification("notifications/initialized", Json::object(Map([])))
}

///|
/// A `tools/list` request. `cursor` is empty for the first page; a reply's `nextCursor` goes here
/// for the next.
pub fn mcp_list_tools_request(id : Int, cursor : String) -> Json {
  let params = if cursor == "" {
    Json::object(Map([]))
  } else {
    json_obj([("cursor", Json::string(cursor))])
  }
  mcp_request(id, "tools/list", params)
}

///|
/// A `tools/call` request. `arguments` is the object the model gave the gateway, forwarded as the
/// server's tool expects it.
pub fn mcp_call_request(id : Int, tool : String, arguments : Json) -> Json {
  mcp_request(
    id,
    "tools/call",
    json_obj([("name", Json::string(tool)), ("arguments", arguments)]),
  )
}

///|
/// One message as one line. The stdio transport frames messages by newline and forbids an embedded
/// newline inside one, which is why this is a compact stringify and not a pretty one.
pub fn mcp_frame(message : Json) -> String {
  message.stringify() + "\n"
}

// ── The HTTP transport's protocol surface ─────────────────────────────────

///|
/// The header a Streamable HTTP server hands back a session id in.
///
/// The spelling is the protocol's. Case is the transport's business — an HTTP header map compares
/// case-insensitively — so what is here is the name as it must be *sent*.
pub fn mcp_session_header() -> String {
  "mcp-session-id"
}

///|
/// What a request says it will accept.
///
/// Both spellings, because the transport lets a server answer one request with either: a plain JSON
/// body is the simple case and an event stream is what a server falls back to when it needs to send
/// something before the answer. A client that named only one would get a 406 from servers that
/// insist on the other, and the failure would look like a broken server.
pub fn mcp_accept_value() -> String {
  "application/json, text/event-stream"
}

///|
/// The headers one HTTP request carries.
///
/// The session id is sent only once there is one: the `initialize` request has none, and the id is
/// what the *reply* to it establishes. Sending an empty one would be claiming a session that does
/// not exist yet.
pub fn mcp_http_headers(session_id : String) -> Array[(String, String)] {
  let headers : Array[(String, String)] = [
    ("Content-Type", "application/json"),
    ("Accept", mcp_accept_value()),
  ]
  if session_id != "" {
    headers.push((mcp_session_header(), session_id))
  }
  headers
}

///|
/// The session id out of a reply's headers.
///
/// A header map compares case-insensitively, so the comparison here is done on a lowered copy — the
/// *rule* (which header, and that an empty one is no id) belongs in `core` where it can be tested,
/// even though the map that carried it is the transport's.
pub fn mcp_session_id_from_headers(
  headers : Array[(String, String)],
) -> String? {
  let wanted = mcp_session_header()
  for header in headers {
    let (name, value) = header
    if name.to_lower() == wanted && value != "" {
      return Some(value)
    }
  }
  None
}

///|
/// Whether a response's content type is an event stream rather than a single JSON document.
///
/// Read as a prefix and lowered, because a real `Content-Type` arrives with parameters —
/// `text/event-stream; charset=utf-8` — and an equality test would call that a JSON body and fail to
/// parse it.
pub fn is_event_stream(content_type : String) -> Bool {
  content_type.to_lower().trim().has_prefix("text/event-stream")
}

///|
/// The payloads of one SSE event block, or `[]` for a block that carries none.
///
/// Reproduced rather than borrowed from the model-stream reader: MCP's transport and a provider's
/// stream are two different specifications that happen to use the same framing, and sharing a parser
/// between them would mean a change made for one silently altering the other. This is the smaller
/// half — `data:` lines only, no event names, no ids, no retry — because that is all the transport
/// sends.
pub fn sse_data_lines(block : String) -> Array[String] {
  let out : Array[String] = []
  for raw in block.split("\n") {
    let line = raw.to_owned()
    if !line.has_prefix("data:") {
      continue
    }
    let value = line[5:].to_owned()
    out.push(if value.has_prefix(" ") { value[1:].to_owned() } else { value })
  }
  out
}

// ── Reading what comes back ────────────────────────────────────────────────

///|
/// A server's error reply.
pub(all) struct McpError {
  code : Int
  message : String
} derive(Eq, Debug)

///|
/// One line from a server, classified.
///
/// A server may send three unrelated things down the same pipe, and treating them alike is how a
/// notification gets mistaken for the answer to a request. So the shape decides: `id` present means
/// a reply, `method` present means the server's own message, and neither means a line this client
/// can do nothing with.
pub(all) enum McpIncoming {
  /// The answer to a request we sent. Exactly one of `result`/`error` is set.
  Reply(id~ : Int, result~ : Json?, error~ : McpError?)
  /// Something the server said on its own, e.g. `notifications/tools/list_changed`.
  Notification(rpc_method~ : String, params~ : Json)
  /// A line this client does not act on: not JSON, not an object, a server-addressed request (we
  /// answer none), or a message with neither an `id` nor a `method`. Named rather than dropped so a
  /// reader can see *why* a line was set aside instead of watching a request time out.
  Ignored(reason~ : String)
} derive(Eq, Debug)

///|
/// Classify one newline-delimited line.
pub fn parse_mcp_message(line : String) -> McpIncoming {
  let trimmed = line.trim()
  if trimmed == "" {
    return Ignored(reason="empty line")
  }
  let parsed = try @json.parse(trimmed) catch {
    _ => return Ignored(reason="not JSON")
  } noraise {
    json => json
  }
  match parsed {
    Object(_) => ()
    _ => return Ignored(reason="not a JSON object")
  }
  let rpc_method = arg_string(parsed, "method")
  let id = arg_int(parsed, "id")
  match (rpc_method, id) {
    // Both present: a request the server addressed to us. This client implements no server-facing
    // methods, so the honest answer is that it went unhandled.
    (Some(name), Some(_)) =>
      Ignored(reason="server request `\{name}` is not handled")
    (Some(name), None) =>
      Notification(
        rpc_method=name,
        params=opt(parsed, "params").unwrap_or(Json::object(Map([]))),
      )
    (None, Some(id)) =>
      match opt(parsed, "error") {
        Some(error) =>
          Reply(
            id~,
            result=None,
            error=Some({
              code: arg_int(error, "code").unwrap_or(0),
              message: arg_required_string(error, "message"),
            }),
          )
        None =>
          match opt(parsed, "result") {
            Some(result) => Reply(id~, result=Some(result), error=None)
            None => Ignored(reason="a reply with neither `result` nor `error`")
          }
      }
    (None, None) => Ignored(reason="neither `id` nor `method`")
  }
}

// ── The handshake ──────────────────────────────────────────────────────────

///|
/// What `initialize` came back with.
///
/// `has_tools` is read rather than assumed: a server that announced no `tools` capability has none
/// to list, and asking anyway is a request it is entitled to reject.
pub(all) struct McpHandshake {
  protocol_version : String
  server_name : String
  server_version : String
  has_tools : Bool
} derive(Eq, Debug)

///|
pub fn parse_initialize_result(result : Json) -> McpHandshake {
  let server_info = opt(result, "serverInfo").unwrap_or(Json::object(Map([])))
  let capabilities = opt(result, "capabilities").unwrap_or(
    Json::object(Map([])),
  )
  {
    protocol_version: arg_required_string(result, "protocolVersion"),
    server_name: arg_required_string(server_info, "name"),
    server_version: arg_required_string(server_info, "version"),
    has_tools: opt(capabilities, "tools") is Some(_),
  }
}

///|
/// A tool a server announced, as `tools/list` described it.
pub(all) struct McpTool {
  name : String
  description : String
  /// The server's own JSON Schema, kept opaque: it is the server's contract about its arguments,
  /// not something this client has an opinion about, and it reaches the model unchanged.
  input_schema : Json
} derive(Eq, Debug)

///|
/// The tools one `tools/list` page announced, and the cursor for the next page if there is one.
///
/// A tool with no name is dropped rather than kept: it could never be called, so it would be a
/// catalog entry whose only effect is to spend tokens on a dead end.
pub fn parse_tools_list(result : Json) -> (Array[McpTool], String?) {
  let tools : Array[McpTool] = []
  for item in arg_array(result, "tools") {
    let name = arg_required_string(item, "name")
    if name == "" {
      continue
    }
    tools.push({
      name,
      description: arg_required_string(item, "description"),
      input_schema: opt(item, "inputSchema").unwrap_or(
        json_obj([("type", Json::string("object"))]),
      ),
    })
  }
  let cursor = match arg_string(result, "nextCursor") {
    Some(next) if next != "" => Some(next)
    _ => None
  }
  (tools, cursor)
}

// ── A tool result, as the model sees it ────────────────────────────────────

///|
/// Turn a `tools/call` result into the output a built-in tool would have produced.
///
/// The content blocks map onto `Content` directly — text to text, image to image — because the two
/// vocabularies were designed for the same job and pretending otherwise would mean a picture
/// arriving as base64 in the model's prose. A block this client cannot render becomes a short note
/// rather than nothing: a silently dropped block is a tool that appears to have answered and did
/// not, and the model has no way to tell the difference.
pub fn mcp_call_result(result : Json) -> ToolOutput {
  let content : Array[Content] = []
  let notes : Array[String] = []
  for block in arg_array(result, "content") {
    match arg_string(block, "type") {
      Some("text") => content.push(Text(arg_required_string(block, "text")))
      Some("image") =>
        match arg_string(block, "mimeType") {
          Some(mime_type) if mime_type != "" =>
            content.push(
              Image(data=arg_required_string(block, "data"), mime_type~),
            )
          _ =>
            // Without a type the image is bytes nothing downstream can display, so it is reported
            // as what it is rather than handed on as a picture.
            notes.push("(an image block with no `mimeType` was left out)")
        }
      Some("resource") =>
        match resource_text(block) {
          Some(text) => content.push(Text(text))
          None =>
            notes.push(
              "(a binary resource the client cannot render was left out)",
            )
        }
      Some(other) =>
        notes.push("(an unsupported content type \"\{other}\" was left out)")
      None => notes.push("(a content block with no `type` was left out)")
    }
  }
  let is_error = arg_bool(result, "isError").unwrap_or(false)
  // `structuredContent` is the newer, machine-shaped half of a result. A tool may answer with it
  // alone, and dropping it would turn a working call into a blank one.
  if content.is_empty() {
    match opt(result, "structuredContent") {
      Some(structured) =>
        if structured != Json::null() {
          content.push(Text(structured.stringify()))
        }
      None => ()
    }
  }
  if content.is_empty() {
    notes.push(
      if is_error {
        "(the server reported an error and returned nothing else)"
      } else {
        "(the tool returned no content)"
      },
    )
  }
  if !notes.is_empty() {
    content.push(Text(notes.join("\n")))
  }
  { content, is_error, details: None, }
}

///|
/// A `resource` block's text, when it carries text at all. A `blob` is base64 the model could not
/// read, and a URI on its own names something the client does not fetch, so both are `None`.
fn resource_text(block : Json) -> String? {
  let resource = match opt(block, "resource") {
    Some(resource) => resource
    None => return None
  }
  let text = match arg_string(resource, "text") {
    Some(text) => text
    None => return None
  }
  let uri = arg_required_string(resource, "uri")
  if uri == "" {
    Some(text)
  } else {
    Some("\{uri}\n\{text}")
  }
}

// ── The catalog ────────────────────────────────────────────────────────────

///|
/// A server as the catalog and the gateway need it: what it is called, what it is for, and what it
/// announced through `tools/list`.
///
/// Built from config plus that reply, and nothing else — no connection, no handle, no state that
/// changes. That is what lets the catalog be rendered by the same pure prompt builder the skills go
/// through, and what makes "which servers are reachable" a value rather than a query.
pub(all) struct McpServer {
  /// What a call names, and what the catalog sorts and lists by. Comes from the config entry, so it
  /// is stable across sessions where a tool list is not.
  name : String
  /// One line telling the model when this server is worth asking. May be empty.
  description : String
  /// What it announced. Empty is a real answer — a server with no tools — and the catalog says so.
  tools : Array[McpTool]
} derive(Eq, Debug)

///|
/// How many of a server's tool names the catalog spells out before it stops and points at the
/// server instead.
///
/// The catalog is in every request, so a server announcing hundreds of tools must not be able to
/// spend the prompt on its own. Forty names is still a size a reader can take in and covers every
/// server seen so far; past it, the model asks, which is the path it would take anyway.
pub fn mcp_catalog_tool_name_limit() -> Int {
  40
}

///|
/// Servers ordered by name, so two configs that differ only in file order produce the same catalog
/// — and therefore the same request bytes.
pub fn sorted_servers(servers : Array[McpServer]) -> Array[McpServer] {
  let out : Array[McpServer] = []
  for server in servers {
    out.push(server)
  }
  out.sort_by((a, b) => compare_names(a.name, b.name))
  out
}

///|
/// The catalog the model reads to decide whether a server is worth asking.
///
/// **Names, not schemas.** A tool's name is usually enough to recognize the verb a task needs, and
/// a name costs a couple of tokens where its schema costs dozens. An empty list renders no section
/// at all, which is the same rule the skill catalog follows and what keeps a workspace with no
/// servers sending exactly the prompt it sent before MCP existed.
pub fn mcp_catalog_prompt(servers : Array[McpServer]) -> String {
  if servers.length() == 0 {
    return ""
  }
  let out = StringBuilder()
  out.write_string("## MCP servers\n\n")
  out.write_string(
    "More tools, reachable through the `mcp` tool. The names below are all that is listed here — ask a\n" +
    "server what its tools take, then call one. Do both through `mcp`.\n\n",
  )
  for server in sorted_servers(servers) {
    out.write_string("- \{server.name}")
    if server.description != "" {
      out.write_string(" — \{server.description}")
    }
    out.write_string("\n")
    if server.tools.length() > 0 {
      out.write_string("  \{tool_names_line(server)}\n")
    }
  }
  out.to_string()
}

///|
/// One server's tools as a line of backticked names, summarized past the limit.
fn tool_names_line(server : McpServer) -> String {
  let limit = mcp_catalog_tool_name_limit()
  let shown : Array[String] = []
  let mut hidden = 0
  let mut index = 0
  for tool in server.tools {
    if index < limit {
      shown.push("`\{tool.name}`")
    } else {
      hidden += 1
    }
    index += 1
  }
  let list = shown.join(", ")
  if hidden == 0 {
    "Tools: \{list}"
  } else {
    "Tools: \{list} (+ \{hidden} more — ask `\{server.name}` for the rest)"
  }
}

// ── Asking, and being told what there is ───────────────────────────────────

///|
/// What a server has, as the text the model reads back through the gateway. This is the pull: the
/// descriptions and the full argument schemas, spent only when a task reached for the server.
///
/// The example at the end is not decoration. The gateway takes the tool's arguments nested one level
/// deeper than a declared tool would, so showing the exact shape is cheaper than a round of the
/// model guessing at it.
pub fn mcp_describe_message(server : McpServer) -> String {
  let out = StringBuilder()
  out.write_string(server.name)
  if server.description != "" {
    out.write_string(" — \{server.description}")
  }
  out.write_string("\n")
  if server.tools.is_empty() {
    out.write_string(
      "\nThis server has no tools, so there is nothing here to call.\n",
    )
    return out.to_string()
  }
  for tool in server.tools {
    out.write_string("\n`\{tool.name}`")
    if tool.description != "" {
      out.write_string(" — \{tool.description}")
    }
    out.write_string("\n  arguments:\n")
    out.write_string(
      indent_lines(tool.input_schema.stringify(indent=2), "    "),
    )
    out.write_string("\n")
  }
  out.write_string(
    "\nCall one with the `mcp` tool, e.g. {\"server\":\"" +
    server.name +
    "\",\"tool\":\"" +
    server.tools[0].name +
    "\",\"arguments\":{}} — `arguments` is the tool's own, exactly as the schema above describes.\n",
  )
  out.to_string()
}

///|
/// Prefix every line, so an indented schema reads as one block rather than as prose the model might
/// take for the surrounding message.
fn indent_lines(text : String, prefix : String) -> String {
  let out = StringBuilder()
  for line in text.split("\n") {
    out.write_string(prefix)
    out.write_string(line.to_owned())
    out.write_string("\n")
  }
  out.to_string()
}

///|
/// What a call to a server this turn does not have comes back with.
///
/// Written as an instruction rather than as an error message, for the reason
/// `undeclared_tool_message` is: the model is the reader, and a refusal that names what *is* there
/// is one it can act on. This is also what makes loading on demand safe — a server the catalog did
/// not mention is one the model can still discover by asking, so a miss costs a call and not the
/// task.
pub fn mcp_unknown_server_message(
  name : String,
  servers : Array[McpServer],
) -> String {
  let known : Array[String] = []
  for server in sorted_servers(servers) {
    known.push("`\{server.name}`")
  }
  let list = if known.is_empty() {
    "no MCP server is configured"
  } else {
    "the servers are \{known.join(", ")}"
  }
  "Refused: there is no MCP server named `\{name}`, so nothing ran. As far as this session knows, \{list}."
}

///|
/// What a call to a tool a server does not have comes back with — the server half of
/// `undeclared_tool_message`, and the reason a wrong tool name costs one call.
pub fn mcp_unknown_tool_message(server : McpServer, name : String) -> String {
  let known : Array[String] = []
  for tool in server.tools {
    known.push("`\{tool.name}`")
  }
  let tail = if known.is_empty() {
    "It has no tools at all."
  } else {
    "Its tools are \{known.join(", ")}."
  }
  "Refused: `\{server.name}` has no tool named `\{name}`, so nothing ran. \{tail} Ask `\{server.name}` with no `tool` to see what each one takes."
}

// ── The gateway ────────────────────────────────────────────────────────────

///|
/// What a call to the `mcp` tool asks for.
pub(all) enum McpCall {
  /// What does this server have? No `tool` given.
  Describe(server~ : String)
  /// Run one of its tools.
  Invoke(server~ : String, tool~ : String, arguments~ : Json)
  /// The call cannot be routed. `reason` is the short cause; the message is built with the server
  /// list, which `parse_mcp_call` does not have.
  Invalid(reason~ : String)
} derive(Eq, Debug)

///|
/// Read the gateway's arguments. No `tool` means the describe half, which is what makes "ask first"
/// cost the same one field as calling does.
///
/// `arguments` is coerced rather than trusted. A model that has the object in its head sometimes
/// sends it as a string, and the string is unambiguous — it either parses to an object or does not —
/// so accepting it is cheaper than a refusal the model would answer by sending the same call again.
/// The same leniency, for the same reason, as code mode accepting `bash` for `exec`.
pub fn parse_mcp_call(arguments : Json) -> McpCall {
  let server = arg_required_string(arguments, "server").trim().to_owned()
  if server == "" {
    return Invalid(reason="`server` is required")
  }
  let tool = arg_required_string(arguments, "tool").trim().to_owned()
  if tool == "" {
    return Describe(server~)
  }
  match call_arguments(opt(arguments, "arguments")) {
    Some(arguments) => Invoke(server~, tool~, arguments~)
    None =>
      Invalid(
        reason="`arguments` must be a JSON object (or a string containing one)",
      )
  }
}

///|
/// The tool arguments a call carries: an object passed through, a string parsed, absent read as
/// empty. `None` when something was given that is neither.
fn call_arguments(value : Json?) -> Json? {
  match value {
    None => Some(Json::object(Map([])))
    Some(Object(_)) => value
    Some(String(text)) => parse_object_text(text)
    Some(_) => None
  }
}

///|
fn parse_object_text(text : String) -> Json? {
  let parsed = try @json.parse(text) catch {
    _ => return None
  } noraise {
    json => json
  }
  match parsed {
    Object(_) => Some(parsed)
    _ => None
  }
}

///|
/// What an unroutable call comes back with.
pub fn mcp_invalid_message(
  reason : String,
  servers : Array[McpServer],
) -> String {
  let known : Array[String] = []
  for server in sorted_servers(servers) {
    known.push("`\{server.name}`")
  }
  let tail = if known.is_empty() {
    "No MCP server is configured."
  } else {
    "Call it as {\"server\":\"<name>\",\"tool\":\"<name>\",\"arguments\":{}}, with the server one of \{known.join(", ")}."
  }
  "Refused: \{reason}, so nothing ran. \{tail}"
}

///|
/// The gateway tool.
///
/// One tool rather than one per server, which is what keeps a server's tools out of the request and
/// out of the namespace: nothing a server names can collide with `bash`, and two servers naming the
/// same tool is a matter of which `server` the call carries rather than of who registered first.
///
/// `Exclusive` because a server's tool is arbitrary code on the other end — it may write, fetch or
/// prompt — which is the same classification `bash` gets for the same reason.
pub fn mcp_tool() -> ToolDef {
  let description =
    #|Reach a tool on one of the MCP servers listed in the system prompt.
    #|
    #|Pass `server` and `tool` to run a tool, or just `server` to see what that server has — its
    #|tools' descriptions and the arguments each one takes. Ask before calling: the arguments are
    #|the server's own and only the server's schema describes them.
    #|
    #|The result is whatever the server returned, text and images included.
    #|
  {
    name: "mcp",
    description,
    parameters: object_schema(
      [
        (
          "server",
          str_prop("The MCP server to use, as named in the system prompt."),
        ),
        (
          "tool",
          str_prop(
            "The server's tool to run. Omit to list what the server has, with the arguments each one takes.",
          ),
        ),
        (
          "arguments",
          json_obj([
            ("type", Json::string("object")),
            (
              "description",
              Json::string(
                "The tool's arguments, matching the schema the server describes. Omit when the tool takes none.",
              ),
            ),
          ]),
        ),
      ],
      ["server"],
    ),
    concurrency: Exclusive,
    timeout_ms: None,
    snippet: "Run a tool on an MCP server; ask first what it has",
  }
}

///|
/// This turn's tools with the gateway added, when there are servers to reach.
///
/// Appended rather than folded into `tools_for_mode`, because the gateway exists only when a server
/// does. With none configured the array is the one the mode already had, name for name, so the
/// request is byte-identical to what it was before MCP existed — the same discipline the skill
/// catalog follows, and the reason neither shows up as an empty section.
pub fn with_mcp_tools(
  tools : Array[ToolDef],
  servers : Array[McpServer],
) -> Array[ToolDef] {
  if servers.length() == 0 {
    return tools
  }
  let out : Array[ToolDef] = []
  for tool in tools {
    out.push(tool)
  }
  out.push(mcp_tool())
  out
}

// ── What the panel shows ───────────────────────────────────────────────────

///|
/// One server as the settings panel needs it.
///
/// Built from four inputs rather than read off a live object, because the reader's question is wider
/// than any one of them answers: whether it is *configured*, whether it is *switched on*, whether it
/// is *up*, and if not, why. A row assembled from one of those alone would be wrong about the other
/// three — an off server and a broken one look identical from the connections, and that difference is
/// the whole reason the row exists.
pub(all) struct ServerEntry {
  name : String
  /// `stdio` or `http`, or empty for an entry that named neither.
  transport : String
  description : String
  /// How many tools it offers. Zero for one that is not up, and for one that is up with nothing.
  tool_count : Int
  /// Whether a turn may reach it.
  enabled : Bool
  /// Why it is not running, when that is a fact the reader can act on — empty when it is up, and
  /// empty when it is off on purpose, because a switch that is off is not a fault.
  note : String
} derive(Eq, Debug)

///|
/// Every configured server as the panel shows it, switched on or off.
///
/// Names that are switched off but no longer configured are appended, the same way `skill_entries`
/// does it: a setting a reader cannot see is a setting they cannot undo. The rest are in name order,
/// so the panel and the catalog list the same servers in the same order.
pub fn server_entries(
  configured : Array[McpConfigEntry],
  connected : Array[McpServer],
  failures : Array[(String, String)],
  disabled : Array[String],
) -> Array[ServerEntry] {
  let out : Array[ServerEntry] = []
  let known : Array[String] = []
  for entry in configured {
    let name = entry_name(entry)
    if name == "" {
      continue
    }
    known.push(name)
    let enabled = !disabled.contains(name)
    let up = index_of_server(connected, name)
    let note = if !enabled {
      ""
    } else {
      match up {
        Some(_) => ""
        None =>
          match failure_reason(failures, name) {
            Some(reason) => reason
            // Enabled, not up, no failure recorded: the servers have not been looked at yet. Said
            // plainly rather than left blank, so a row that is neither on nor broken explains itself.
            None => "not started yet"
          }
      }
    }
    out.push({
      name,
      transport: config_transport(entry),
      description: config_description(entry),
      tool_count: match up {
        Some(server) => server.tools.length()
        None => 0
      },
      enabled,
      note,
    })
  }
  let extras = disabled.copy()
  extras.sort_by((a, b) => compare_names(a, b))
  for name in extras {
    // The same two rules the configured loop applies, for the same reasons: an empty name is not a
    // setting — the decoder drops one on the way in, and a value built by hand should not be able to
    // put one on screen — and a name that is already a row above is not a second row.
    if name != "" && !known.contains(name) {
      out.push({
        name,
        transport: "",
        description: "",
        tool_count: 0,
        enabled: false,
        note: "",
      })
    }
  }
  out
}

///|
fn index_of_server(servers : Array[McpServer], name : String) -> McpServer? {
  for server in servers {
    if server.name == name {
      return Some(server)
    }
  }
  None
}

///|
fn failure_reason(failures : Array[(String, String)], name : String) -> String? {
  for failure in failures {
    let (failed, reason) = failure
    if failed == name {
      return Some(reason)
    }
  }
  None
}

///|
fn config_description(entry : McpConfigEntry) -> String {
  match entry {
    Stdio(config) => config.description
    Http(config) => config.description
    Unsupported(_) => ""
  }
}
