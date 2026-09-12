///|
/// The driver, end to end, against a scripted model.
///
/// What is being tested is the sequencing: which request goes out, in what order,
/// what gets written to the log, and what a stop does. None of that needs a
/// provider — it needs a server that answers with a chosen response and remembers
/// what it was asked.
///
/// Scripted responses over a real socket rather than an injected callback: going
/// through the transport means the request encoding, the SSE reader and the parser
/// are all exercised rather than bypassed, and it is the only way to assert on what
/// the model was actually sent.
///
/// Scratch directories live under `_build`, which the build already ignores.

///|
const FIXED_TIME : Int64 = 1700000000000L

///|
/// A port nothing is listening on, for the fake model to take.
async fn fake_model_port() -> Int {
  let probe = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = probe.addr.port()
  probe.close()
  port
}

///|
/// Answer requests in order, repeating the last scripted response, and record every
/// request body.
async fn serve_scripted(
  port : Int,
  responses : Array[String],
  seen : Array[String],
  delay_ms : Int,
) -> Unit {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:\{port}"))
  let mut index = 0
  while true {
    let (tcp, _) = server.accept()
    let headers = match tcp.read_until("\r\n\r\n") {
      Some(text) => text
      None => ""
    }
    let body = read_request_body(tcp, headers)
    seen.push(body)
    if delay_ms > 0 {
      @async.sleep(delay_ms)
    }
    let reply = responses[if index < responses.length() {
        index
      } else {
        responses.length() - 1
      }]
    index += 1
    tcp.write(sse_response(reply))
    tcp.close()
  }
}

///|
fn sse_response(body : String) -> String {
  "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \{body.length()}\r\nConnection: close\r\n\r\n" +
  body
}

///|
/// Read the body of a request.
///
/// The async http client sends a request body with `Transfer-Encoding: chunked`
/// unless the caller supplies a `Content-Length`, so a server that only looks for a
/// length answers before the body arrives — and then the connection it closes is
/// one the client is still writing to.
async fn read_request_body(tcp : @socket.Tcp, headers : String) -> String {
  match content_length(headers) {
    Some(length) => @utf8.decode_lossy(tcp.read_exactly(length))
    None =>
      if headers.to_lower().contains("transfer-encoding: chunked") {
        read_chunked(tcp)
      } else {
        ""
      }
  }
}

///|
/// Read a chunked body: a hex length, that many bytes, a CRLF, repeated, ended by a
/// zero-length chunk.
async fn read_chunked(tcp : @socket.Tcp) -> String {
  let out = StringBuilder()
  while true {
    let size = match tcp.read_until("\r\n") {
      Some(line) => hex_prefix(line)
      None => 0
    }
    if size <= 0 {
      break
    }
    out.write_string(@utf8.decode_lossy(tcp.read_exactly(size)))
    // The CRLF after the data is framing, not content.
    ignore(tcp.read_until("\r\n"))
  }
  out.to_string()
}

///|
fn hex_prefix(line : String) -> Int {
  let mut value = 0
  for c in line {
    let digit = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      break
    }
    value = value * 16 + digit
  }
  value
}

///|
/// The `Content-Length` of a request, or `None` when it is absent.
fn content_length(headers : String) -> Int? {
  for raw in headers.split("\r\n") {
    let line = raw.to_lower()
    if line.has_prefix("content-length:") {
      let value = line[15:]
      let mut length = 0
      for c in value {
        if c >= '0' && c <= '9' {
          length = length * 10 + (c.to_int() - '0'.to_int())
        } else {
          break
        }
      }
      return Some(length)
    }
  }
  None
}

