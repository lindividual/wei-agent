///|
/// MCP, from the shell's side: what a `.mcp.json` in a repository does to a session opened there.
///
/// The protocol decisions are pinned in `core/mcp_test.mbt` and the transport in
/// `platform/mcp_test.mbt`. What is left, and what is only reachable here, is the wiring: that a
/// config file is found, that the servers come up, that the gateway is declared **only** when there
/// is one, and that the catalog the prompt carries names exactly what a call can reach. Those are
/// `Shell::` decisions, so they cross the seam a keystroke does — `Shell::of`, a literal `World`, and
/// an array to record into.

///|
/// A scratch repository directory for one test.
async fn mcp_scratch() -> String {
  let dir = "_build/mcp_shell/\{@core.new_entry_id()}"
  @platform.make_dirs(dir)
  // Absolute, because a server is started with the session's cwd and a real config names its command
  // by an absolute path or a bare name on `PATH`. A relative one would be resolved against the
  // session's directory, which is the same directory only by coincidence.
  "\{@platform.current_dir()}/\{dir}"
}

///|
/// A shell over a repository that has a `.mcp.json`, and the list of everything it says.
///
/// The config is a real file in a real scratch directory because that is the thing under test: the
/// shell reaches the servers through `read_mcp_config`, so a fixture that handed it the parsed value
/// would be testing the parser again and not the wiring.
async fn mcp_shell(
  dir : String,
  servers : String,
) -> (Shell, () -> Array[Json]) {
  @platform.write_text("\{dir}/.mcp.json", servers)
  let seen : Array[Json] = []
  let session = @core.Session::new(
    {
      id: "s",
      timestamp: @core.format_iso_utc(0L),
      cwd: dir,
      parent_session: None,
      version: Some(3),
    },
    [],
  )
  let shell = Shell::of(
    {
      home: dir,
      settings: @core.decode_app_settings(""),
      root: "\{dir}/sessions",
      start: dir,
      base_url: "https://api.deepseek.com",
      jobs: @core.JobStore::new(),
      pins: [],
      session,
      path: "\{dir}/session.jsonl",
      session_bytes: 0L,
      debug_log: "",
      facts: [],
    },
    out=json => seen.push(json),
  )
  (shell, () => seen)
}

///|
/// A server that echoes, written beside the config that names it.
///
/// One directory for both, so the config can name the script by the absolute path a real config would
/// use — a relative `command` would be resolved against the session's cwd, which is the same
/// directory only by coincidence.
async fn mcp_shell_server(dir : String) -> String {
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
    #|            "serverInfo": {"name": "echo", "version": "1"}}})
    #|    elif m == "tools/list":
    #|        send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": [
    #|            {"name": "say", "description": "Say it back.",
    #|             "inputSchema": {"type": "object"}}]}})
    #|
  let path = "\{dir}/echo_server.py"
  @platform.write_text(path, source)
  path
}

///|
/// A config naming one stdio server, with a description and an unknown command for the one that
/// cannot start.
fn mcp_shell_config(script : String) -> String {
  let echo = "{\"command\":\"python3\",\"args\":[\"" +
    script +
    "\"],\"description\":\"Says things back.\"}"
  let broken = "{\"command\":\"/nonexistent/wei-test-binary\"}"
  "{\"mcpServers\":{\"echo\":" + echo + ",\"broken\":" + broken + "}}"
}

