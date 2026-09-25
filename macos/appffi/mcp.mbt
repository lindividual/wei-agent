///|
/// The shell's side of MCP: which servers a working directory has, and when they start and stop.
///
/// The protocol, the config format and the transport are all elsewhere — `core/mcp*.mbt` and
/// `platform/mcp*.mbt` — and none of them decides *when* a process should be started or how long it
/// should live. That is a fact about a window, so it lives here.
///
/// The shape is `skills_here`'s, one directory at a time: a server is a fact about a project, two
/// sessions in two repositories must each reach their own, and the map is what keeps a turn from
/// re-reading a config file it has already read.
///
/// **When they start.** On demand, when a session in a directory is first acted on, and never
/// *inside* the request that needs them: the servers are up before the turn's tool set is built, so
/// the model is never handed a catalog describing something that is not there yet. A server that
/// hangs costs its handshake timeout on that first command and nothing afterwards.
///
/// **When they stop.** At quit, all of them, from the same place the sessions are stopped. A server
/// that outlived the window it was started for would be a process nobody could see, on a machine
/// whose only interface for stopping one is this window.
///
/// **A server that does not come up is absent from the catalog but not from the record.** The
/// catalog names only what answered — a name the model cannot call is worse than no name at all —
/// so the reason is kept beside the connections and shown by `/mcp`. Without that, a typo in a
/// `command` would be a feature that silently does nothing.
///
/// **A switched-off server is started and then not offered**, which reads backwards and is
/// deliberate. The alternative — not starting it — would leave the panel unable to say what is behind
/// the switch, and the reader deciding whether to trust a server is exactly the reader who wants to
/// see its tool list first. Being up costs one connection; being unreachable costs only a
/// `disabled_servers` entry.

///|
/// Start this directory's servers if they have not been started.
///
/// Idempotent, and idempotent *including the failures*: a directory whose config is broken is marked
/// as examined with an empty connection list, so a turn in it does not retry a handshake that just
/// failed. Retrying per turn would make one broken server a source of a new timeout on every
/// question, which is the opposite of what a reader wants.
///
/// Idempotence is what lets this be called from two places — before a command, and after one that
/// may have changed which session is on screen — without either having to know whether the other
/// ran.
async fn[X] Shell::mcp_ensure(
  self : Shell,
  group : @async.TaskGroup[X],
  cwd : String,
) -> Unit {
  if self.mcp.get(cwd) is Some(_) {
    return
  }
  let entries = @platform.read_mcp_config(cwd, self.home)
  let configs = @core.startable_servers(entries)
  // Marked before the start, not after: `connect_mcp_servers` reads config files and spawns
  // processes, and a re-entrant ensure during that window — a second turn starting while the first
  // is still opening servers — would start every server twice.
  self.mcp.set(cwd, [])
  let (connected, failed) = @platform.connect_mcp_servers(group, configs, cwd)
  self.mcp.set(cwd, connected)
  // The entries this client cannot run at all are listed with the ones that were tried and failed,
  // because to a reader they are the same thing: a server in their config that does not work. Only
  // one of the two reasons is actionable, and the reason says which.
  let not_up : Array[(String, String)] = []
  for entry in entries {
    // Only `Unsupported` is a failure to record: the two real transports were tried, and whatever
    // happened to them is in `failed` already.
    match entry {
      @core.Unsupported(name~, reason~) => not_up.push((name, reason))
      _ => ()
    }
  }
  for failure in failed {
    not_up.push(failure)
  }
  self.mcp_failed.set(cwd, not_up)
}

///|
/// Every server this directory has running, switched on or off.
///
/// The unfiltered view, and the one the panel and `/mcp` are built from: a switched-off server still
/// has a tool count and still has a reason if it failed, and both are things a reader deciding about
/// the switch needs. Empty until `mcp_ensure` has run, and empty for a directory with no config,
/// which is the ordinary case.
fn Shell::mcp_all(self : Shell, cwd : String) -> Array[@platform.McpSession] {
  match self.mcp.get(cwd) {
    Some(connections) => connections
    None => []
  }
}

///|
/// This directory's servers that a turn may actually reach: running, and not switched off.
///
/// Filtered at read time rather than at start time, so flipping a switch takes effect on the next turn
/// without a restart — the same rule `enabled_skills` follows, and for the same reason: the panel has
/// to be able to list what is off in order to turn it back on, and it cannot list what was never
/// started.
fn Shell::mcp_here(self : Shell, cwd : String) -> Array[@platform.McpSession] {
  let out : Array[@platform.McpSession] = []
  for session in self.mcp_all(cwd) {
    if self.settings.server_enabled(session.server().name) {
      out.push(session)
    }
  }
  out
}

///|
/// This directory's servers, in the shape the prompt takes them.
fn Shell::mcp_servers(self : Shell, cwd : String) -> Array[@core.McpServer] {
  @platform.mcp_catalogs(self.mcp_here(cwd))
}