///|
/// Run `body` with a scripted model listening on `localhost`.
async fn with_fake_model(
  responses : Array[String],
  seen : Array[String],
  body : async (String) -> Unit,
  delay_ms? : Int = 0,
) -> Unit {
  let port = fake_model_port()
  @async.with_task_group(group => {
    // `no_wait`: the accept loop only ends when it is cancelled, so a group that
    // waited for it would never finish the test.
    ignore(
      group.spawn(
        () => serve_scripted(port, responses, seen, delay_ms),
        no_wait=true,
      ),
    )
    @async.sleep(30)
    body("http://127.0.0.1:\{port}")
  })
}

///|
async fn scratch(name : String) -> String {
  let dir = "_build/agent_test/\{name}-\{@core.new_entry_id()}"
  @platform.make_dirs(dir)
  dir
}

///|
/// One chunk of SSE carrying a `read` tool call for `path`.
fn read_tool_call_sse(path : String) -> String {
  "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"" +
  path +
  "\\\"}\"}}]},\"finish_reason\":null}]}\n\ndata: {\"id\":\"c1\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\ndata: [DONE]\n\n"
}

///|
/// One chunk of SSE carrying a `bash` tool call.
fn bash_tool_call_sse(command : String) -> String {
  "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"" +
  command +
  "\\\"}\"}}]},\"finish_reason\":null}]}\n\ndata: {\"id\":\"c1\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\ndata: [DONE]\n\n"
}

///|
/// One chunk of SSE carrying a text reply and a clean stop.
fn text_sse(text : String) -> String {
  "data: {\"id\":\"c2\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"" +
  text +
  "\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"c2\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":3,\"total_tokens\":23}}\n\ndata: [DONE]\n\n"
}

///|
/// Context for a turn against the fake model, with the log already on disk.
async fn context_for(
  dir : String,
  base_url : String,
  entries : Array[@core.Entry],
  window? : Int,
) -> @agent.AgentContext {
  let path = "\{dir}/session.jsonl"
  let header : @core.SessionHeader = {
    id: "test",
    timestamp: @core.format_iso_utc(FIXED_TIME),
    cwd: dir,
    parent_session: None,
    version: Some(3),
  }
  @platform.create_session(path, header)
  @platform.append_entries(path, entries)
  let tools = @core.builtin_tools()
  @agent.AgentContext::new(
    session=@core.Session::new(header, entries),
    session_path=path,
    cwd=dir,
    api_key="fixture-key",
    system_prompt=@core.build_system_prompt(dir, tools),
    tools~,
    base_url~,
    context_window=window.unwrap_or(@core.deepseek_v4_flash_context_window()),
  )
}

///|
/// The entries in the log on disk, parsed back.
async fn logged(path : String) -> @core.Session {
  @core.parse_session_file(@platform.read_text(path))
}

///|
/// A turn that uses a tool: the model asks, the tool runs, the result goes back, and
/// the answer that follows is the one the user sees.
///
/// The assertions cover the three places a mistake would hide: how many calls were
/// made, what the tool actually produced, and what the log says afterwards —
/// including that the log is a chain rather than a set of entries sharing a file.
async test "a turn runs a tool and writes the log" {
  let dir = scratch("tool")
  @platform.write_text("\{dir}/note.txt", "hello-from-tool\n")
  let seen : Array[String] = []
  with_fake_model([read_tool_call_sse("note.txt"), text_sse("done")], seen, async fn(
    base_url,
  ) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "read the note",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_eq(result.model_calls, 2)
    assert_eq(result.tool_calls, 1)
    assert_eq(result.compactions, 0)
    assert_eq(result.replies, ["done"])
    assert_true(result.usage.total_tokens > 0)

    // The model was told what the tool produced, in the second request.
    assert_eq(seen.length(), 2)
    assert_true(seen[1].contains("hello-from-tool"), msg=seen[1])

    let session = logged(ctx.session_path)
    let kinds : Array[String] = []
    for entry in session.entries {
      match entry.kind {
        @core.Message(message~) =>
          match message {
            @core.User(_) => kinds.push("user")
            @core.Assistant(_) => kinds.push("assistant")
            @core.ToolResult(_) => kinds.push("toolResult")
          }
        @core.ModelChange(..) => kinds.push("model")
        @core.ThinkingLevelChange(..) => kinds.push("thinking")
        _ => kinds.push("other")
      }
    }
    assert_eq(kinds, [
      "model", "thinking", "user", "assistant", "toolResult", "assistant",
    ])
    // A chain, not a pile: every entry points at the one before it.
    for i in 1..<session.entries.length() {
      assert_eq(
        session.entries[i].parent_id,
        Some(session.entries[i - 1].id),
        msg="entry \{i} does not follow the previous one",
      )
    }
  })
}

