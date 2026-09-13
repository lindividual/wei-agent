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
/// Answer requests in order, repeating the last scripted response, and record every
/// request body.
///
/// Takes the bound listener rather than a port number: see `with_fake_model`.
async fn serve_scripted(
  server : @socket.TcpServer,
  responses : Array[String],
  seen : Array[String],
  delay_ms : Int,
) -> Unit {
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
///
/// The listener is created here rather than a port being probed and released. Probing hands back
/// a port that nothing holds, and another test in this binary can be given the same number in the
/// gap between the probe's close and the real bind — which showed up as an "Address already in
/// use" failure in roughly one full run in four. Binding once and handing the port to the script
/// keeps the socket ours from the first instruction, and a `0` port asks the kernel for one that
/// is free at bind time rather than at probe time.
async fn with_fake_model(
  responses : Array[String],
  seen : Array[String],
  body : async (String) -> Unit,
  delay_ms? : Int = 0,
) -> Unit {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group(group => {
    // `no_wait`: the accept loop only ends when it is cancelled, so a group that
    // waited for it would never finish the test.
    ignore(
      group.spawn(
        () => serve_scripted(server, responses, seen, delay_ms),
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
      "model", "thinking", "user", "other", "assistant", "toolResult", "assistant",
      "other",
    ])
    // The two `other` entries are the turn's bookkeeping: it opens before any work happens and
    // records how it ended. Neither is conversation — the model is never sent them — which is why
    // the message sequence around them is exactly what it was before either existed.
    let customs : Array[String] = []
    for entry in session.entries {
      match entry.kind {
        @core.Custom(custom_type~, ..) => customs.push(custom_type)
        _ => ()
      }
    }
    assert_eq(customs, [@core.turn_start_type(), @core.turn_outcome_type()])
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
/// A tool that throws is reported to the model, and the turn continues.
///
/// The concrete failure is a `read` of a file that is not UTF-8: a binary reached by mistake is
/// an ordinary event, and the model needs to be told it so it can pick another file. The driver
/// re-raised anything that was not a cancellation, so this used to end the whole turn — the
/// reader got an error and no reply at all. What is asserted here is the shape that matters:
/// the turn reaches its second model call and produces the reply, and the tool result it sent
/// says the file was not text.
async test "a tool that fails does not end the turn" {
  let dir = scratch("tool-failure")
  let raw : FixedArray[Byte] = [b'\xff', b'\xfe', b'\x00', b'\x80']
  @fs.write_file("\{dir}/blob.bin", Bytes::from_array(raw))
  let seen : Array[String] = []
  with_fake_model(
    [read_tool_call_sse("blob.bin"), text_sse("sorry about that")],
    seen,
    async fn(base_url) {
      let ctx = context_for(dir, base_url, [])
      let result = @agent.run_turn(
        ctx,
        "read the blob",
        FIXED_TIME,
        thinking_level="high",
      )
      // Two calls: the model got an answer to its tool call and finished.
      assert_eq(result.model_calls, 2)
      assert_eq(result.tool_calls, 1)
      assert_eq(result.replies, ["sorry about that"])
      // And the answer it got said the file is not text, rather than that the turn broke.
      assert_eq(seen.length(), 2)
      assert_true(seen[1].contains("not UTF-8 text"), msg=seen[1])
    },
  )
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
    // The turn was stopped by the reader, so the log carries that record after the message: a
    // conversation that just ends reads the same whether the model finished or someone pulled the
    // plug, and the next reader of this file is the one who has to tell them apart.
    assert_eq(session.last_turn_ending(), Some(@core.Stopped))
    let last_message = {
      let mut found : @core.EntryKind? = None
      for entry in session.entries {
        if entry.kind is @core.Message(_) {
          found = Some(entry.kind)
        }
      }
      found.unwrap()
    }
    match last_message {
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
          _ => fail("expected the last message to be the assistant's")
        }
      _ => fail("expected a message")
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

///|
/// A turn that spends past the cost limit is stopped, and says it was the cost that did it.
///
/// The round limit does not bound the bill: a handful of large requests can cost more than a
/// hundred small ones, so a turn can be cheap in calls and expensive in dollars. This is the
/// guard that actually bounds spending, and it is checked before the next request rather than
/// after it, so nothing is bought that the limit was meant to prevent.
///
/// The limit is tiny here on purpose, so the test does not need hundreds of scripted responses
/// to cross it. Each scripted reply bills 10 prompt and 5 completion tokens, which at this
/// model's prices is about $0.000003, so a limit of $0.00001 is reached in a few calls. The
/// scripted replies never stop asking for tools, which is what a runaway model looks like.
async test "the cost limit stops a turn and reports itself" {
  let dir = scratch("cost-limit")
  @platform.write_text("\{dir}/note.txt", "again\n")
  let seen : Array[String] = []
  with_fake_model([read_tool_call_sse("note.txt")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "spend money",
      FIXED_TIME,
      thinking_level="high",
      max_rounds=1000,
      max_cost=0.00001,
    )
    assert_true(result.cost_limit_hit, msg="the cost limit did not fire")
    assert_false(result.settled)
    // It stopped well short of the round limit, which is the point of having two limits.
    assert_true(result.model_calls >= 1 && result.model_calls < 20)
    // And it stopped having actually spent the money, not before spending any.
    assert_true(result.usage.cost.total >= 0.00001)
  })
}

///|
/// A zero cost limit means "no limit", not "stop at once".
///
/// The distinction matters because zero is the natural value for "off", and reading it as an
/// immediate stop would make every unlimited call return after one model call — a silent
/// truncation rather than an error.
async test "a zero cost limit is no limit at all" {
  let dir = scratch("cost-off")
  @platform.write_text("\{dir}/note.txt", "hello\n")
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
      max_cost=0.0,
    )
    assert_false(result.cost_limit_hit)
    assert_true(result.settled)
    assert_eq(result.model_calls, 2)
  })
}

// ── Retrying a failed model call ───────────────────────────────────────────

///|
/// Answer with a bare status and no body, so the client raises the error for that code.
fn status_response(code : Int) -> String {
  "HTTP/1.1 \{code} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
}

///|
/// A fake endpoint whose first `failures` requests answer `503`, and which then behaves
/// normally. `seen` counts every request that arrived, retries included.
async fn serve_flaky(
  server : @socket.TcpServer,
  failures : Int,
  responses : Array[String],
  seen : Array[String],
) -> Unit {
  let mut index = 0
  let mut attempts = 0
  while true {
    let (tcp, _) = server.accept()
    let headers = match tcp.read_until("\r\n\r\n") {
      Some(text) => text
      None => ""
    }
    let body = read_request_body(tcp, headers)
    seen.push(body)
    if attempts < failures {
      attempts += 1
      tcp.write(status_response(503))
      tcp.close()
      continue
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
async fn with_flaky_model(
  failures : Int,
  responses : Array[String],
  seen : Array[String],
  body : async (String) -> Unit,
) -> Unit {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group(group => {
    ignore(
      group.spawn(
        () => serve_flaky(server, failures, responses, seen),
        no_wait=true,
      ),
    )
    @async.sleep(30)
    body("http://127.0.0.1:\{port}")
  })
}

///|
/// A turn survives a transient failure: the retry gets a real answer and the turn finishes.
///
/// This is the whole point of retrying. A 503 is the endpoint saying "not now", and without a
/// second attempt the reader loses the turn — and the money already spent on the requests before
/// it — to something that would have worked a second later.
async test "a transient failure is retried and the turn finishes" {
  let dir = scratch("retry-ok")
  let seen : Array[String] = []
  with_flaky_model(2, [text_sse("recovered")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "say something",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_eq(result.replies, ["recovered"])
    assert_eq(result.model_calls, 1)
    // Three requests reached the endpoint: two refused, one answered.
    assert_eq(seen.length(), 3)
  })
}

///|
/// A permanent failure is not retried: the endpoint would say the same thing again.
///
/// The distinction is what keeps a bad key from turning into four identical failures and three
/// pointless waits. Only one request should reach the endpoint.
async test "a permanent failure is reported without retrying" {
  let dir = scratch("retry-permanent")
  let seen : Array[String] = []
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  let failed = @async.with_task_group(group => {
    ignore(
      group.spawn(
        () => {
          while true {
            let (tcp, _) = server.accept()
            let headers = match tcp.read_until("\r\n\r\n") {
              Some(text) => text
              None => ""
            }
            let _ = read_request_body(tcp, headers)
            seen.push("hit")
            tcp.write(status_response(401))
            tcp.close()
          }
        },
        no_wait=true,
      ),
    )
    @async.sleep(30)
    let ctx = context_for(dir, "http://127.0.0.1:\{port}", [])
    let raised = try {
      ignore(@agent.run_turn(ctx, "say something", FIXED_TIME))
      false
    } catch {
      _ => true
    } noraise {
      value => value
    }
    raised
  })
  assert_true(failed, msg="a 401 should end the turn")
  // One request, not four: a permanent failure is an answer, not a hiccup.
  assert_eq(seen.length(), 1)
}

///|
/// Once output has been delivered, a failure is not retried.
///
/// Retrying replays the response from its start, so text the browser has already rendered would
/// be followed by the same text a second time. Stopping is the lesser harm: the reader keeps the
/// prefix they saw and is told the call failed after it had begun.
///
/// The endpoint here promises more bytes than it sends and then drops the connection, which is
/// what a connection dying mid-answer looks like to the client: text arrives, then the stream
/// breaks. That is the one case where a retry would be actively harmful.
async test "a failure after output has started is not retried" {
  let dir = scratch("retry-after-output")
  let seen : Array[String] = []
  // Content, no finish, no [DONE]. The Content-Length lies so the close is an error rather
  // than a clean end.
  let partial = "data: {\"id\":\"c3\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"already seen\"},\"finish_reason\":null}]}\n\n"
  let truncated = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n" +
    partial
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  let deltas : Array[String] = []
  let failed = @async.with_task_group(group => {
    ignore(
      group.spawn(
        () => {
          let mut first = true
          while true {
            let (tcp, _) = server.accept()
            let headers = match tcp.read_until("\r\n\r\n") {
              Some(text) => text
              None => ""
            }
            let _ = read_request_body(tcp, headers)
            seen.push("hit")
            if first {
              first = false
              tcp.write(truncated)
              tcp.close()
            } else {
              // A retry would land here; the test asserts it never does.
              tcp.write(sse_response(text_sse("should not happen")))
              tcp.close()
            }
          }
        },
        no_wait=true,
      ),
    )
    @async.sleep(30)
    let ctx = context_for(dir, "http://127.0.0.1:\{port}", [])
    let raised = try {
      ignore(
        @agent.run_turn(ctx, "say something", FIXED_TIME, on_delta=event => {
          match event {
            @core.Text(delta~) => deltas.push(delta)
            _ => ()
          }
        }),
      )
      false
    } catch {
      _ => true
    } noraise {
      value => value
    }
    raised
  })
  // The text reached the caller before the stream broke, which is exactly why a retry is off
  // the table.
  assert_true(
    deltas.length() > 0,
    msg="expected the partial text to be delivered",
  )
  assert_true(failed, msg="the broken stream should end the turn")
  // And exactly one request was made: no replay of text the reader already has.
  assert_eq(seen.length(), 1)
}

///|
/// A turn that outlives its time budget is stopped, and says that is what stopped it.
///
/// The third bound, and the one neither of the others can express: a command can sit for an hour
/// making no model calls and costing nothing while the reader waits. The deadline is measured from
/// the clock at the start of the turn, and the check is at the top of the loop, so a slow step is
/// allowed to finish and the next one is refused.
///
/// The fake model is given a deliberate delay: a fast one would finish inside any budget and the
/// test would pass without the guard doing anything.
async test "the time limit stops a turn and reports itself" {
  let dir = scratch("time-limit")
  @platform.write_text("\{dir}/note.txt", "again\n")
  let seen : Array[String] = []
  with_fake_model(
    [read_tool_call_sse("note.txt"), text_sse("never reached")],
    seen,
    async fn(base_url) {
      let ctx = context_for(dir, base_url, [])
      let result = @agent.run_turn(
        ctx,
        "take your time",
        FIXED_TIME,
        thinking_level="high",
        max_rounds=1000,
        max_cost=0.0,
        // One second, against a model that takes longer than that to answer.
        max_seconds=1,
      )
      assert_false(result.settled)
      // It stopped after the slow first call rather than running on.
      assert_eq(result.model_calls, 1)
      // And the caller can tell it was the clock, not a limit on calls or money.
      assert_true(result.time_limit_hit, msg="the time limit did not fire")
    },
    delay_ms=1100,
  )
}

///|
/// One chunk of SSE carrying a reply the model stopped writing because it ran out of room.
///
/// The `finish_reason` is the only place the truncation is recorded — the text itself just
/// stops — so this is what the driver has to notice.
fn truncated_sse(text : String) -> String {
  "data: {\"id\":\"c4\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"" +
  text +
  "\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"c4\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":384000,\"total_tokens\":384020}}\n\ndata: [DONE]\n\n"
}

///|
/// An answer cut off at the output limit is reported as truncated, and a whole one is not.
///
/// This is the distinction the reader cannot make for themselves. A response that hit the token
/// ceiling arrives looking exactly like a finished answer — the text simply stops mid-sentence —
/// and the model has no way to say "I was interrupted", because the interruption is the end of
/// what it wrote. Without this flag the UI shows a truncated answer as a complete one.
async test "an answer cut off at the output limit is marked truncated" {
  let dir = scratch("truncated")
  let seen : Array[String] = []
  with_fake_model([truncated_sse("the answer begins and then just")], seen, async fn(
    base_url,
  ) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "write a lot",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_true(result.truncated, msg="a length stop should be reported")
    // The turn itself settled: the model was done, it just ran out of room. Truncation is not a
    // limit on the turn, which is why it needs its own field.
    assert_true(result.settled)
    assert_false(result.cost_limit_hit)
    assert_eq(result.replies, ["the answer begins and then just"])
  })
  // And a clean stop is not marked, so the flag means something.
  let clean : Array[String] = []
  with_fake_model([text_sse("a complete thought")], clean, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "say something",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_false(result.truncated, msg="a stop finish reason is not truncation")
    assert_true(result.settled)
  })
}

///|
/// A turn stopped by a guard leaves a record of *why* in the log.
///
/// Without it the file is ambiguous in a way that costs the reader real time: a turn cut off at
/// the cost limit and a turn that finished both end with a message, and nothing in the messages
/// says which happened. The record is a `custom` entry, so it is not replayed to the model — the
/// next request carries exactly the same conversation it would have.
async test "a turn stopped by a limit records why in the log" {
  let dir = scratch("outcome-limit")
  @platform.write_text("\{dir}/note.txt", "again\n")
  let seen : Array[String] = []
  with_fake_model([read_tool_call_sse("note.txt")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "spend money",
      FIXED_TIME,
      thinking_level="high",
      max_rounds=1000,
      max_cost=0.00001,
    )
    assert_true(result.cost_limit_hit)
    let session = logged(ctx.session_path)
    assert_eq(session.last_turn_ending(), Some(@core.CostLimit))
    // The record does not become conversation: the model is never told about it.
    let messages = session.context().messages
    for message in messages {
      assert_false(
        message is @core.Custom(..),
        msg="a turn outcome must not be replayed to the model",
      )
    }
  })
}

///|
/// An ordinary turn that the model finished adds no record at all.
///
/// The entry is only for endings the conversation cannot express. Writing one for every turn
/// would grow the file for no reader's benefit, and would make "was this turn stopped?" a
/// question with no cheap answer.
async test "a turn that finishes normally records that it finished" {
  let dir = scratch("outcome-normal")
  let seen : Array[String] = []
  with_fake_model([text_sse("all done")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "say something",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_true(result.settled)
    let session = logged(ctx.session_path)
    // Recorded, not omitted. "The log has no outcome" has to mean "this turn never finished",
    // and that is only true if success writes one too.
    assert_eq(session.last_turn_ending(), Some(@core.Completed))
    // The turn is closed, so it is not in flight any more.
    assert_false(session.turn_in_flight())
    // And an ordinary ending is not an interruption, which is what keeps the status line quiet.
    assert_false(@core.TurnEnding::Completed.is_interruption())
  })
}

///|
/// A truncated answer is recorded too, even though the turn itself finished normally.
///
/// This is the case a reader is most likely to be misled by: the turn settled, so nothing else in
/// the log suggests the answer is incomplete.
async test "a truncated answer is recorded as such" {
  let dir = scratch("outcome-truncated")
  let seen : Array[String] = []
  with_fake_model([truncated_sse("the answer begins and then")], seen, async fn(
    base_url,
  ) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "write a lot",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_true(result.truncated)
    assert_true(result.settled)
    let session = logged(ctx.session_path)
    assert_eq(session.last_turn_ending(), Some(@core.Truncated))
  })
}

