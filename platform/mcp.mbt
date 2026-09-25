///|
/// Speaking MCP to a server: a child process over stdio, or a URL over HTTP.
///
/// The transport, and only the transport: starting a server, framing a message, and waiting for the
/// answer that belongs to a request. Every decision about *what* the frames mean is in
/// `core/mcp.mbt`, which is pure and tested against fixed bytes; this file is the part that has to
/// talk to something outside the process.
///
/// **The connection is long-lived, and that is why it is not a tool.** A server is started once and
/// asked many times; starting one per call would pay the startup in the middle of a turn and lose
/// whatever state the server keeps — and for stdio that startup is a process. So the shell starts
/// servers when a session opens and holds them.
///
/// **Requests are answered in order, synchronously.** One request goes out and the answer carrying
/// its id comes back — notifications and unparsable lines are passed over. That is enough because
/// the calls this client makes are already serial: a batch of tool calls runs one at a time (see
/// `agent/driver.mbt`), so a queue of outstanding requests would be machinery for a concurrency that
/// does not occur, and a pending-reply table that has to be kept correct under cancellation is a
/// real cost for no gain. The discipline that comes with it is that a server which needs a *reply*
/// from us before answering cannot be talked to — this client answers nothing — and the timeout is
/// what keeps that from hanging a turn.
///
/// **The two transports share the session, not the wire.** `mcp_open_session` is the handshake —
/// initialize, initialized, list every page of tools — and both transports call it, because a second
/// copy of that sequence is a second thing to keep in step with the protocol. What differs is one
/// function below it: `send` writes to a pipe or posts to a URL, and nothing above that line knows
/// which.

///|
/// How long a handshake may take.
///
/// Shorter than a call, because a server that has not answered `initialize` is usually not going to:
/// a command that is not installed, a binary that is not a server, or one waiting on a prompt. The
/// cost of being wrong is a server that would have worked being reported as failed, so it is not
/// short.
fn mcp_handshake_timeout_ms() -> Int {
  15000
}

///|
/// How long one `tools/call` may take.
///
/// Generous on purpose: a server's tool may be doing real work — a search, a fetch, a query — and
/// this is not a timeout on the *server*, only on how long this client will wait for it to answer.
/// Two minutes is longer than any call is likely to need and short enough that a wedged server does
/// not hold a turn open forever.
pub fn mcp_call_timeout_ms() -> Int {
  120000
}

///|
/// A live server reached over stdio: what it is, what it has, and the pipe to it.
pub struct McpStdio {
  /// Name, description and tools, in the shape the catalog and the prompt take. Held rather than
  /// re-derived so the catalog cannot disagree with what the connection actually offers.
  priv server : @core.McpServer
  /// The child. Held so the connection can end it: a server that is never asked again should not
  /// outlive the session that started it.
  priv proc : @process.Process
  /// Writing to this end is the request side. Closing it is EOF, which is how a server is told to
  /// stop.
  priv writer : @process.WriteToProcess
  /// The reply side. Reads are line-delimited by the transport's rules.
  priv reader : @process.ReadFromProcess
  priv mut next_id : Int
  /// Why this connection can no longer be used, or `None` while it still can.
  ///
  /// **A timed-out read is the reason this exists.** `read_until` is cancelled mid-line by the
  /// timeout, and a cancelled read may have consumed bytes it never handed back — so after a timeout
  /// the stream's framing is no longer trustworthy and the next reply could be matched to the wrong
  /// request. Resynchronizing a byte stream with no delimiter guarantee is not something this client
  /// can do, and pretending it can would be worse than saying so: the connection is marked dead and
  /// every later call is refused with the one reason that explains all of them.
  ///
  /// A server that closed its output lands here too, for the same reason and a simpler one.
  priv mut dead : String?
}

///|
pub fn McpStdio::server(self : McpStdio) -> @core.McpServer {
  self.server
}

