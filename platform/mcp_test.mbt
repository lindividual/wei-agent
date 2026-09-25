///|
/// The stdio transport against a real child process.
///
/// A fake server is the only way to test this half honestly: the protocol's decisions are pinned in
/// `core/mcp_test.mbt` against fixed bytes, so what is left to check here is that a real process gets
/// started, that a frame written to it comes back as a reply, and that the failure modes — a command
/// that is not there, a server that exits, a server that answers with an error — are reported rather
/// than hung on.
///
/// The server is a Python script because the transport is what is under test, not a server. It is
/// written to a scratch directory per test for the reason `platform/tools_test.mbt` gives: the tests
/// run concurrently and two of them creating the same path would race.

///|
/// A server that handshakes, pages `tools/list`, and answers two tools.
///
/// The paging is deliberate — the first page carries a `nextCursor` and the second does not — so a
/// client that stopped at the first page would report one tool where the server has two, which is the
/// failure mode that looks like a working integration.
fn fake_server_source() -> String {
  let source =
    #|import sys, json
    #|
    #|def send(payload):
    #|    sys.stdout.write(json.dumps(payload) + "\n")
    #|    sys.stdout.flush()
    #|
    #|def reply(id, result):
    #|    send({"jsonrpc": "2.0", "id": id, "result": result})
    #|
    #|def error(id, code, message):
    #|    send({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
    #|
    #|for line in sys.stdin:
    #|    line = line.strip()
    #|    if not line:
    #|        continue
    #|    msg = json.loads(line)
    #|    method = msg.get("method")
    #|    id = msg.get("id")
    #|    if method == "initialize":
    #|        reply(id, {
    #|            "protocolVersion": "2024-11-05",
    #|            "capabilities": {"tools": {"listChanged": False}},
    #|            "serverInfo": {"name": "fake", "version": "9.9"},
    #|        })
    #|    elif method == "notifications/initialized":
    #|        pass
    #|    elif method == "tools/list":
    #|        cursor = (msg.get("params") or {}).get("cursor")
    #|        if cursor:
    #|            reply(id, {"tools": [{"name": "echo", "description": "Echo.", "inputSchema": {"type": "object"}}]})
    #|        else:
    #|            reply(id, {"tools": [{"name": "ping", "description": "Ping.", "inputSchema": {"type": "object"}}], "nextCursor": "page-2"})
    #|    elif method == "tools/call":
    #|        name = (msg.get("params") or {}).get("name")
    #|        if name == "ping":
    #|            reply(id, {"content": [{"type": "text", "text": "pong"}]})
    #|        elif name == "echo":
    #|            reply(id, {"content": [{"type": "text", "text": "echoed"}]})
    #|        else:
    #|            error(id, -32602, "Unknown tool: " + str(name))
    #|    else:
    #|        error(id, -32601, "Method not found")
    #|
  source
}

///|
/// A server that announces no `tools` capability, to check that it is not asked to list any.
fn toolless_server_source() -> String {
  let source =
    #|import sys, json
    #|
    #|for line in sys.stdin:
    #|    line = line.strip()
    #|    if not line:
    #|        continue
    #|    msg = json.loads(line)
    #|    if msg.get("method") == "initialize":
    #|        sys.stdout.write(json.dumps({
    #|            "jsonrpc": "2.0",
    #|            "id": msg.get("id"),
    #|            "result": {
    #|                "protocolVersion": "2024-11-05",
    #|                "capabilities": {},
    #|                "serverInfo": {"name": "toolless", "version": "1"},
    #|            },
    #|        }) + "\n")
    #|        sys.stdout.flush()
    #|
  source
}

///|
async fn write_server(name : String, source : String) -> String {
  let dir = "_build/mcp_test/\{name}-\{@core.new_entry_id()}"
  make_dirs(dir)
  let path = "\{dir}/server.py"
  write_text(path, source)
  path
}