///|
/// The tool set a turn in this directory is given, gateway included.
///
/// One function for both halves, because they are one decision: the gateway is declared exactly when
/// there is a server for it to reach, and the catalog names exactly the servers it can reach. A
/// caller that built one without the other would send an `mcp` tool with no servers to call, or name
/// servers the turn has no way to reach.
fn Shell::mcp_tools(
  self : Shell,
  cwd : String,
  tools : Array[@core.ToolDef],
) -> Array[@core.ToolDef] {
  @platform.tools_with_mcp(tools, self.mcp_here(cwd))
}

///|
/// Stop every server this process started.
///
/// Called once, at quit, and deliberately not when a session closes: a server is keyed by directory,
/// and a session closing is not a statement that the reader is done with the repository.
fn Shell::mcp_dispose(self : Shell) -> Unit {
  // The unfiltered map, deliberately: a switched-off server is still a process this window started,
  // and a switch is not a statement that its process should be left running with nobody to stop it.
  for _, connections in self.mcp {
    for connection in connections {
      connection.close()
    }
  }
}

// ── What `/mcp` answers with ───────────────────────────────────────────────

///|
/// This working directory's servers, as a reader wants to read them.
///
/// A row per server: the ones that are up with what they offer, then the ones that are not with why.
/// The order is the point — what is reachable comes first, because that is what the reader is usually
/// asking, and the failures are the footnote they only need when something they expected is missing.
///
/// **This is the one place a failed server is visible.** The catalog names only what answered, since a
/// name the model cannot call is worse than no name at all, so a typo in a `command` would otherwise
/// be a feature that silently does nothing. The reason travels with the row for exactly that reason.
fn Shell::mcp_failures(self : Shell, cwd : String) -> Array[(String, String)] {
  match self.mcp_failed.get(cwd) {
    Some(failures) => failures
    None => []
  }
}

///|
fn mcp_report_text(
  connections : Array[@platform.McpSession],
  failures : Array[(String, String)],
  disabled : Array[String],
) -> String {
  if connections.is_empty() && failures.is_empty() {
    return "no MCP servers here — a server is a `.mcp.json` in the working directory, or `~/.wei/mcp.json`"
  }
  let out = StringBuilder()
  for connection in connections {
    let server = connection.server()
    if out.to_string() != "" {
      out.write_string("\n")
    }
    out.write_string("\{server.name} — \{server.tools.length()} tool(s)")
    if server.description != "" {
      out.write_string(" · \{server.description}")
    }
    // Said here as well as in the panel, because the two are read in different frames of mind: this
    // is what a reader types when a model reach for something that did not happen, and "off" is a
    // different answer from "not there" — the first is a switch they flipped and forgot.
    if disabled.contains(server.name) {
      out.write_string(" · off")
    }
    out.write_string("\n")
    for tool in server.tools {
      out.write_string("  \{tool.name}\n")
    }
  }
  // A pair rather than two loop variables: `for a, b in array` is index-and-element, which would
  // bind `reason` to the whole tuple.
  for failure in failures {
    if out.to_string() != "" {
      out.write_string("\n")
    }
    let (name, reason) = failure
    out.write_string("\{name} — did not start: \{reason}\n")
  }
  out.to_string()
}

///|
/// What `/mcp` says: this directory's servers, and its configured ones that did not come up.
///
/// The servers are already started by the time this runs — the command loop ensures them before it
/// dispatches, and this is dispatched from there — so the answer is about this machine rather than
/// about a cache: a reader who just fixed a server's command and types `/mcp` is told the truth.
///
/// A note rather than a status line, because this is a fact about the workspace and stays readable;
/// the status line is one sentence that the next thing said overwrites.
fn Shell::report_mcp(self : Shell, open : Open) -> Unit {
  self.say_note(
    open.path,
    mcp_report_text(
      // The unfiltered list: `/mcp` reports what a *workspace* has, including what is switched off,
      // because the reader asking what happened to `github` is usually the reader who turned it off.
      self.mcp_all(open.cwd),
      self.mcp_failures(open.cwd),
      self.settings.disabled_servers,
    ),
    "mcp",
  )
}

// ── The settings panel's view ──────────────────────────────────────────────

///|
/// Every configured server as the panel shows it.
///
/// The configured list is read fresh rather than remembered from `mcp_ensure`, because the panel has
/// to answer a question the catalog never asks: what did the reader *write down*, including the
/// entries this client could not run at all. Those never became connections, so a view built from the
/// connections alone would silently drop them — and an entry a reader typed that has no row is the
/// same failure as one that failed to start with no reason.
async fn Shell::server_entries(
  self : Shell,
  cwd : String,
) -> Array[@core.ServerEntry] {
  let configured = @platform.read_mcp_config(cwd, self.home)
  @core.server_entries(
    configured,
    @platform.mcp_catalogs(self.mcp_all(cwd)),
    self.mcp_failures(cwd),
    self.settings.disabled_servers,
  )
}