///|
/// Start a child process and complete the handshake, or say why it could not be done.
///
/// A failure is a value rather than an exception because it is the ordinary case: a command that is
/// not installed, a server that answers with an error, one that hangs. The caller is a settings
/// panel that has somewhere to show it, and a session that should open anyway — a broken server must
/// not be able to keep the window from opening.
async fn[X] start_mcp_stdio(
  group : @async.TaskGroup[X],
  config : @core.McpStdioConfig,
  cwd : String,
) -> Result[McpStdio, String] {
  let (reader, stdout_pipe) = @process.read_from_process()
  let (stdin_pipe, writer) = @process.write_to_process()
  // The child's environment is the reader's plus what the config adds: a server needs `PATH` and
  // `HOME` as much as it needs its token. `extra_env` rather than a replacement.
  let env : Map[String, String] = Map(config.env)
  // stderr is left alone — the child inherits this process's, so a server that logs is readable and
  // a server that logs a lot cannot block on a full pipe nobody is draining.
  let proc = try
    @process.spawn(
      group,
      config.command,
      config.args,
      extra_env=env,
      stdin=stdin_pipe,
      stdout=stdout_pipe,
      cwd~,
      no_wait=true,
    )
  catch {
    err => {
      // Both ends are dropped on the way out so a half-started child cannot be left holding them.
      writer.close()
      reader.close()
      return Err("could not start `\{config.command}`: \{err}")
    }
  } noraise {
    proc => proc
  }
  let self : McpStdio = {
    server: { name: config.name, description: config.description, tools: [], },
    proc,
    writer,
    reader,
    next_id: 1,
    dead: None,
  }
  match self.open_session() {
    Ok(tools) => Ok({ ..self, server: { ..self.server, tools, }, })
    Err(reason) => {
      // A server that failed to handshake is stopped here rather than left running: nothing will
      // ever talk to it, and a process nobody holds is a process nobody stops.
      self.close()
      Err(reason)
    }
  }
}

///|
/// End a connection: EOF, then make sure it went.
///
/// Closing the write end is the polite shutdown and is usually enough — a server that reads its
/// input sees EOF and exits. The cancel is for the ones that do not, and it is not conditional
/// because there is no portable way to ask whether a process has exited without waiting for it, and
/// waiting here would block the caller that is closing a window.
pub fn McpStdio::close(self : McpStdio) -> Unit {
  self.writer.close()
  self.reader.close()
  self.proc.cancel()
}

// ── The session, shared by both transports ────────────────────────────────

///|
/// How one request goes out and its answer comes back.
///
/// The builder takes the id rather than the message, because the id is what the caller allocates and
/// the message is what the id goes into — passing the message would mean every transport knowing how
/// to number its own requests, which is a way for two of them to number them differently.
type Sender = async ((Int) -> Json, Int) -> Result[Json, String]

///|
/// `initialize`, `initialized`, then every page of `tools/list`.
///
/// Shared rather than written twice, because it is the same six decisions in both transports and a
/// second copy is a second thing to keep in step with the protocol. Notably it is *not* the
/// transport's business that a server may have no tools, or that the version it answers with is not
/// the one we asked for.
async fn mcp_open_session(
  send : Sender,
  notify : async (Json) -> Result[Unit, String],
) -> Result[Array[@core.McpTool], String] {
  let timeout = mcp_handshake_timeout_ms()
  match send(id => @core.mcp_initialize_request(id), timeout) {
    Err(reason) => return Err("the handshake failed: \{reason}")
    Ok(result) => {
      let handshake = @core.parse_initialize_result(result)
      guard handshake.protocol_version != "" else {
        return Err(
          "the server's `initialize` reply carried no `protocolVersion`",
        )
      }
      // The result is deliberately not checked against the version we asked for. A server that
      // answers with a different revision has still answered, and refusing over the string would
      // trade a working session for a formality; what matters is that it spoke the handshake.
      match notify(@core.mcp_initialized_notification()) {
        Err(reason) => return Err("could not finish the handshake: \{reason}")
        Ok(_) => ()
      }
      if handshake.has_tools {
        mcp_list_all_tools(send, timeout)
      } else {
        // A server that announced no `tools` capability is not asked to list any, so it is
        // reachable and has nothing — which the catalog renders as exactly that.
        Ok([])
      }
    }
  }
}