///|
fn fake_config(name : String, script : String) -> @core.McpConfig {
  Stdio({
    name,
    command: "python3",
    args: [script],
    env: [],
    description: "A fake server.",
  })
}

///|
fn text_of(output : @core.ToolOutput) -> String {
  let out = StringBuilder()
  for block in output.content {
    match block {
      Text(text) => out.write_string(text)
      _ => ()
    }
  }
  out.to_string()
}

// ── The happy path ─────────────────────────────────────────────────────────

///|
async test "a server starts, handshakes, and reports every page of its tools" {
  let script = write_server("fake", fake_server_source())
  @async.with_task_group(group => {
    match start_mcp_session(group, fake_config("fake", script), ".") {
      Err(reason) => fail("the server should have started: \{reason}")
      Ok(connection) => {
        let server = connection.server()
        assert_eq(server.name, "fake")
        // Two tools out of two pages: a client that stopped at the first would report only `ping`.
        assert_eq(server.tools.map(tool => tool.name), ["ping", "echo"])
        assert_eq(server.tools[0].description, "Ping.")
        // The schema the server announced, carried through unchanged — it is the server's contract.
        assert_eq(
          server.tools[0].input_schema,
          Json::object(Map([("type", Json::string("object"))])),
        )
        connection.close()
      }
    }
  })
}

///|
async test "a call reaches the server and its result comes back as content" {
  let script = write_server("call", fake_server_source())
  @async.with_task_group(group => {
    let connection = match
      start_mcp_session(group, fake_config("call", script), ".") {
      Ok(connection) => connection
      Err(reason) => fail("the server should have started: \{reason}")
    }
    assert_eq(text_of(connection.call("ping", Json::object(Map([])))), "pong")
    // A second call on the same connection: this is the part that makes a long-lived process worth
    // having, and it is also where an off-by-one in the request ids would show up.
    assert_eq(text_of(connection.call("echo", Json::object(Map([])))), "echoed")
    connection.close()
  })
}

///|
async test "a server's own error comes back as an error result" {
  let script = write_server("unknown", fake_server_source())
  @async.with_task_group(group => {
    let connection = match
      start_mcp_session(group, fake_config("unknown", script), ".") {
      Ok(connection) => connection
      Err(reason) => fail("the server should have started: \{reason}")
    }
    let output = connection.call("nope", Json::object(Map([])))
    assert_true(output.is_error)
    // The server's wording, not a message invented here: it is the part the model can act on.
    assert_true(
      text_of(output).contains("Unknown tool: nope"),
      msg=text_of(output),
    )
    connection.close()
  })
}

///|
async test "a server that announced no tools capability is not asked to list any" {
  let script = write_server("toolless", toolless_server_source())
  @async.with_task_group(group => {
    match start_mcp_session(group, fake_config("toolless", script), ".") {
      Err(reason) => fail("the server should have started: \{reason}")
      Ok(connection) => {
        // Reachable, with nothing — which is a real answer, not a failure.
        assert_eq(connection.server().tools.length(), 0)
        connection.close()
      }
    }
  })
}

// ── The failure modes ──────────────────────────────────────────────────────

///|
async test "a command that cannot be started is a reason, not an exception" {
  // The ordinary case: a server the reader configured from a README and never installed. The window
  // has to open anyway.
  let config : @core.McpConfig = Stdio({
    name: "missing",
    command: "/nonexistent/wei-test-binary",
    args: [],
    env: [],
    description: "",
  })
  @async.with_task_group(group => {
    match start_mcp_session(group, config, ".") {
      Ok(_) => fail("there is no such binary")
      Err(reason) =>
        assert_true(reason.contains("/nonexistent/wei-test-binary"), msg=reason)
    }
  })
}

///|
async test "a server that exits before answering is reported as gone" {
  // `false` starts and exits zero without ever writing a frame. The read comes back empty, which is
  // a different problem from the server saying no, and is said in those words.
  let config : @core.McpConfig = Stdio({
    name: "dead",
    command: "/usr/bin/false",
    args: [],
    env: [],
    description: "",
  })
  @async.with_task_group(group => {
    match start_mcp_session(group, config, ".") {
      Ok(_) => fail("a server that writes nothing cannot handshake")
      Err(reason) =>
        assert_true(reason.contains("closed its output"), msg=reason)
    }
  })
}