///|
/// The server is started by the first command, and the turn that follows reaches it.
///
/// The order matters and is the point: the servers are ensured *before* the request is built, so what
/// the model is handed describes what is actually there. A design that started them lazily on the
/// first call would have to send a catalog full of names that might not answer.
async test "a config file's server comes up, and the turn carries the gateway and its catalog" {
  let dir = mcp_scratch()
  let script = mcp_shell_server(dir)
  let (shell, _seen) = mcp_shell(dir, mcp_shell_config(script))
  let open = shell.shown()
  @async.with_task_group(group => {
    // Before anything: no server has been looked for, so the tool set is the plain one.
    assert_false(
      @core.has_tool(shell.mcp_tools(open.cwd, @core.builtin_tools()), "mcp"),
    )
    // The first command is what opens the directory — here a cheap one that does not start a turn,
    // because the turn itself needs a provider.
    shell.mcp_ensure(group, open.cwd)
    let connections = shell.mcp_here(open.cwd)
    assert_eq(connections.length(), 1)
    assert_eq(connections[0].server().name, "echo")
    // The gateway is declared, and the catalog names exactly the server that answered — the
    // unstartable one is absent, which is what keeps the model from calling it.
    let tools = shell.mcp_tools(open.cwd, @core.builtin_tools())
    assert_true(@core.has_tool(tools, "mcp"))
    let catalog = @core.mcp_catalog_prompt(shell.mcp_servers(open.cwd))
    assert_true(catalog.contains("- echo — Says things back."), msg=catalog)
    assert_true(catalog.contains("`say`"), msg=catalog)
    assert_false(catalog.contains("broken"), msg=catalog)
    // And the prompt a turn would send carries it.
    let prompt = shell.system_prompt(open, tools)
    assert_true(prompt.contains("## MCP servers"), msg=prompt)
    // Twice is once: the ensure is idempotent, so a second call does not start a second process.
    shell.mcp_ensure(group, open.cwd)
    assert_eq(shell.mcp_here(open.cwd).length(), 1)
    shell.mcp_dispose()
  })
}

///|
/// A repository with no config gets no gateway, and the prompt is byte-identical to before MCP.
///
/// The property the whole design is built around: MCP costs a workspace nothing until it configures a
/// server, so a session in an ordinary repository sends exactly what it sent before this feature
/// existed.
async test "no config means no gateway and no section in the prompt" {
  let dir = mcp_scratch()
  let (shell, _seen) = mcp_shell(dir, "{\"mcpServers\":{}}")
  let open = shell.shown()
  @async.with_task_group(group => {
    shell.mcp_ensure(group, open.cwd)
    assert_eq(shell.mcp_here(open.cwd).length(), 0)
    let tools = shell.mcp_tools(open.cwd, @core.builtin_tools())
    assert_false(@core.has_tool(tools, "mcp"))
    let prompt = shell.system_prompt(open, tools)
    assert_false(prompt.contains("## MCP servers"), msg=prompt)
    // And the prompt is the one this shell would send if `servers` did not exist: same workspace
    // instructions, same skill catalog, same tool list, no section. That is the claim MCP has to
    // keep — an empty server list contributes no bytes.
    assert_eq(
      prompt,
      @core.build_system_prompt(
        open.cwd,
        tools,
        skills=shell.enabled_skills(open.cwd),
      ),
    )
    shell.mcp_dispose()
  })
}

///|
/// A config whose only server cannot start leaves the workspace exactly as it was.
///
/// The failure mode worth pinning: a typo in a command must not put a gateway in the request that
/// reaches nothing, and must not take the session down with it. The window opens, the turn runs, and
/// the server is simply absent.
async test "a server that cannot start leaves no gateway behind" {
  let dir = mcp_scratch()
  let (shell, _seen) = mcp_shell(
    dir, "{\"mcpServers\":{\"broken\":{\"command\":\"/nonexistent/wei-test-binary\"}}}",
  )
  let open = shell.shown()
  @async.with_task_group(group => {
    shell.mcp_ensure(group, open.cwd)
    assert_eq(shell.mcp_here(open.cwd).length(), 0)
    let tools = shell.mcp_tools(open.cwd, @core.builtin_tools())
    assert_false(@core.has_tool(tools, "mcp"))
    assert_false(shell.system_prompt(open, tools).contains("## MCP servers"))
    // Marked as examined, so a broken config costs one handshake attempt and not one per turn.
    shell.mcp_ensure(group, open.cwd)
    assert_true(shell.mcp.get(open.cwd) is Some(_))
    shell.mcp_dispose()
  })
}

// ── `/mcp` ─────────────────────────────────────────────────────────────────

///|
/// The report names what is up and what did not come up.
///
/// The second half is the point: the catalog deliberately omits servers that failed, so a typo in a
/// `command` would otherwise be a feature that silently does nothing. This row is the only place the
/// reason is readable, which makes it the one thing `/mcp` is for that nothing else covers.
test "the report lists servers, their tools, and the ones that did not start" {
  let connections : Array[@platform.McpSession] = []
  let failures : Array[(String, String)] = [
    ("broken", "could not start `/nonexistent/x`: ..."),
  ]
  let text = mcp_report_text(connections, failures, [])
  assert_true(text.contains("broken"), msg=text)
  assert_true(text.contains("did not start"), msg=text)
  assert_true(text.contains("/nonexistent/x"), msg=text)
}