///|
/// Every page of `tools/list`.
///
/// Paged because the protocol pages it: a server with more tools than fit in one reply says so with
/// a cursor, and a client that stops at the first page silently reports a server as having fewer
/// tools than it does — which is the failure mode that looks like a working integration.
async fn mcp_list_all_tools(
  send : Sender,
  timeout : Int,
) -> Result[Array[@core.McpTool], String] {
  let tools : Array[@core.McpTool] = []
  let mut cursor = ""
  let mut failure : String? = None
  let mut more = true
  while more {
    match send(id => @core.mcp_list_tools_request(id, cursor), timeout) {
      Err(reason) => {
        failure = Some("`tools/list` failed: \{reason}")
        more = false
      }
      Ok(result) => {
        let (page, next) = @core.parse_tools_list(result)
        for tool in page {
          tools.push(tool)
        }
        match next {
          Some(next_cursor) => cursor = next_cursor
          None => more = false
        }
      }
    }
  }
  match failure {
    Some(reason) => Err(reason)
    None => Ok(tools)
  }
}

///|
/// The handshake, over this connection.
async fn McpStdio::open_session(
  self : McpStdio,
) -> Result[Array[@core.McpTool], String] {
  mcp_open_session(
    (build, timeout) => {
      let id = self.take_id()
      self.ask(id, build(id), timeout)
    },
    message => self.notify(message),
  )
}

// ── One exchange ───────────────────────────────────────────────────────────

///|
/// Call one of the server's tools.
///
/// The arguments are forwarded as the model gave them, with no validation here: the server's own
/// schema is the contract, and this client has no copy of it at the moment a call is made — which is
/// the cost of loading schemas on demand, and is why an invalid argument comes back as the server's
/// own error message rather than as a refusal invented here.
pub async fn McpStdio::call(
  self : McpStdio,
  tool : String,
  arguments : Json,
) -> @core.ToolOutput {
  // Refused before anything is written. A dead connection's next reply could belong to a request
  // that was timed out, so "this server is no longer usable" is the honest answer and the only one
  // a caller can act on.
  match self.dead {
    Some(reason) => return @core.ToolOutput::error(reason)
    None => ()
  }
  let id = self.take_id()
  match
    self.ask(
      id,
      @core.mcp_call_request(id, tool, arguments),
      mcp_call_timeout_ms(),
    ) {
    Err(reason) => @core.ToolOutput::error(reason)
    Ok(result) => @core.mcp_call_result(result)
  }
}

///|
/// Send a request and wait for the reply that carries its id.
async fn McpStdio::ask(
  self : McpStdio,
  id : Int,
  message : Json,
  timeout_ms : Int,
) -> Result[Json, String] {
  match self.send(message) {
    Err(reason) => Err(reason)
    Ok(_) =>
      match @async.with_timeout_opt(timeout_ms, () => self.await_reply(id)) {
        Some(result) => result
        // A server that never answers is the case this bound exists for, and the id is named
        // because a turn that hit several servers needs to know which one was quiet. The connection
        // is marked dead on the way out: the cancelled read cannot be resynchronized.
        None => {
          let reason = "`\{self.server.name}` did not answer within \{timeout_ms}ms and is no longer being used"
          self.dead = Some(reason)
          Err(reason)
        }
      }
  }
}

///|
/// Read lines until the reply to `id` arrives.
///
/// Lines that are not it are passed over rather than treated as an error: a server is entitled to
/// send notifications at any time, and one of them arriving between a request and its reply is
/// normal, not a failure. The only thing that ends the loop otherwise is the reader coming back
/// empty, which means the server exited — reported as such, since "the server closed its output" is
/// a different problem from "the server said no".
async fn McpStdio::await_reply(
  self : McpStdio,
  id : Int,
) -> Result[Json, String] {
  let mut answer : Result[Json, String]? = None
  while answer is None {
    let line = match self.reader.read_until("\n") {
      Some(line) => line
      None => {
        let reason = "`\{self.server.name}` closed its output"
        self.dead = Some(reason)
        answer = Some(Err(reason))
        continue
      }
    }
    match @core.parse_mcp_message(line) {
      @core.Reply(id=rpc_id, result~, error~) =>
        if rpc_id == id {
          answer = Some(
            match (result, error) {
              // The server's own wording, because that is the part the model can act on.
              (Some(result), _) => Ok(result)
              (_, Some(err)) => Err(err.message)
              (None, None) => Err("the server sent a reply with no result")
            },
          )
        }
      // Anything else is passed over. A notification is the server talking on its own — most of
      // what they carry is `tools/list_changed` — and a line this client cannot read is not the
      // answer to anything. Failing the request over either would be worse than ignoring it.
      _ => ()
    }
  }
  answer.unwrap()
}