///|
async test "a server's environment is the reader's plus what the config adds" {
  // A server needs `PATH` as much as it needs its token, so the config's variables are an addition
  // rather than a replacement — which is the difference between a working server and one that cannot
  // find its own interpreter.
  let script = write_server("env", fake_server_source())
  let config : @core.McpConfig = Stdio({
    name: "env",
    command: "python3",
    args: [script],
    env: [("WEI_MCP_TEST_TOKEN", "secret")],
    description: "",
  })
  // `python3` resolves through `PATH`, which this test never sets: reaching the handshake at all is
  // the assertion.
  @async.with_task_group(group => {
    match start_mcp_session(group, config, ".") {
      Err(reason) => fail("the server should have started: \{reason}")
      Ok(connection) => {
        assert_eq(connection.server().name, "env")
        connection.close()
      }
    }
  })
}

// ── Naming and the catalog ─────────────────────────────────────────────────

///|
async test "only connected servers reach the catalog" {
  // The discipline the prompt depends on: a name in the catalog that nothing answers to sends the
  // model to a refusal, so what failed is reported to the reader instead of being listed.
  let good = write_server("catalog-good", fake_server_source())
  let configs : Array[@core.McpConfig] = [
    fake_config("good", good),
    Stdio({
      name: "missing",
      command: "/nonexistent/wei-test-binary",
      args: [],
      env: [],
      description: "",
    }),
  ]
  @async.with_task_group(group => {
    let (connections, failed) = connect_mcp_servers(group, configs, ".")
    assert_eq(failed.length(), 1)
    assert_eq(failed[0].0, "missing")
    let catalogs = mcp_catalogs(connections)
    assert_eq(catalogs.map(server => server.name), ["good"])
    // And the catalog of a connected server still carries its tools.
    assert_eq(catalogs[0].tools.length(), 2)
    // A call names a connected server, and a name nothing answers to is `None` — which is what the
    // refusal is built from.
    assert_true(mcp_connection_named(connections, "good") is Some(_))
    assert_true(mcp_connection_named(connections, "missing") is None)
    for connection in connections {
      connection.close()
    }
  })
}

// ── A connection that has gone ─────────────────────────────────────────────

///|
/// A server that handshakes and then exits.
///
/// The read after that comes back empty, which is the case the `dead` flag exists for: a stream that
/// has been closed mid-conversation cannot be resynchronized, so the connection is retired rather
/// than reused.
fn vanishing_server_source() -> String {
  let source =
    #|import sys, json
    #|
    #|def send(p):
    #|    sys.stdout.write(json.dumps(p) + "\n")
    #|    sys.stdout.flush()
    #|
    #|for line in sys.stdin:
    #|    line = line.strip()
    #|    if not line:
    #|        continue
    #|    msg = json.loads(line)
    #|    m = msg.get("method")
    #|    if m == "initialize":
    #|        send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {
    #|            "protocolVersion": "2024-11-05",
    #|            "capabilities": {"tools": {}},
    #|            "serverInfo": {"name": "vanishing", "version": "1"}}})
    #|    elif m == "tools/list":
    #|        send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": [
    #|            {"name": "say", "description": "Say it back.",
    #|             "inputSchema": {"type": "object"}}]}})
    #|        # Gone, without answering anything else.
    #|        sys.exit(0)
    #|
  source
}