///|
/// A stream the caller stops reading is recorded as aborted, not as a failure.
///
/// The distinction is what a resumed session depends on: an `error` assistant
/// message reads as a broken connection and invites retrying work the user
/// deliberately cancelled. pi writes `aborted`, and this is the one place the
/// driver can know it — the stop is decided by the caller, mid-stream.
async test "a stopped stream is logged as aborted" {
  let dir = scratch("abort")
  let partial = "data: {\"id\":\"c3\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"half a thought\"},\"finish_reason\":null}]}\n\n"
  let seen : Array[String] = []
  with_fake_model([partial], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let mut stop = false
    let result = @agent.run_turn(
      ctx,
      "start something long",
      FIXED_TIME,
      thinking_level="high",
      // Stop as soon as the first token arrives, which is what the abort button
      // does from the other side of the socket.
      on_delta=fn(_event) { stop = true },
      should_stop=() => stop,
    )
    assert_eq(result.model_calls, 1)
    let session = logged(ctx.session_path)
    let last = session.entries[session.entries.length() - 1]
    match last.kind {
      @core.Message(message~) =>
        match message {
          @core.Assistant(assistant) => {
            assert_eq(assistant.stop_reason, @core.Aborted)
            assert_eq(assistant.error_message, Some("Operation aborted"))
            match assistant.content[0] {
              @core.Text(text) => assert_eq(text, "half a thought")
              _ => fail("expected the partial text to survive")
            }
          }
          _ => fail("expected the last entry to be the assistant's")
        }
      _ => fail("expected the last entry to be a message")
    }
  })
}

///|
/// A conversation that has outgrown the window is summarized before the next call,
/// and the summary is what the following request carries.
///
/// This is the whole compaction path in one test: the decision (`should_compact`),
/// the cut, the extra model call, the entry that records it, and — the part that
/// would be easiest to get wrong — the framing the next request uses. A summary
/// replayed without pi's `<summary>` wrapper is a summary the model cannot tell
/// apart from something the user said.
async test "a long conversation is compacted before the next call" {
  let dir = scratch("compact")
  // Enough text to cross the threshold for a small window, in messages big enough
  // that some of them fall before the cut.
  // ~10.8k tokens per message, so three of them clear the threshold for the 40k
  // window below and still leave something on both sides of the cut.
  let paragraph = "lorem ipsum dolor sit amet consectetur adipiscing elit ".repeat(
    800,
  )
  let entries : Array[@core.Entry] = []
  let mut parent : String? = None
  for i in 0..<3 {
    let id = @core.new_entry_id()
    entries.push({
      id,
      parent_id: parent,
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("\{paragraph} part \{i}")],
          timestamp: FIXED_TIME,
        }),
      ),
    })
    parent = Some(id)
  }
  let seen : Array[String] = []
  with_fake_model(
    [text_sse("a summary of the old work"), text_sse("carrying on")],
    seen,
    async fn(base_url) {
      // A 40k window puts the threshold at ~23.6k tokens; the log above is larger.
      let ctx = context_for(dir, base_url, entries, window=40000)
      let result = @agent.run_turn(
        ctx,
        "continue",
        FIXED_TIME,
        thinking_level="high",
      )
      assert_eq(result.compactions, 1)
      // Two calls beyond the summarization itself: the summary, then the reply.
      assert_eq(seen.length(), 2)
      // The first request asks the model to summarize.
      assert_true(seen[0].contains("summarize"), msg=seen[0])
      assert_true(seen[0].contains("## Goal"), msg=seen[0])
      // The second carries the summary as framed user text.
      assert_true(
        seen[1].contains(
          "The conversation history before this point was compacted into the following summary:",
        ),
        msg=seen[1],
      )
      assert_true(seen[1].contains("a summary of the old work"), msg=seen[1])

      let session = logged(ctx.session_path)
      let mut compactions = 0
      for entry in session.entries {
        if entry.kind is @core.Compaction(summary~, ..) {
          compactions += 1
          assert_true(
            summary.contains("a summary of the old work"),
            msg=summary,
          )
        }
      }
      assert_eq(compactions, 1)
      // The derived context starts at the summary, which is what makes the
      // compaction take effect for everything that follows.
      let messages = result.session.context().messages
      assert_true(messages[0] is @core.CompactionSummary(_))
      assert_true(messages.length() > 1)
    },
  )
}