///|
/// Write one frame. A failure here means the pipe is gone, which is worth saying in those words:
/// the usual cause is a server that has already exited.
async fn McpStdio::send(
  self : McpStdio,
  message : Json,
) -> Result[Unit, String] {
  try Some(self.writer.write(@core.mcp_frame(message))) catch {
    _ =>
      Err(
        "`\{self.server.name}` is not accepting input — it has probably exited",
      )
  } noraise {
    _ => Ok(())
  }
}

///|
/// The same, for a notification. Kept separate because a notification's failure is not an error
/// anyone can act on: there is no reply that would have carried it.
async fn McpStdio::notify(
  self : McpStdio,
  message : Json,
) -> Result[Unit, String] {
  self.send(message)
}

///|
fn McpStdio::take_id(self : McpStdio) -> Int {
  let id = self.next_id
  self.next_id = id + 1
  id
}

///|
/// A live server reached over HTTP: what it is, what it has, and where to post.
pub struct McpHttp {
  priv server : @core.McpServer
  priv url : String
  /// The server's own headers, as configured. Credentials go here.
  priv headers : Array[(String, String)]
  /// What the server handed back in `initialize`, or empty before that. Every later request carries
  /// it — this is the whole of what makes a series of HTTP posts one *session* rather than a series
  /// of unrelated ones, and a server that requires it answers 400 without it.
  priv mut session_id : String
  priv mut next_id : Int
  /// The same record the stdio connection keeps, and it means the same thing: a server that closed
  /// the session, or that never answered, is not reused. An HTTP connection recovers better than a
  /// pipe does — there is no half-read stream to resynchronize — but a session the server has
  /// forgotten would answer 404 forever, so saying so once and stopping is still the honest answer.
  priv mut dead : String?
  /// The content type of the last response, so that `exchange` can tell the two answer shapes apart.
  ///
  /// Held rather than returned because `notify` posts too and wants neither — and reset on every
  /// post, so a stale type cannot decide how the *next* body is read.
  priv mut last_content_type : String
}

///|
pub fn McpHttp::server(self : McpHttp) -> @core.McpServer {
  self.server
}

///|
/// Nothing to end: the server owns the session, and an HTTP connection holds no local resource.
///
/// Kept as a method anyway, because the shell's `mcp_dispose` walks a list of sessions without
/// asking which transport each one is — and a `match` there would be the one place that knows.
pub fn McpHttp::close(self : McpHttp) -> Unit {
  ignore(self)
}

///|
/// Reach a server over HTTP and complete the handshake, or say why it could not be done.
async fn start_mcp_http(
  config : @core.McpHttpConfig,
) -> Result[McpHttp, String] {
  let self : McpHttp = {
    server: { name: config.name, description: config.description, tools: [], },
    url: config.url,
    headers: config.headers,
    session_id: "",
    next_id: 1,
    dead: None,
    last_content_type: "",
  }
  match self.open_session() {
    Ok(tools) => Ok({ ..self, server: { ..self.server, tools, }, })
    Err(reason) => Err(reason)
  }
}

///|
async fn McpHttp::open_session(
  self : McpHttp,
) -> Result[Array[@core.McpTool], String] {
  mcp_open_session(
    (build, timeout) => {
      let id = self.take_id()
      self.ask(id, build(id), timeout)
    },
    message => self.notify(message),
  )
}

///|
/// Call one of the server's tools.
pub async fn McpHttp::call(
  self : McpHttp,
  tool : String,
  arguments : Json,
) -> @core.ToolOutput {
  match self.dead {
    Some(reason) => return @core.ToolOutput::error(reason)
    None => ()
  }
  let id = self.take_id()
  match
    self.ask(
      id,
      @core.mcp_call_request(id, tool, arguments),
      mcp_call_timeout_ms(),
    ) {
    Err(reason) => @core.ToolOutput::error(reason)
    Ok(result) => @core.mcp_call_result(result)
  }
}