// ── Continuing an interrupted turn ─────────────────────────────────────────

///|
/// A turn that opens and never closes is one that was interrupted, and the log says so.
///
/// This is the durable half of crash recovery. `needs_repair` covers the case where an assistant
/// message asked for tools and no result answered them; it cannot see a turn killed between two
/// completions, because such a turn leaves the conversation perfectly balanced. The open turn is
/// what makes both cases visible, and it is written before any work happens precisely so that a
/// kill at any moment leaves it behind.
test "an open turn with no outcome is in flight" {
  let header : @core.SessionHeader = {
    id: "s",
    timestamp: @core.format_iso_utc(0L),
    cwd: "/tmp",
    parent_session: None,
    version: Some(3),
  }
  let opened : @core.Entry = {
    id: "t1",
    parent_id: None,
    timestamp: @core.format_iso_utc(0L),
    kind: @core.Custom(
      custom_type=@core.turn_start_type(),
      data=Some(
        Json::object(Map([("prompt", Json::string("build the thing"))])),
      ),
    ),
  }
  let interrupted = @core.Session::new(header, [opened])
  assert_true(interrupted.turn_in_flight())
  assert_eq(interrupted.in_flight_prompt(), Some("build the thing"))
  // Once an outcome is written the turn is closed, whichever way it ended.
  let closed = @core.Session::new(header, [
    opened,
    {
      id: "t2",
      parent_id: Some("t1"),
      timestamp: @core.format_iso_utc(0L),
      kind: @core.Custom(
        custom_type=@core.turn_outcome_type(),
        data=Some(Json::object(Map([("ending", Json::string("completed"))]))),
      ),
    },
  ])
  assert_false(closed.turn_in_flight())
  assert_eq(closed.in_flight_prompt(), None)
}