///|
async test "a server that goes away is retired, and later calls say the same thing" {
  let script = write_server("vanishing", vanishing_server_source())
  @async.with_task_group(group => {
    let connection = match
      start_mcp_session(group, fake_config("vanishing", script), ".") {
      Ok(connection) => connection
      Err(reason) => fail("the server should have started: \{reason}")
    }
    assert_eq(connection.server().tools.length(), 1)
    let first = connection.call("say", Json::object(Map([])))
    assert_true(first.is_error, msg=text_of(first))
    // The second is refused from the record rather than by writing to a pipe whose reader is gone.
    // Whatever the first one said, the second says the same thing — that is the point of retiring
    // the connection instead of trying to parse whatever arrives next.
    let second = connection.call("say", Json::object(Map([])))
    assert_true(second.is_error)
    assert_eq(text_of(second), text_of(first))
    // And the reason names the server, so a turn that hit several knows which one is gone.
    assert_true(text_of(second).contains("vanishing"), msg=text_of(second))
    connection.close()
  })
}

// ── The HTTP transport ─────────────────────────────────────────────────────

///|
/// A request header as a string, or empty when it was not sent.
fn http_header(request : @http.Request, name : String) -> String {
  match request.headers.get(@http.CaseInsensitiveString(name)) {
    Some(value) => value
    None => ""
  }
}