///|
/// Post one request and find the answer to it in what comes back.
async fn McpHttp::ask(
  self : McpHttp,
  id : Int,
  message : Json,
  timeout_ms : Int,
) -> Result[Json, String] {
  match @async.with_timeout_opt(timeout_ms, () => self.exchange(message, id)) {
    Some(result) => result
    None => {
      let reason = "`\{self.server.name}` did not answer within \{timeout_ms}ms and is no longer being used"
      self.dead = Some(reason)
      Err(reason)
    }
  }
}

///|
/// A notification: posted, and the answer ignored.
///
/// The transport answers a notification with `202 Accepted` and no body, so there is nothing to
/// find — but the *status* is still checked, because a server that rejected the notification is a
/// server the handshake did not actually finish with.
async fn McpHttp::notify(
  self : McpHttp,
  message : Json,
) -> Result[Unit, String] {
  match
    @async.with_timeout_opt(mcp_handshake_timeout_ms(), () => self.post(message)) {
    Some(Err(reason)) => Err(reason)
    Some(Ok(_)) => Ok(())
    None => Err("`\{self.server.name}` did not accept the notification in time")
  }
}

///|
/// Post one message, and pull the reply with `id` out of whatever came back.
async fn McpHttp::exchange(
  self : McpHttp,
  message : Json,
  id : Int,
) -> Result[Json, String] {
  match self.post(message) {
    Err(reason) => Err(reason)
    Ok(body) =>
      // The server may answer either way, and which one it chose is in the content type rather than
      // in the shape of the body — an SSE stream of one message is not JSON and would not parse.
      match self.last_content_type {
        content_type =>
          if @core.is_event_stream(content_type) {
            self.reply_in_stream(body, id)
          } else {
            self.reply_in_body(body, id)
          }
      }
  }
}

///|
/// The reply to `id` in a body that is one JSON-RPC message.
fn McpHttp::reply_in_body(
  self : McpHttp,
  body : String,
  id : Int,
) -> Result[Json, String] {
  match @core.parse_mcp_message(body) {
    @core.Reply(id=rpc_id, result~, error~) =>
      if rpc_id != id {
        Err(
          "`\{self.server.name}` answered request \{id} with a reply to \{rpc_id}",
        )
      } else {
        reply_result(self.server.name, result, error)
      }
    // A 200 that carries a notification or a body this client cannot read is not an answer at all,
    // so it is reported rather than retried or passed over: passing it over would hang.
    @core.Ignored(reason~) =>
      Err("`\{self.server.name}` answered with something unreadable: \{reason}")
    @core.Notification(rpc_method~, ..) =>
      Err(
        "`\{self.server.name}` answered with a `\{rpc_method}` notification instead of a reply",
      )
  }
}

///|
/// The reply to `id` in an event stream: the first message in it that is one.
fn McpHttp::reply_in_stream(
  self : McpHttp,
  body : String,
  id : Int,
) -> Result[Json, String] {
  // Events are separated by a blank line, and a stream may carry several — a progress notification
  // before the answer is the ordinary case, which is exactly why a server chose a stream.
  for block in body.split("\n\n") {
    for payload in @core.sse_data_lines(block.to_owned()) {
      match @core.parse_mcp_message(payload) {
        @core.Reply(id=rpc_id, result~, error~) =>
          if rpc_id == id {
            return reply_result(self.server.name, result, error)
          }
        // Anything else is passed over, the same rule the stdio reader follows: a notification is
        // the server talking on its own, and it is not the answer to anything.
        _ => ()
      }
    }
  }
  Err(
    "`\{self.server.name}` did not send a reply to request \{id} in its event stream",
  )
}