///|
/// A workspace with nothing configured is told what a server *is*, not that something is broken.
test "an empty report says what a server would be" {
  let text = mcp_report_text([], [], [])
  assert_true(text.contains(".mcp.json"), msg=text)
  assert_false(text.contains("did not start"), msg=text)
}

///|
/// `/mcp` is a command, not a question.
///
/// A word that fell through to `Prompt` would be sent to the model and billed for — the exact failure
/// every command word here is spelled out to avoid.
test "the mcp command is parsed as a command" {
  // `Command` has no `Eq`, so the check is the shape: a prompt would be `Prompt("/mcp")`, which is
  // exactly the failure this word is spelled out to avoid.
  match command_of("/mcp") {
    ReportMcp => ()
    Prompt(text) => fail("`/mcp` would have been sent to the model as: \{text}")
    _ => fail("`/mcp` is not the command it should be")
  }
  // And asking is never refused: it reads, it does not disturb a running turn's file.
  assert_true(gate(ReportMcp, false) is Allowed)
  assert_true(gate(ReportMcp, true) is Allowed)
}

///|
/// A `/mcp` in a repository with a server says so, through the real command loop.
async test "the mcp command reports this workspace's servers" {
  let dir = mcp_scratch()
  let script = mcp_shell_server(dir)
  let (shell, seen) = mcp_shell(dir, mcp_shell_config(script))
  // The ensure runs inside `handle`, before the command is dispatched — the same order a turn gets,
  // so what `/mcp` reports is what a turn would be given.
  command(shell, "/mcp")
  let lines = seen()
  assert_eq(lines.length(), 1)
  let text = lines[0].stringify()
  assert_true(text.contains("\"kind\":\"note\""), msg=text)
  assert_true(text.contains("\"name\":\"mcp\""), msg=text)
  assert_true(text.contains("echo"), msg=text)
  assert_true(text.contains("say"), msg=text)
  // The unstartable server is reported too — that is the whole reason this command exists.
  assert_true(text.contains("broken"), msg=text)
  assert_true(text.contains("did not start"), msg=text)
  shell.mcp_dispose()
}

// ── The switch ─────────────────────────────────────────────────────────────

///|
/// `/mcp <name>` is a switch, and bare `/mcp` is the report. One word apart, and the space is the
/// whole distinction — the same rule `/skill` follows.
test "the mcp command tells a report from a switch" {
  match command_of("/mcp") {
    ReportMcp => ()
    Prompt(text) => fail("`/mcp` would have been sent to the model: \{text}")
    _ => fail("`/mcp` is not the report")
  }
  match command_of("/mcp github") {
    ToggleServer(name) => assert_eq(name, "github")
    Prompt(text) => fail("`/mcp github` would have been sent: \{text}")
    _ => fail("`/mcp github` is not a switch")
  }
  // Both are read-only with respect to a running turn's file, so neither is refused.
  assert_true(gate(ReportMcp, true) is Allowed)
  assert_true(gate(ToggleServer("github"), true) is Allowed)
}