///|
/// A Streamable HTTP MCP server, on a real socket.
///
/// A fake rather than a mock: the transport under test is a real HTTP client, so the thing on the
/// other end has to be a real HTTP server or the test is about a stub. What it answers is fixed — one
/// tool, `say`, echoing its `text` argument — and what it *checks* is recorded, because the header
/// rules are the part of this transport a client can get wrong silently.
///
/// `seen` collects `(path, session id, authorization)` per request so a test can assert both that the
/// session id from `initialize` was echoed and that the configured headers went out.
async fn serve_http_mcp(
  server : @http.Server,
  seen : Array[(String, String, String)],
  call_as_stream : Bool,
) -> Unit {
  server.run_forever() <| ((request, body, connection) => {
    let raw = @utf8.decode_lossy(body.read_all().binary())
    let session = http_header(request, "mcp-session-id")
    let auth = http_header(request, "Authorization")
    seen.push((request.path, session, auth))
    let message = try @json.parse(raw) catch {
      _ => Json::null()
    } noraise {
      json => json
    }
    let id = @core.arg_int(message, "id").unwrap_or(0)
    let rpc_method = @core.arg_required_string(message, "method")
    let reply = match rpc_method {
      "initialize" =>
        Json::object(
          Map([
            ("jsonrpc", Json::string("2.0")),
            ("id", Json::number(id.to_double())),
            (
              "result",
              Json::object(
                Map([
                  ("protocolVersion", Json::string("2024-11-05")),
                  (
                    "capabilities",
                    Json::object(Map([("tools", Json::object(Map([])))])),
                  ),
                  (
                    "serverInfo",
                    Json::object(
                      Map([
                        ("name", Json::string("http")),
                        ("version", Json::string("1")),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        )
      "tools/list" =>
        Json::object(
          Map([
            ("jsonrpc", Json::string("2.0")),
            ("id", Json::number(id.to_double())),
            (
              "result",
              Json::object(
                Map([
                  (
                    "tools",
                    Json::array([
                      Json::object(
                        Map([
                          ("name", Json::string("say")),
                          ("description", Json::string("Say it back.")),
                          (
                            "inputSchema",
                            Json::object(
                              Map([("type", Json::string("object"))]),
                            ),
                          ),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        )
      "tools/call" =>
        Json::object(
          Map([
            ("jsonrpc", Json::string("2.0")),
            ("id", Json::number(id.to_double())),
            (
              "result",
              Json::object(
                Map([
                  (
                    "content",
                    Json::array([
                      Json::object(
                        Map([
                          ("type", Json::string("text")),
                          ("text", Json::string("http said: hi")),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        )
      _ => Json::null()
    }
    // The notification is answered with a bare `202`, exactly as the transport specifies — no body,
    // and no JSON-RPC envelope, because there is no request id to carry a reply to.
    if rpc_method == "notifications/initialized" {
      connection.send_response(202, "Accepted")
      connection.end_response()
      return
    }
    let headers : @http.Headers = Map([])
    if rpc_method == "initialize" {
      headers.set(@http.CaseInsensitiveString("mcp-session-id"), "sess-1")
    }
    let text = reply.stringify()
    let body_text = if call_as_stream && rpc_method == "tools/call" {
      // The other accepted shape: an event stream carrying one message. A client that assumed JSON
      // would fail to parse this, which is the case this exists to catch.
      headers.set(
        @http.CaseInsensitiveString("Content-Type"),
        "text/event-stream",
      )
      "data: " + text + "\n\n"
    } else {
      headers.set(
        @http.CaseInsensitiveString("Content-Type"),
        "application/json",
      )
      text
    }
    connection.send_response(200, "OK", extra_headers=headers)
    connection.write(body_text)
    connection.end_response()
  })
}

///|
fn http_config(url : String) -> @core.McpConfig {
  Http({
    name: "http",
    url,
    headers: [("Authorization", "Bearer test-token")],
    description: "A remote server.",
  })
}

///|
async test "an http server handshakes, lists, and answers a call" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  let seen : Array[(String, String, String)] = []
  @async.with_task_group(group => {
    ignore(group.spawn(() => serve_http_mcp(server, seen, false), no_wait=true))
    @async.sleep(20)
    let session = match
      start_mcp_session(group, http_config("http://127.0.0.1:\{port}/mcp"), ".") {
      Ok(session) => session
      Err(reason) => fail("the server should have started: \{reason}")
    }
    // Three requests: initialize, the notification, and tools/list.
    assert_eq(session.server().name, "http")
    assert_eq(session.server().tools.map(tool => tool.name), ["say"])
    assert_eq(session.server().tools[0].description, "Say it back.")
    assert_eq(
      text_of(session.call("say", @json.parse("{\"text\":\"hi\"}"))),
      "http said: hi",
    )
    // The session id from `initialize` was echoed on every request after it, and the configured
    // header went out on all of them. Both are rules a client can silently get wrong: a server that
    // does not see its own id answers 400, and one that does not see the token answers 401.
    assert_true(seen.length() >= 3, msg="expected at least three requests")
    assert_eq(
      seen[0].1,
      "",
      msg="initialize must not claim a session it has not been given",
    )
    for i = 1; i < seen.length(); i = i + 1 {
      assert_eq(seen[i].1, "sess-1", msg="request \{i} lost the session id")
    }
    for entry in seen {
      assert_eq(
        entry.2,
        "Bearer test-token",
        msg="a request went out without the token",
      )
    }
    assert_eq(seen[0].0, "/mcp")
    session.close()
    server.close()
  })
}

///|
async test "a call answered as an event stream is read as one" {
  // The transport lets a server answer with either shape, and which one it chose is in the content
  // type rather than in the body. A client that only parsed JSON would report a working server as
  // broken, which is why this is a separate server rather than a second assertion on the first.
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  let seen : Array[(String, String, String)] = []
  @async.with_task_group(group => {
    ignore(group.spawn(() => serve_http_mcp(server, seen, true), no_wait=true))
    @async.sleep(20)
    let session = match
      start_mcp_session(group, http_config("http://127.0.0.1:\{port}/mcp"), ".") {
      Ok(session) => session
      Err(reason) => fail("the server should have started: \{reason}")
    }
    assert_eq(text_of(session.call("say", @json.parse("{}"))), "http said: hi")
    session.close()
    server.close()
  })
}

///|
async test "a server that is not there is a reason, not a hang" {
  // Port 1 is reserved and nothing listens on it. The failure has to arrive as a value: a session
  // that cannot connect must not be able to keep a window from opening.
  @async.with_task_group(group => {
    match start_mcp_session(group, http_config("http://127.0.0.1:1/mcp"), ".") {
      Ok(_) => fail("nothing is listening on port 1")
      Err(reason) => assert_true(reason.contains("127.0.0.1:1"), msg=reason)
    }
  })
}