///|
/// A turn that never stops asking for tools ends, and says so.
///
/// The bound has to be reported rather than raised: this runs inside a server, and a
/// model that loops must not be able to take the process — and with it every other
/// conversation — down.
async test "a model that never settles is stopped by the round limit" {
  let dir = scratch("rounds")
  @platform.write_text("\{dir}/note.txt", "again\n")
  let seen : Array[String] = []
  with_fake_model([read_tool_call_sse("note.txt")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "loop forever",
      FIXED_TIME,
      thinking_level="high",
      max_rounds=3,
    )
    assert_false(result.settled)
    assert_eq(result.model_calls, 3)
    assert_eq(result.tool_calls, 3)
    // The log stays balanced: the last thing written is the result of the last tool
    // call, so a resumed session does not need repairing.
    assert_false(result.session.needs_repair())
  })
}

///|
/// Every entry carries the time it happened, not the time the turn started.
///
/// A turn spends its time between entries — in the model, in the tools — and a log where
/// forty entries share one timestamp cannot be read back to see where the minutes went.
/// The fake model is slowed down here because a fast one would make the two times equal
/// by accident.
async test "entries are timestamped when they happen" {
  let dir = scratch("times")
  @platform.write_text("\{dir}/note.txt", "hello\n")
  let seen : Array[String] = []
  with_fake_model(
    [read_tool_call_sse("note.txt"), text_sse("done")],
    seen,
    async fn(base_url) {
      let ctx = context_for(dir, base_url, [])
      let result = @agent.run_turn(
        ctx,
        "read it",
        FIXED_TIME,
        thinking_level="high",
      )
      let session = logged(ctx.session_path)
      let mut asked : Int64 = 0
      let mut answered : Int64 = 0
      let mut tooled : Int64 = 0
      for entry in session.entries {
        match entry.kind {
          @core.Message(message~) =>
            match message {
              @core.User(_) =>
                asked = @core.parse_iso_utc(entry.timestamp).unwrap()
              @core.ToolResult(_) =>
                tooled = @core.parse_iso_utc(entry.timestamp).unwrap()
              @core.Assistant(_) =>
                answered = @core.parse_iso_utc(entry.timestamp).unwrap()
            }
          _ => ()
        }
      }
      // The model was made to take ~30ms per response, so "different" is measurable
      // rather than lucky.
      assert_true(
        answered > asked,
        msg="assistant \{answered} vs user \{asked}",
      )
      assert_true(tooled > 0L)
      assert_eq(result.tool_calls, 1)
    },
    delay_ms=30,
  )
}