///|
/// A fresh session has no turn open, so nothing looks interrupted before anything runs.
test "a session that never ran a turn is not in flight" {
  let header : @core.SessionHeader = {
    id: "s",
    timestamp: @core.format_iso_utc(0L),
    cwd: "/tmp",
    parent_session: None,
    version: Some(3),
  }
  assert_false(@core.Session::new(header, []).turn_in_flight())
}

///|
/// Continuing a turn does not ask for the prompt again, and does not open a second turn.
///
/// The distinction from `run_turn` is one message and one entry: a continued turn appends no user
/// message (the prompt is already there) and writes no opening (the turn is already open). What it
/// does do is run the loop to completion and close the turn, which is what makes the log
/// consistent again — and it is the loop, not a replay, so the tool results already recorded stay as
/// they are.
async test "a continued turn closes the open turn without a new prompt" {
  let dir = scratch("continue")
  let seen : Array[String] = []
  with_fake_model([text_sse("carrying on")], seen, async fn(base_url) {
    // The state a crash leaves: the prompt is in the log and the turn was opened, and nothing
    // happened after that. Built by hand rather than by running a turn, because the point is what
    // `continuing` does with this exact shape.
    let ask : @core.Entry = {
      id: "u1",
      parent_id: None,
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("the prompt from before the crash")],
          timestamp: FIXED_TIME,
        }),
      ),
    }
    let opened = @core.turn_start_entry(
      "the prompt from before the crash",
      Some("u1"),
      FIXED_TIME,
    )
    let ctx = context_for(dir, base_url, [ask, opened])
    let result = @agent.run_turn(
      ctx,
      // Ignored: nothing appends it, because `continuing` says the prompt is already in the log.
      "this prompt must not be appended",
      FIXED_TIME,
      thinking_level="high",
      continuing=true,
    )
    assert_eq(result.replies, ["carrying on"])
    let session = logged(ctx.session_path)
    // The turn is closed now, so a restart would not try to continue it again.
    assert_false(session.turn_in_flight())
    assert_eq(session.last_turn_ending(), Some(@core.Completed))
    // And exactly one user message exists — the one the first, interrupted call appended.
    let mut users = 0
    for entry in session.entries {
      match entry.kind {
        @core.Message(message~) =>
          match message {
            @core.User(_) => users += 1
            _ => ()
          }
        _ => ()
      }
    }
    assert_eq(users, 1)
  })
}