///|
/// Switching a server off takes it out of the turn's tool set and out of the prompt, and the row says
/// so — all three, because they are one decision seen from three sides.
async test "a switched-off server is not offered to a turn" {
  let dir = mcp_scratch()
  let script = mcp_shell_server(dir)
  let (shell, _seen) = mcp_shell(dir, mcp_shell_config(script))
  let open = shell.shown()
  @async.with_task_group(group => {
    shell.mcp_ensure(group, open.cwd)
    // Up, and offered: one server, and the gateway with it.
    assert_eq(shell.mcp_all(open.cwd).length(), 1)
    assert_true(
      @core.has_tool(shell.mcp_tools(open.cwd, @core.builtin_tools()), "mcp"),
    )
    assert_true(
      shell
      .system_prompt(open, @core.builtin_tools())
      .contains("## MCP servers"),
    )

    // Switched off. The process is still up — see `mcp_ensure` for why that is deliberate — but
    // nothing downstream of the switch can see it.
    command(shell, "/mcp echo")
    assert_eq(shell.settings.disabled_servers, ["echo"])
    assert_eq(shell.mcp_all(open.cwd).length(), 1, msg="the process stays up")
    assert_eq(
      shell.mcp_here(open.cwd).length(),
      0,
      msg="but it is not reachable",
    )
    let tools = shell.mcp_tools(open.cwd, @core.builtin_tools())
    assert_false(
      @core.has_tool(tools, "mcp"),
      msg="no server means no gateway, so the request is the plain built-in one",
    )
    assert_false(shell.system_prompt(open, tools).contains("## MCP servers"))
    // And the panel row says off rather than listing a tool count. Rows are in name order, so the
    // entry is picked out by name rather than by position.
    let entries = shell.server_entries(open.cwd)
    let mut echo : @core.ServerEntry? = None
    for entry in entries {
      if entry.name == "echo" {
        echo = Some(entry)
      }
    }
    let echo = match echo {
      Some(entry) => entry
      None => fail("the server should have a row")
    }
    assert_eq(echo.enabled, false)
    assert_true(echo.note == "", msg="a switch that is off is not a fault")

    // And back on, in the same process, with no restart: the switch is read at the top of a turn.
    command(shell, "/mcp echo")
    assert_eq(shell.settings.disabled_servers, [])
    assert_eq(shell.mcp_here(open.cwd).length(), 1)
    assert_true(
      @core.has_tool(shell.mcp_tools(open.cwd, @core.builtin_tools()), "mcp"),
    )
    shell.mcp_dispose()
  })
}

///|
/// The panel's row for a server that did not come up carries the reason.
///
/// The one fact about MCP a reader cannot get any other way: the catalog omits what failed, so a typo
/// in a command is otherwise a feature that silently does nothing.
async test "a broken server's row explains itself" {
  let dir = mcp_scratch()
  let (shell, _seen) = mcp_shell(
    dir, "{\"mcpServers\":{\"broken\":{\"command\":\"/nonexistent/wei-test-binary\"}}}",
  )
  let open = shell.shown()
  @async.with_task_group(group => {
    shell.mcp_ensure(group, open.cwd)
    let entries = shell.server_entries(open.cwd)
    assert_eq(entries.length(), 1)
    assert_eq(entries[0].name, "broken")
    assert_eq(entries[0].transport, "stdio")
    assert_true(entries[0].enabled)
    assert_eq(entries[0].tool_count, 0)
    assert_true(
      entries[0].note.contains("/nonexistent/wei-test-binary"),
      msg=entries[0].note,
    )
    shell.mcp_dispose()
  })
}

///|
/// An entry this client cannot read a transport out of is still a row, with why.
///
/// It never became a connection, so a panel built from the connections alone would drop it — and an
/// entry a reader typed that has no row is the same failure as one that failed to start with no
/// reason.
async test "a config entry with no transport is a row too" {
  let dir = mcp_scratch()
  let (shell, _seen) = mcp_shell(
    dir, "{\"mcpServers\":{\"mystery\":{\"args\":[]}}}",
  )
  let open = shell.shown()
  @async.with_task_group(group => {
    shell.mcp_ensure(group, open.cwd)
    let entries = shell.server_entries(open.cwd)
    assert_eq(entries.length(), 1)
    assert_eq(entries[0].name, "mystery")
    assert_eq(entries[0].transport, "", msg="there is no transport to name")
    assert_true(entries[0].note.contains("`command`"), msg=entries[0].note)
    shell.mcp_dispose()
  })
}

///|
/// A name switched off and then removed from the config is still a row.
///
/// The rule the skills list already follows: a setting a reader cannot see is a setting they cannot
/// undo. Without this, deleting a server from `.mcp.json` while it was off would leave a name in
/// `settings.json` with nothing on screen to flip back.
test "a switched-off name with no config behind it is still listed" {
  let entries = @core.server_entries([], [], [], ["ghost"])
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "ghost")
  assert_eq(entries[0].enabled, false)
  assert_true(entries[0].note == "", msg="off on purpose is not a fault")
}