///|
/// A turn reports each tool as it finishes, and its counts as they grow.
///
/// This is what a page renders to look alive during a long turn, so the events and the
/// progress numbers are part of the driver's contract rather than a detail of the UI.
async test "tools and progress are reported as the turn runs" {
  let dir = scratch("live")
  @platform.write_text("\{dir}/note.txt", "live-output\n")
  let seen : Array[String] = []
  let events : Array[(String, String, Bool)] = []
  let progress : Array[(Int, Int)] = []
  with_fake_model(
    [
      read_tool_call_sse("note.txt"),
      read_tool_call_sse("missing.txt"),
      text_sse("done"),
    ],
    seen,
    async fn(base_url) {
      let ctx = context_for(dir, base_url, [])
      let result = @agent.run_turn(
        ctx,
        "read two files",
        FIXED_TIME,
        thinking_level="high",
        on_tool=event => events.push((event.name, event.output, event.is_error)),
        on_progress=(calls, tools) => progress.push((calls, tools)),
      )
      assert_eq(result.model_calls, 3)
      assert_eq(events.length(), 2)
      let (first_name, first_output, first_error) = events[0]
      assert_eq(first_name, "read")
      assert_true(first_output.contains("live-output"), msg=first_output)
      assert_false(first_error)
      // A tool that fails is reported as failing, not left out.
      let (_, _, second_error) = events[1]
      assert_true(second_error)
      // The counts grow, and the last report is the finished turn's.
      assert_true(progress.length() >= 2, msg="\{progress.length()} reports")
      assert_eq(progress[progress.length() - 1], (3, 2))
    },
  )
}

///|
/// Stopping a turn reaches the command that is running.
///
/// The abort flag alone would not: it is checked between steps, and the step in progress *is*
/// the command. Without cancelling the tool, a `sleep 30` would keep the turn — and the
/// session's turn slot — busy for its full duration after the reader asked it to stop.
async test "stopping a turn kills the tool that is running" {
  let dir = scratch("stop-tool")
  let seen : Array[String] = []
  with_fake_model([bash_tool_call_sse("sleep 30")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let mut stop = false
    let mut handle : @agent.ToolHandle? = None
    let started = @env.now()
    let result = @async.with_task_group(group => {
      ignore(
        group.spawn(
          () => {
            // Wait for the command to be running, then stop it the way the button does.
            while handle is None {
              @async.sleep(10)
            }
            @async.sleep(200)
            stop = true
            match handle {
              Some(running) => (running.stop)()
              None => ()
            }
          },
          no_wait=true,
        ),
      )
      @agent.run_turn(
        ctx,
        "run something long",
        FIXED_TIME,
        thinking_level="high",
        should_stop=() => stop,
        on_tool_process=published => handle = published,
      )
    })
    let elapsed = (@env.now() - started).reinterpret_as_int64()
    // `sleep 30` minus the kill: the assertion is that the stop was quick, not that it was
    // recorded.
    assert_true(elapsed < 5000L, msg="took \{elapsed}ms")
    assert_eq(result.tool_calls, 1)
    // The model is told the command was stopped, rather than the turn dying.
    let session = logged(ctx.session_path)
    let mut told = ""
    let mut is_error = false
    for entry in session.entries {
      match entry.kind {
        @core.Message(message~) =>
          match message {
            @core.ToolResult(result) => {
              is_error = result.is_error
              for block in result.content {
                match block {
                  @core.Text(text) => told = told + text
                  _ => ()
                }
              }
            }
            _ => ()
          }
        _ => ()
      }
    }
    assert_true(told.contains("stopped"), msg=told)
    assert_true(is_error)
  })
}