///|
/// Post one message, keeping the session id and the content type the reply carried.
///
/// The session id is read here rather than at the call sites because `initialize` is the request that
/// establishes it and it is *not* the only one that may return it: a server can hand a new id back at
/// any time, and a client that only looked once would keep sending a stale one.
async fn McpHttp::post(
  self : McpHttp,
  message : Json,
) -> Result[String, String] {
  match self.dead {
    Some(reason) => return Err(reason)
    None => ()
  }
  let headers : @http.Headers = Map([])
  for header in @core.mcp_http_headers(self.session_id) {
    let (name, value) = header
    headers.set(@http.CaseInsensitiveString(name), value)
  }
  for header in self.headers {
    let (name, value) = header
    headers.set(@http.CaseInsensitiveString(name), value)
  }
  let body = message.stringify()
  let posted : Result[(@http.Response, &@io.Data), String] = try
    Ok(@http.post(self.url, body, headers~))
  catch {
    err => Err("could not reach `\{self.url}`: \{err}")
  } noraise {
    result => result
  }
  let (response, data) = match posted {
    Err(reason) => {
      // A refused TCP connection is the same kind of fact as a server that closed a stream: nothing
      // about the *session* was learned, so the session is retired rather than retried on the next
      // call with the same result.
      self.dead = Some(reason)
      return Err(reason)
    }
    Ok(pair) => pair
  }
  let response_headers : Array[(String, String)] = []
  for name, value in response.headers {
    response_headers.push((name.to_string(), value))
  }
  match @core.mcp_session_id_from_headers(response_headers) {
    Some(id) => self.session_id = id
    None => ()
  }
  self.last_content_type = match
    response.headers.get(@http.CaseInsensitiveString("Content-Type")) {
    Some(value) => value
    None => ""
  }
  let text = @utf8.decode_lossy(data.binary())
  if response.code >= 200 && response.code < 300 {
    Ok(text)
  } else {
    // A 404 with a session id is the one failure worth naming precisely: the protocol says it means
    // the session is gone, and a reader who sees it knows to restart the server rather than to check
    // their credentials.
    let reason = if response.code == 404 && self.session_id != "" {
      "`\{self.server.name}` no longer knows this session (HTTP 404) — restart it"
    } else {
      "`\{self.server.name}` answered HTTP \{response.code}: \{clip(text)}"
    }
    self.dead = Some(reason)
    Err(reason)
  }
}

///|
fn McpHttp::take_id(self : McpHttp) -> Int {
  let id = self.next_id
  self.next_id = id + 1
  id
}

///|
/// A reply's result, or the server's own wording for why there is none.
fn reply_result(
  name : String,
  result : Json?,
  error : @core.McpError?,
) -> Result[Json, String] {
  match (result, error) {
    // The server's own wording, because that is the part the model can act on.
    (Some(result), _) => Ok(result)
    (_, Some(err)) => Err(err.message)
    (None, None) => Err("`\{name}` sent a reply with no result")
  }
}

///|
/// An error body is prose from another service and can be a page of HTML. Clipped so that a failed
/// connection reports a reason instead of filling the transcript with somebody's error page.
fn clip(text : String) -> String {
  let limit = 300
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned() + "…"
  }
}

// ── The session, whichever transport it is on ─────────────────────────────

///|
/// A server this process can reach, on either transport.
///
/// The shell holds these rather than the transport-specific values, and the reason is that the three
/// things it does with one — read its catalog, call a tool, close it — are the same for both. A
/// `match` in the shell would be the one place that knew about transports, and it would have to be
/// written three times.
pub(all) enum McpSession {
  Stdio(McpStdio)
  Http(McpHttp)
}

///|
pub fn McpSession::server(self : McpSession) -> @core.McpServer {
  match self {
    Stdio(connection) => connection.server()
    Http(connection) => connection.server()
  }
}

///|
pub fn McpSession::close(self : McpSession) -> Unit {
  match self {
    Stdio(connection) => connection.close()
    Http(connection) => connection.close()
  }
}

///|
pub async fn McpSession::call(
  self : McpSession,
  tool : String,
  arguments : Json,
) -> @core.ToolOutput {
  match self {
    Stdio(connection) => connection.call(tool, arguments)
    Http(connection) => connection.call(tool, arguments)
  }
}

///|
/// Bring one server up, whichever transport its config names.
///
/// Public because it is the one entry point a caller needs: a caller with a single config should not
/// have to go through `connect_mcp_servers` and its pair of arrays to start one server.
pub async fn[X] start_mcp_session(
  group : @async.TaskGroup[X],
  config : @core.McpConfig,
  cwd : String,
) -> Result[McpSession, String] {
  match config {
    Stdio(config) =>
      match start_mcp_stdio(group, config, cwd) {
        Ok(connection) => Ok(Stdio(connection))
        Err(reason) => Err(reason)
      }
    Http(config) =>
      match start_mcp_http(config) {
        Ok(connection) => Ok(Http(connection))
        Err(reason) => Err(reason)
      }
  }
}