///|
/// Typing a new message closes a turn that was left open.
///
/// "At most one turn is open" is an invariant, not a nicety: if the old turn stayed open, every
/// later start would announce an interruption the reader had already moved past — and the log would
/// claim two turns were in flight, which is not a state the reader can act on. Choosing to type
/// again is choosing to abandon the interrupted work.
async test "a new turn abandons an interrupted one" {
  let dir = scratch("abandon")
  let seen : Array[String] = []
  with_fake_model([text_sse("starting over")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    // Open a turn and then walk away from it, the way a crash would.
    let opened = @core.turn_start_entry(
      "the first attempt",
      ctx.session.leaf_id,
      FIXED_TIME,
    )
    @platform.append_entry(ctx.session_path, opened)
    let left_open = ctx.session.add_entries([opened])
    assert_true(left_open.turn_in_flight())
    let ctx = { ..ctx, session: left_open, }
    let result = @agent.run_turn(
      ctx,
      "never mind, do this instead",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_eq(result.replies, ["starting over"])
    // The abandoned turn is closed and the new one is the one open — not both, not neither.
    let session = logged(ctx.session_path)
    assert_false(session.turn_in_flight())
    assert_eq(session.last_turn_ending(), Some(@core.Completed))
    // The new prompt is in the log alongside the old: the reader's history is not rewritten.
    let users : Array[String] = []
    for entry in session.entries {
      match entry.kind {
        @core.Message(message~) =>
          match message {
            @core.User(m) =>
              match m.content[0] {
                @core.Text(text) => users.push(text)
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    assert_eq(users, ["never mind, do this instead"])
  })
}