///|
/// A command that returns while its work continues becomes a job.
///
/// This is the case the whole job layer exists for: the tool call is over, the turn is over, and
/// something is still running. Without a record it is a process nobody is looking at — the thing
/// that gets forgotten.
async test "a backgrounded command is recorded as a job" {
  let dir = scratch("bg-job")
  let seen : Array[String] = []
  with_fake_model(
    [bash_tool_call_sse("/bin/sleep 60 & echo started"), text_sse("ok")],
    seen,
    async fn(base_url) {
      let ctx = context_for(dir, base_url, [])
      let result = @agent.run_turn(
        ctx,
        "start something",
        FIXED_TIME,
        thinking_level="high",
      )
      assert_eq(result.tool_calls, 1)
      let live = ctx.jobs.live()
      assert_eq(
        live.length(),
        1,
        msg="expected one live job, saw \{live.length()}",
      )
      let job = live[0]
      assert_eq(job.kind, "bash")
      assert_eq(job.session, ctx.session_path)
      assert_true(job.label.contains("sleep 60"), msg=job.label)
      assert_true(
        job.pids.length() >= 1,
        msg="a job without pids cannot be stopped",
      )
      // The model is told, in the tool result, that something was left running.
      let session = logged(ctx.session_path)
      let mut told = ""
      for entry in session.entries {
        match entry.kind {
          @core.Message(message~) =>
            match message {
              @core.ToolResult(result) =>
                for block in result.content {
                  match block {
                    @core.Text(text) => told = told + text
                    _ => ()
                  }
                }
              _ => ()
            }
          _ => ()
        }
      }
      assert_true(told.contains("left 1 process"), msg=told)

      // Stopping it through the store is what the sidebar's Kill button does.
      let pids = ctx.jobs.request_stop(job.id)
      assert_true(@platform.kill_pids(pids) >= 1)
      ctx.jobs.finish(job.id, Killed, detail="killed", finished_at=FIXED_TIME)
      assert_true(ctx.jobs.live().is_empty())
      for pid in pids {
        assert_false(@platform.pid_alive(pid), msg="pid \{pid} should be gone")
      }
    },
  )
}

///|
/// A foreground command leaves no job behind: the panel is for what is still running.
async test "a foreground command leaves no job record" {
  let dir = scratch("fg-job")
  let seen : Array[String] = []
  with_fake_model(
    [bash_tool_call_sse("/bin/echo hello"), text_sse("ok")],
    seen,
    async fn(base_url) {
      let ctx = context_for(dir, base_url, [])
      ignore(
        @agent.run_turn(ctx, "say hello", FIXED_TIME, thinking_level="high"),
      )
      assert_true(
        ctx.jobs.list().is_empty(),
        msg="\{ctx.jobs.list().length()} records",
      )
    },
  )
}

///|
/// The per-session limit dsh sets at ten: past it, the command is refused rather than started.
async test "a session past the background limit is told to clean up" {
  let dir = scratch("bg-limit")
  let seen : Array[String] = []
  with_fake_model(
    [bash_tool_call_sse("/bin/echo should-not-run"), text_sse("ok")],
    seen,
    async fn(base_url) {
      let ctx = context_for(dir, base_url, [])
      // Fill the budget with jobs that stand in for running processes.
      for i in 0..<@core.max_live_jobs_per_session() {
        ignore(
          ctx.jobs.start(
            kind="bash",
            label="standing job \{i}",
            session=ctx.session_path,
            started_at=FIXED_TIME,
            pids=[],
          ),
        )
      }
      let result = @agent.run_turn(
        ctx,
        "run it",
        FIXED_TIME,
        thinking_level="high",
      )
      assert_eq(result.tool_calls, 0)
      let session = logged(ctx.session_path)
      let mut said = ""
      for entry in session.entries {
        match entry.kind {
          @core.Message(message~) =>
            match message {
              @core.ToolResult(result) => {
                assert_true(result.is_error)
                for block in result.content {
                  match block {
                    @core.Text(text) => said = said + text
                    _ => ()
                  }
                }
              }
              _ => ()
            }
          _ => ()
        }
      }
      assert_true(said.contains("Refused"), msg=said)
      // Nothing was started, so the budget is unchanged.
      assert_eq(
        ctx.jobs.live_count(ctx.session_path),
        @core.max_live_jobs_per_session(),
      )
    },
  )
}