///|
/// Start every configured server, keeping the ones that worked and the reasons the others did not.
///
/// Sequential rather than concurrent. Servers are started when a session opens, so the cost is one
/// startup latency once, and a batch started at once would make a failure that much harder to
/// attribute to the server that caused it.
pub async fn[X] connect_mcp_servers(
  group : @async.TaskGroup[X],
  configs : Array[@core.McpConfig],
  cwd : String,
) -> (Array[McpSession], Array[(String, String)]) {
  let connected : Array[McpSession] = []
  let failed : Array[(String, String)] = []
  for config in configs {
    let name = match config {
      @core.Stdio(config) => config.name
      @core.Http(config) => config.name
    }
    match start_mcp_session(group, config, cwd) {
      Ok(session) => connected.push(session)
      Err(reason) => failed.push((name, reason))
    }
  }
  (connected, failed)
}

///|
/// The catalogs of the servers that came up.
///
/// **A server that is not connected is not in the catalog.** That is the whole discipline: the
/// catalog is the model's map of what it can reach, so a name in it that no connection answers to
/// sends the model to a refusal. What failed is reported to the reader instead, where something can
/// be done about it.
pub fn mcp_catalogs(sessions : Array[McpSession]) -> Array[@core.McpServer] {
  let out : Array[@core.McpServer] = []
  for session in sessions {
    out.push(session.server())
  }
  out
}

///|
/// The session a call names, out of the ones that are up.
pub fn mcp_connection_named(
  sessions : Array[McpSession],
  name : String,
) -> McpSession? {
  for session in sessions {
    if session.server().name == name {
      return Some(session)
    }
  }
  None
}

///|
/// What a call to the `mcp` tool does.
///
/// This is the gateway's whole body: route the call to a session, or answer with what there is. The
/// two refusals are `core/mcp.mbt`'s, not invented here, because they are prompt text — a refusal is
/// read by the model, and where it comes from is where it should be tested.
///
/// Nothing here can fail in a way that ends a turn. A server's tool that errors comes back as an
/// error result, the same as a built-in tool's failure does, and the model is told what went wrong
/// instead of the turn dying with it. That is the same rule `agent/driver.mbt` applies to every
/// other tool, and it matters more here: this reaches code another process chose.
pub async fn call_mcp(
  sessions : Array[McpSession],
  arguments : Json,
) -> @core.ToolOutput {
  let catalogs = mcp_catalogs(sessions)
  match @core.parse_mcp_call(arguments) {
    @core.Invalid(reason~) =>
      @core.ToolOutput::error(@core.mcp_invalid_message(reason, catalogs))
    @core.Describe(server~) =>
      match mcp_connection_named(sessions, server) {
        // A server the catalog does not list: said with the list, so the model's next call can be
        // one that works.
        None =>
          @core.ToolOutput::error(
            @core.mcp_unknown_server_message(server, catalogs),
          )
        Some(session) =>
          @core.ToolOutput::text(@core.mcp_describe_message(session.server()))
      }
    @core.Invoke(server~, tool~, arguments~) =>
      match mcp_connection_named(sessions, server) {
        None =>
          @core.ToolOutput::error(
            @core.mcp_unknown_server_message(server, catalogs),
          )
        Some(session) => {
          let known = session.server()
          // A tool the server does not have is refused *before* the call goes out. The server would
          // answer the same thing, in its own words, but the list of what it does have is something
          // only this side can add — and that list is what turns a wrong name into a working call.
          let mut found = false
          for candidate in known.tools {
            if candidate.name == tool {
              found = true
            }
          }
          if !found {
            @core.ToolOutput::error(@core.mcp_unknown_tool_message(known, tool))
          } else {
            session.call(tool, arguments)
          }
        }
      }
  }
}

///|
/// The tool set a turn is given, with the gateway appended when servers are up.
///
/// A thin passthrough to `core/mcp.mbt` so a caller does not have to reach into two packages to
/// build one request: the tool set and the catalog are the same decision, and this is where the
/// platform's sessions become the core's value.
pub fn tools_with_mcp(
  tools : Array[@core.ToolDef],
  sessions : Array[McpSession],
) -> Array[@core.ToolDef] {
  @core.with_mcp_tools(tools, mcp_catalogs(sessions))
}
