///|
/// The MCP protocol surface: frames, the handshake, the catalog, and refusals.
///
/// These are all pure, so every decision the protocol makes is pinned here against fixed bytes —
/// which is the point of keeping it in `core/`. The connection that carries the frames is the only
/// part left to the platform layer, and it is the part with the least to decide.
///
/// Two helpers stand in for package-private ones a blackbox test cannot reach: `json_of` for
/// building an object, and `at` for reading one field. They are copies of what `core/tools.mbt` and
/// `core/message_json.mbt` already have, not a second implementation of anything.

///|
fn json_of(pairs : Array[(String, Json)]) -> Json {
  Json::object(Map(pairs))
}

///|
fn at(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
fn mcp_test_schema() -> Json {
  json_of([
    ("type", Json::string("object")),
    (
      "properties",
      json_of([("title", json_of([("type", Json::string("string"))]))]),
    ),
    ("required", Json::array([Json::string("title")])),
  ])
}

///|
fn mcp_test_server(
  name : String,
  description : String,
  tools : Array[McpTool],
) -> McpServer {
  { name, description, tools, }
}

///|
fn mcp_test_tool(name : String, description : String) -> McpTool {
  { name, description, input_schema: mcp_test_schema(), }
}

// ── Frames and the handshake ───────────────────────────────────────────────

///|
test "initialize asks for the revision, names the client, and claims nothing" {
  assert_eq(
    mcp_initialize_request(1),
    json_of([
      ("jsonrpc", Json::string("2.0")),
      ("id", Json::number(1.0)),
      ("method", Json::string("initialize")),
      (
        "params",
        json_of([
          ("protocolVersion", Json::string(mcp_protocol_version())),
          // Empty on purpose: every optional client capability promises something this client does
          // not do, and announcing one would invite a server to ask for it and wait forever.
          ("capabilities", json_of([])),
          (
            "clientInfo",
            json_of([
              ("name", Json::string(mcp_client_name())),
              ("version", Json::string(mcp_client_version())),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

///|
test "a notification carries no id, and a frame ends in exactly one newline" {
  let frame = mcp_frame(mcp_initialized_notification())
  assert_true(frame.has_suffix("\n"))
  assert_false(frame.has_suffix("\n\n"))
  let parsed = @json.parse(frame)
  assert_eq(parsed, mcp_initialized_notification())
  assert_true(
    at(parsed, "id") is None,
    msg="a notification must not carry an id",
  )
}

///|
test "initialize reads the revision, the server's name, and whether it has tools" {
  let listed = parse_initialize_result(
    @json.parse(
      "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"github\",\"version\":\"1.2.3\"}}",
    ),
  )
  assert_eq(listed.protocol_version, "2024-11-05")
  assert_eq(listed.server_name, "github")
  assert_eq(listed.server_version, "1.2.3")
  assert_true(listed.has_tools)
  // A server that announced no `tools` capability is not asked to list any.
  let bare = parse_initialize_result(
    @json.parse(
      "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"echo\",\"version\":\"0\"}}",
    ),
  )
  assert_false(bare.has_tools)
}

// ── Reading what comes back ────────────────────────────────────────────────

///|
test "a result reply is a reply, not a notification" {
  let incoming = parse_mcp_message(
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"tools\":[]}}",
  )
  match incoming {
    Reply(id~, result~, error~) => {
      assert_eq(id, 7)
      assert_true(error is None)
      assert_eq(result.unwrap(), json_of([("tools", Json::array([]))]))
    }
    _ => fail("expected a reply")
  }
}

///|
test "an error reply keeps the server's own message" {
  let incoming = parse_mcp_message(
    "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32602,\"message\":\"Unknown tool: nope\"}}",
  )
  match incoming {
    Reply(result~, error~, ..) => {
      assert_true(result is None)
      let err = error.unwrap()
      assert_eq(err.code, -32602)
      // The server's wording, kept: it is the thing the model can act on.
      assert_eq(err.message, "Unknown tool: nope")
    }
    _ => fail("expected a reply")
  }
}

///|
test "a message with a method and no id is the server's own" {
  let incoming = parse_mcp_message(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
  )
  match incoming {
    Notification(rpc_method~, params~) => {
      assert_eq(rpc_method, "notifications/tools/list_changed")
      assert_eq(params, json_of([]))
    }
    _ => fail("expected a notification")
  }
}

///|
test "a server request is set aside, and the reason says which one it was" {
  // A request the server addresses to us: it carries an id *and* a method. Nothing here answers one.
  match
    parse_mcp_message(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"roots/list\"}",
    ) {
    Ignored(reason~) => assert_true(reason.contains("roots/list"), msg=reason)
    _ => fail("expected an ignored line")
  }
}

///|
test "lines that cannot be acted on are named, not silently dropped" {
  // Each of these would otherwise be a request that never gets answered, with nothing to read.
  match parse_mcp_message("not json at all") {
    Ignored(reason~) => assert_eq(reason, "not JSON")
    _ => fail("expected an ignored line")
  }
  match parse_mcp_message("  ") {
    Ignored(reason~) => assert_eq(reason, "empty line")
    _ => fail("expected an ignored line")
  }
  match parse_mcp_message("[1,2,3]") {
    Ignored(reason~) => assert_eq(reason, "not a JSON object")
    _ => fail("expected an ignored line")
  }
  match parse_mcp_message("{\"jsonrpc\":\"2.0\",\"result\":{}}") {
    Ignored(reason~) => assert_true(reason.contains("neither"), msg=reason)
    _ => fail("expected an ignored line")
  }
  match parse_mcp_message("{\"jsonrpc\":\"2.0\",\"id\":3}") {
    Ignored(reason~) =>
      assert_true(reason.contains("neither `result` nor `error`"), msg=reason)
    _ => fail("expected an ignored line")
  }
}

// ── tools/list ─────────────────────────────────────────────────────────────

///|
test "tools/list keeps each tool's schema opaque and its missing description empty" {
  let (tools, cursor) = parse_tools_list(
    @json.parse(
      "{\"tools\":[{\"name\":\"create_issue\",\"description\":\"Create an issue.\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"bare\"}]}",
    ),
  )
  assert_true(cursor is None)
  assert_eq(tools.length(), 2)
  assert_eq(tools[0].name, "create_issue")
  assert_eq(tools[0].description, "Create an issue.")
  assert_eq(tools[0].input_schema, json_of([("type", Json::string("object"))]))
  // A missing `inputSchema` becomes the schema every argument set already satisfies, rather than
  // `null` reaching the model as the shape to fill in.
  assert_eq(tools[1].name, "bare")
  assert_eq(tools[1].input_schema, json_of([("type", Json::string("object"))]))
}

///|
test "a nameless tool is dropped and a next cursor is carried" {
  // A tool with no name could never be called, so it would be a catalog entry that only spends
  // tokens. The cursor is what the platform layer follows to the next page.
  let (tools, cursor) = parse_tools_list(
    @json.parse(
      "{\"tools\":[{\"name\":\"\"},{\"name\":\"real\"}],\"nextCursor\":\"page-2\"}",
    ),
  )
  assert_eq(tools.length(), 1)
  assert_eq(tools[0].name, "real")
  assert_eq(cursor, Some("page-2"))
}

// ── tools/call, as the model sees it ───────────────────────────────────────

///|
test "text and image blocks become content, in order" {
  let out = mcp_call_result(
    @json.parse(
      "{\"content\":[{\"type\":\"text\",\"text\":\"done\"},{\"type\":\"image\",\"data\":\"aGk=\",\"mimeType\":\"image/png\"}]}",
    ),
  )
  assert_false(out.is_error)
  assert_eq(out.content.length(), 2)
  assert_eq(out.content[0], Text("done"))
  assert_eq(out.content[1], Image(data="aGk=", mime_type="image/png"))
}

///|
test "an error result keeps its text and says it is one" {
  let out = mcp_call_result(
    @json.parse(
      "{\"content\":[{\"type\":\"text\",\"text\":\"no such repo\"}],\"isError\":true}",
    ),
  )
  assert_true(out.is_error)
  assert_eq(out.content[0], Text("no such repo"))
}

///|
test "a block the client cannot render is named rather than dropped" {
  // Silence here would look like a tool that answered and did not, and the model could not tell.
  let out = mcp_call_result(
    @json.parse(
      "{\"content\":[{\"type\":\"audio\",\"data\":\"x\"},{\"type\":\"image\",\"data\":\"y\"}]}",
    ),
  )
  assert_eq(out.content.length(), 1)
  match out.content[0] {
    Text(text) => {
      assert_true(text.contains("audio"), msg=text)
      assert_true(text.contains("mimeType"), msg=text)
    }
    _ => fail("expected the notes as text")
  }
}

///|
test "a tool that returns nothing says so" {
  let empty = mcp_call_result(@json.parse("{\"content\":[]}"))
  assert_eq(empty.content[0], Text("(the tool returned no content)"))
  let failed = mcp_call_result(@json.parse("{\"content\":[],\"isError\":true}"))
  assert_eq(
    failed.content[0],
    Text("(the server reported an error and returned nothing else)"),
  )
}

///|
test "structuredContent is used when there is no content block" {
  // The newer, machine-shaped half of a result. A tool may answer with only this, and dropping it
  // would turn a working call into a blank one.
  let out = mcp_call_result(
    @json.parse("{\"structuredContent\":{\"count\":3},\"content\":[]}"),
  )
  assert_eq(out.content[0], Text("{\"count\":3}"))
}

///|
test "a text resource keeps its uri; a binary one is reported as unreachable" {
  let text = mcp_call_result(
    @json.parse(
      "{\"content\":[{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///a.txt\",\"text\":\"hi\"}}]}",
    ),
  )
  assert_eq(text.content[0], Text("file:///a.txt\nhi"))
  let blob = mcp_call_result(
    @json.parse(
      "{\"content\":[{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///a.png\",\"blob\":\"aGk=\"}}]}",
    ),
  )
  assert_true(
    match blob.content[0] {
      Text(text) => text.contains("binary")
      _ => false
    },
  )
}

// ── The catalog ────────────────────────────────────────────────────────────

///|
test "no servers renders no section at all" {
  // Not an empty heading: a section that rendered one would invalidate the prefix cache of every
  // session that predates MCP.
  assert_eq(mcp_catalog_prompt([]), "")
}

///|
test "the catalog names each server, what it is for, and its tools" {
  let servers : Array[McpServer] = [
    mcp_test_server("github", "Issues and pull requests.", [
      mcp_test_tool("create_issue", "Create an issue."),
      mcp_test_tool("list_repos", "List repositories."),
    ]),
  ]
  let text = mcp_catalog_prompt(servers)
  assert_true(text.has_prefix("## MCP servers\n"), msg=text)
  assert_true(text.contains("`mcp` tool"), msg=text)
  assert_true(text.contains("- github — Issues and pull requests."), msg=text)
  assert_true(text.contains("`create_issue`, `list_repos`"), msg=text)
}

///|
test "servers are ordered by name, so the prompt does not depend on config order" {
  let servers : Array[McpServer] = [
    mcp_test_server("zeta", "", []),
    mcp_test_server("alpha", "", []),
  ]
  let text = mcp_catalog_prompt(servers)
  let alpha = text.find("alpha").unwrap()
  let zeta = text.find("zeta").unwrap()
  assert_true(alpha < zeta, msg=text)
  // A server with no tools still appears: it is reachable, and the catalog's job is to say what is
  // reachable.
  assert_true(text.contains("- zeta\n"), msg=text)
}

///|
test "a server with more tools than the limit summarizes the rest" {
  let limit = mcp_catalog_tool_name_limit()
  let tools : Array[McpTool] = []
  let mut i = 0
  while i < limit + 2 {
    tools.push(mcp_test_tool("tool_\{i}", ""))
    i = i + 1
  }
  let text = mcp_catalog_prompt([mcp_test_server("big", "", tools)])
  assert_true(text.contains("(+ 2 more"), msg=text)
  assert_true(text.contains("ask `big` for the rest"), msg=text)
  // The fortieth name is still spelled out, and the forty-first is not.
  assert_true(text.contains("`tool_\{limit - 1}`"), msg=text)
  assert_false(text.contains("`tool_\{limit}`"), msg=text)
}

// ── Asking ─────────────────────────────────────────────────────────────────

///|
test "describing a server shows each tool's schema and the exact call shape" {
  let text = mcp_describe_message(
    mcp_test_server("github", "Issues.", [
      mcp_test_tool("create_issue", "Create an issue."),
    ]),
  )
  assert_true(text.contains("`create_issue` — Create an issue."), msg=text)
  // The whole point of asking: the schema, which the catalog deliberately did not carry.
  assert_true(text.contains("\"required\""), msg=text)
  assert_true(text.contains("\"title\""), msg=text)
  // And the call shape, which is one level deeper than a declared tool's arguments.
  assert_true(
    text.contains(
      "\"server\":\"github\",\"tool\":\"create_issue\",\"arguments\":{}",
    ),
    msg=text,
  )
}

///|
test "describing a server with no tools says there is nothing to call" {
  let text = mcp_describe_message(mcp_test_server("empty", "", []))
  assert_true(text.contains("no tools"), msg=text)
}

///|
test "a call with no tool is a describe, and one with a tool is an invoke" {
  assert_eq(
    parse_mcp_call(@json.parse("{\"server\":\"github\"}")),
    Describe(server="github"),
  )
  assert_eq(
    parse_mcp_call(
      @json.parse(
        "{\"server\":\"github\",\"tool\":\"create_issue\",\"arguments\":{\"title\":\"x\"}}",
      ),
    ),
    Invoke(
      server="github",
      tool="create_issue",
      arguments=json_of([("title", Json::string("x"))]),
    ),
  )
  // Whitespace around a name is a model's formatting, not a different server.
  assert_eq(
    parse_mcp_call(@json.parse("{\"server\":\" github \"}")),
    Describe(server="github"),
  )
}

///|
test "a tool with no arguments is callable without spelling them" {
  assert_eq(
    parse_mcp_call(@json.parse("{\"server\":\"echo\",\"tool\":\"ping\"}")),
    Invoke(server="echo", tool="ping", arguments=json_of([])),
  )
}

///|
test "arguments sent as a string are read, not refused" {
  // A model that has the object in its head sometimes sends the string. It is unambiguous either
  // way, so reading it is cheaper than a round the model would answer by repeating itself.
  assert_eq(
    parse_mcp_call(
      @json.parse(
        "{\"server\":\"x\",\"tool\":\"y\",\"arguments\":\"{\\\"a\\\":1}\"}",
      ),
    ),
    Invoke(server="x", tool="y", arguments=json_of([("a", Json::number(1.0))])),
  )
}

///|
test "an unroutable call is named, with the reason" {
  match parse_mcp_call(@json.parse("{\"tool\":\"y\"}")) {
    Invalid(reason~) => assert_true(reason.contains("`server`"), msg=reason)
    _ => fail("expected an invalid call")
  }
  match
    parse_mcp_call(
      @json.parse(
        "{\"server\":\"x\",\"tool\":\"y\",\"arguments\":\"not json\"}",
      ),
    ) {
    Invalid(reason~) => assert_true(reason.contains("object"), msg=reason)
    _ => fail("expected an invalid call")
  }
  match
    parse_mcp_call(
      @json.parse("{\"server\":\"x\",\"tool\":\"y\",\"arguments\":7}"),
    ) {
    Invalid(reason~) => assert_true(reason.contains("object"), msg=reason)
    _ => fail("expected an invalid call")
  }
}

// ── Refusals ───────────────────────────────────────────────────────────────

///|
test "a refusal names what is there, which is what makes asking safe" {
  let servers : Array[McpServer] = [
    mcp_test_server("github", "", [mcp_test_tool("create_issue", "")]),
  ]
  let unknown_server = mcp_unknown_server_message("gitlab", servers)
  assert_true(unknown_server.contains("`github`"), msg=unknown_server)
  // Written as an instruction, not an error: the model is the reader, and this is a call it can
  // correct on the next turn.
  assert_true(unknown_server.has_prefix("Refused:"), msg=unknown_server)

  let unknown_tool = mcp_unknown_tool_message(servers[0], "delete_repo")
  assert_true(unknown_tool.contains("`create_issue`"), msg=unknown_tool)
  assert_true(unknown_tool.contains("no `tool`"), msg=unknown_tool)
}

///|
test "a refusal with nothing configured says so instead of listing nothing" {
  let message = mcp_unknown_server_message("github", [])
  assert_true(message.contains("no MCP server is configured"), msg=message)
}

///|
test "an invalid call lists the servers to call, and says so when there are none" {
  let servers : Array[McpServer] = [mcp_test_server("github", "", [])]
  let with_servers = mcp_invalid_message("`server` is required", servers)
  assert_true(with_servers.contains("`github`"), msg=with_servers)
  let without = mcp_invalid_message("`server` is required", [])
  assert_true(without.contains("No MCP server is configured."), msg=without)
}

// ── The gateway tool ───────────────────────────────────────────────────────

///|
test "with no servers the tool set is unchanged" {
  let builtin = builtin_tools()
  let same = with_mcp_tools(builtin, [])
  assert_eq(same.length(), builtin.length())
  assert_false(has_tool(same, "mcp"))
}

///|
test "with a server the gateway is appended, once, and requires only the server" {
  let servers : Array[McpServer] = [mcp_test_server("github", "", [])]
  let tools = with_mcp_tools(builtin_tools(), servers)
  assert_true(has_tool(tools, "mcp"))
  assert_eq(tools[tools.length() - 1].name, "mcp")
  // `tool` is optional because omitting it is how the model asks what a server has.
  let required = at(tools[tools.length() - 1].parameters, "required").unwrap()
  assert_eq(required, Json::array([Json::string("server")]))
  // Exclusive: a server's tool is arbitrary code on the other end.
  assert_eq(tools[tools.length() - 1].concurrency, Exclusive)
}

///|
test "the gateway's arguments are named in its declaration" {
  // The names are the whole interface: `server`, `tool`, `arguments` are what a model reads to
  // learn how to reach anything, so a rename here is a breaking change to the prompt.
  let properties = at(mcp_tool().parameters, "properties").unwrap()
  assert_true(at(properties, "server") is Some(_))
  assert_true(at(properties, "tool") is Some(_))
  assert_true(at(properties, "arguments") is Some(_))
}

// ── The prompt ─────────────────────────────────────────────────────────────

///|
test "the server catalog is a parameter of the prompt, not something a caller appends" {
  let servers : Array[McpServer] = [mcp_test_server("github", "Issues.", [])]
  let tools = with_mcp_tools(builtin_tools(), servers)
  let shown = build_system_prompt("/work", tools, servers~)
  assert_true(shown.contains("## MCP servers"), msg=shown)
  assert_true(shown.contains("- github — Issues."), msg=shown)
  // The gateway tool is declared either way — it is the turn's tool set, not the catalog — so what
  // the missing argument must not produce is the *servers* section.
  let hidden = build_system_prompt("/work", tools)
  assert_false(hidden.contains("## MCP servers"), msg=hidden)
}

///|
test "no servers leaves the prompt byte-identical to before MCP existed" {
  // The same rule the skill catalog follows: an empty input contributes no bytes, so a workspace
  // with no servers sends exactly what it sent the day before this file was written.
  let tools = builtin_tools()
  assert_eq(
    build_system_prompt("/work", tools),
    build_system_prompt("/work", tools, servers=[]),
  )
}

// ── The HTTP transport's protocol surface ─────────────────────────────────

///|
test "the initialize request carries no session id, and later ones do" {
  // The id is what the *reply* to `initialize` establishes, so claiming one before that would be
  // claiming a session that does not exist yet.
  let first = mcp_http_headers("")
  assert_true(
    has_header(first, "Accept"),
    msg="the accept header is how a server knows what to send",
  )
  assert_false(has_header(first, mcp_session_header()))
  let later = mcp_http_headers("sess-1")
  assert_eq(header_value(later, mcp_session_header()), "sess-1")
}

///|
test "both answer shapes are accepted" {
  // A server that names only one gets a 406 from servers that insist on the other, and the failure
  // looks like a broken server rather than a broken client.
  let accept = mcp_accept_value()
  assert_true(accept.contains("application/json"), msg=accept)
  assert_true(accept.contains("text/event-stream"), msg=accept)
}

///|
test "the session id is read case-insensitively and an empty one is no id" {
  assert_eq(mcp_session_id_from_headers([("Mcp-Session-Id", "s1")]), Some("s1"))
  assert_eq(mcp_session_id_from_headers([("MCP-SESSION-ID", "s2")]), Some("s2"))
  // A server that sent the header empty has not established a session.
  assert_eq(mcp_session_id_from_headers([("mcp-session-id", "")]), None)
  assert_eq(
    mcp_session_id_from_headers([("content-type", "application/json")]),
    None,
  )
}

///|
test "a content type with parameters is still an event stream" {
  // A real `Content-Type` arrives with parameters, and an equality test would call this JSON and
  // then fail to parse it.
  assert_true(is_event_stream("text/event-stream; charset=utf-8"))
  assert_true(is_event_stream("TEXT/EVENT-STREAM"))
  assert_true(is_event_stream(" text/event-stream"))
  assert_false(is_event_stream("application/json"))
  assert_false(is_event_stream(""))
}

///|
test "sse data lines are read, and other lines are not" {
  let payloads = sse_data_lines(
    "id: 1\nevent: message\ndata: {\"a\":1}\n\ndata:{\"b\":2}",
  )
  assert_eq(payloads, ["{\"a\":1}", "{\"b\":2}"])
  // A block with no `data:` line carries no message, which is how a keep-alive comment reads.
  assert_eq(sse_data_lines(": keep-alive"), [])
  assert_eq(sse_data_lines(""), [])
}

///|
fn has_header(headers : Array[(String, String)], name : String) -> Bool {
  header_value(headers, name) != ""
}

///|
fn header_value(headers : Array[(String, String)], name : String) -> String {
  for header in headers {
    let (key, value) = header
    if key == name {
      return value
    }
  }
  ""
}

// ── What the panel shows ───────────────────────────────────────────────────

///|
fn server_entry_names(entries : Array[ServerEntry]) -> Array[String] {
  entries.map(entry => entry.name)
}

///|
fn stdio_entry(name : String) -> McpConfigEntry {
  Stdio({
    name,
    command: "npx",
    args: [],
    env: [],
    description: "Does something.",
  })
}

///|
/// A row per configured server, with the four facts a reader needs to act: what it is, whether it is
/// on, whether it is up, and — the one nothing else carries — why not.
test "a panel row carries the transport, the count, the switch and the reason" {
  let configured : Array[McpConfigEntry] = [
    stdio_entry("github"),
    Http({
      name: "linear",
      url: "https://mcp.linear.app/mcp",
      headers: [],
      description: "",
    }),
    Unsupported(name="mystery", reason="names neither a `command` nor a `url`"),
  ]
  let connected : Array[McpServer] = [
    mcp_test_server("github", "Does something.", [
      mcp_test_tool("create_issue", ""),
      mcp_test_tool("list_repos", ""),
    ]),
  ]
  let failures : Array[(String, String)] = [("linear", "could not reach it")]
  let entries = server_entries(configured, connected, failures, ["mystery"])
  // Name order, so the panel and the catalog list the same servers the same way.
  assert_eq(server_entry_names(entries), ["github", "linear", "mystery"])

  // Up: its count is real, and there is nothing to explain.
  assert_eq(entries[0].transport, "stdio")
  assert_eq(entries[0].description, "Does something.")
  assert_eq(entries[0].tool_count, 2)
  assert_true(entries[0].enabled)
  assert_eq(entries[0].note, "")

  // Enabled and broken: the transport is still named, and the reason travels with the row.
  assert_eq(entries[1].transport, "http")
  assert_true(entries[1].enabled)
  assert_eq(entries[1].tool_count, 0)
  assert_eq(entries[1].note, "could not reach it")

  // Switched off: no fault to report, even though it is not up either. A switch a reader flipped is
  // not a failure, and saying so would send them looking for a config problem they do not have.
  assert_false(entries[2].enabled)
  assert_eq(entries[2].transport, "")
  assert_eq(entries[2].note, "")
}

///|
test "an enabled server that has not been looked at says so" {
  // Neither up nor broken: the servers have not been started yet. A blank would read as "fine".
  let entries = server_entries([stdio_entry("github")], [], [], [])
  assert_eq(entries[0].note, "not started yet")
  assert_eq(entries[0].tool_count, 0)
  assert_true(entries[0].enabled)
}

///|
test "an entry with no name is dropped, and a nameless switched-off one is not" {
  // A config entry with an empty key could never be called, so it has no row. A *disabled* name that
  // is empty is likewise nothing to show — but a disabled name with no config behind it is the row a
  // reader needs to undo the switch, so it stays.
  assert_eq(server_entries([stdio_entry("")], [], [], []).length(), 0)
  let ghost = server_entries([], [], [], ["ghost"])
  assert_eq(server_entry_names(ghost), ["ghost"])
  assert_false(ghost[0].enabled)
  assert_eq(ghost[0].note, "")
  // A blank name is not a row anywhere.
  assert_eq(server_entries([], [], [], [""]).length(), 0)
}

///|
test "a configured name that is also switched off is one row, not two" {
  // The disabled extras are only names with *no* config: a name that is both would otherwise be
  // listed twice, once with its tools and once as a bare setting.
  let entries = server_entries([stdio_entry("github")], [], [], ["github"])
  assert_eq(server_entry_names(entries), ["github"])
  assert_false(entries[0].enabled)
}
