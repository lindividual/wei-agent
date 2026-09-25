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
/// One chunk of SSE carrying an `exec` tool call, in the given dialect.
///
/// Two fields rather than one, because that is the tool: `bash` for a command and `moonbit` for a
/// program. A test that wants the "both dialects" refusal can use `arguments_json_sse`.
fn exec_tool_call_sse(field : String, value : String) -> String {
  tool_call_sse("exec", "{\\\"\{field}\\\":\\\"\{value}\\\"}")
}

///|
/// The SSE event list for one tool call: the delta carrying it, then the usage and stop.
fn tool_call_sse(name : String, arguments : String) -> String {
  "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"" +
  name +
  "\",\"arguments\":\"" +
  arguments +
  "\"}}]},\"finish_reason\":null}]}\n\ndata: {\"id\":\"c1\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\ndata: [DONE]\n\n"
}

///|
/// A context whose tools are code mode's, which is what `--mode code` builds.
///
/// The one difference from `context_for` — and the whole point of the test that uses it: a context
/// that does not carry `bash` is a turn that was told, in both the prompt and the schema, that there
/// is no `bash`. Whether the turn *enforces* that is what is under test.
async fn code_mode_context_for(
  dir : String,
  base_url : String,
  entries? : Array[@core.Entry] = [],
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
  let tools = @core.tools_for_mode(@core.ToolMode::Code)
  @agent.AgentContext::new(
    session=@core.Session::new(header, entries),
    session_path=path,
    cwd=dir,
    api_key="fixture-key",
    system_prompt=@core.build_system_prompt(
      dir,
      tools,
      mode=@core.ToolMode::Code,
    ),
    tools~,
    base_url~,
  )
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
  jobs? : @core.JobStore,
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
    jobs=jobs.unwrap_or(@core.JobStore::new()),
  )
}

///|
/// The entries in the log on disk, parsed back.
async fn logged(path : String) -> @core.Session {
  @core.parse_session_file(@platform.read_text(path))
}

///|
/// Whether the log still holds a tool call on its path that no result answers.
///
/// **A test-local helper, deliberately.** `core` used to export exactly this question as
/// `needs_repair`, and nothing in production ever called it — the repair that runs asks a *stronger*
/// question ("is every result next to the call it answers?"), which is why a transcript where every
/// call had a result and they were all in the wrong place found nothing to fix while every request came
/// back `HTTP 400`. That stronger case has its own test (`an answer in the wrong place is moved to its
/// call`); this one is what the assertions below mean when they say "the log still has an unanswered
/// call", so it lives here rather than as a second public predicate beside the real one.
fn has_unanswered_call(session : @core.Session) -> Bool {
  let answered : Map[String, Unit] = Map([])
  let calls : Array[String] = []
  for entry in session.context_entries() {
    match entry.kind {
      @core.Message(message~) =>
        match message {
          @core.ToolResult(result) => answered.set(result.tool_call_id, ())
          @core.Assistant(assistant) =>
            for block in assistant.content {
              match block {
                @core.ToolCall(id~, ..) => calls.push(id)
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  for id in calls {
    if answered.get(id) is None {
      return true
    }
  }
  false
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
/// deliberately cancelled. upstream writes `aborted`, and this is the one place the
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
/// replayed without upstream's `<summary>` wrapper is a summary the model cannot tell
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
    assert_false(result.session |> has_unanswered_call)
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
/// The figures a turn reports arrive as it runs, not when it ends.
///
/// A turn of twenty rounds would otherwise hand the whole of its spend over at the moment the reader
/// stops needing it, and the tokens, the cache reads and how full the window is are what they watch
/// *while* a long turn runs. So every write to the log is reported with the log as it stands, and a
/// call's own numbers are there before the next one is made.
async test "the log is reported at every commit, not only at the end" {
  let dir = scratch("usage-live")
  @platform.write_text("\{dir}/note.txt", "live-output\n")
  let seen : Array[String] = []
  // Replies, billed input, messages on the path — what the bar reads off each snapshot.
  let snapshots : Array[(Int, Int, Int)] = []
  with_fake_model([read_tool_call_sse("note.txt"), text_sse("done")], seen, async fn(
    base_url,
  ) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "read a file",
      FIXED_TIME,
      thinking_level="high",
      on_commit=session => {
        let usage = session.usage()
        snapshots.push(
          (
            usage.replies,
            usage.billed_input(),
            session.context().messages.length(),
          ),
        )
      },
    )
    assert_eq(result.model_calls, 2)
    // The prompt, the turn opening, the two responses and the tool round. The turn opening reports
    // nothing new — it moves neither the spend nor the conversation — and is reported anyway,
    // because it is the entry that answers "is a turn in flight" for the caller: without it the
    // caller's copy stops at the prompt, and the next prompt opens a second turn beside the first.
    // The model change is the one commit that is not reported: it is written before the prompt,
    // moves nothing the caller watches, and is read from the file by whoever needs it.
    assert_eq(snapshots.length(), 5)
    // Nothing spent yet when the prompt goes in, and the window has already moved — the figure a
    // reader watches when a turn spends a long time before its first token. The turn opening
    // reports the same numbers one commit later.
    let (spent, _, at_prompt) = snapshots[0]
    assert_eq(spent, 0)
    let (still_nothing, _, after_opening) = snapshots[1]
    assert_eq(still_nothing, 0)
    assert_eq(after_opening, at_prompt)
    // The first call's own tokens are reported while the turn is still working on the second.
    let (first, input, _) = snapshots[2]
    assert_eq(first, 1)
    assert_eq(input, 10, msg="the first scripted call bills 10 prompt tokens")
    // The last snapshot before the turn ended has the whole of it, tool round included — that is
    // what the bar is left showing.
    let (all, _, messages) = snapshots[snapshots.length() - 1]
    assert_eq(all, result.model_calls)
    assert_eq(messages, result.session.context().messages.length())
  })
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
/// The wait between attempts is reported, so the longest silence in a turn is not silent.
///
/// A retry is where a turn has the least to watch: the model has not answered, no tool has run, and
/// neither count has moved. What a front end gets is the pair — which attempt is about to be made —
/// and then a `None` when the call answers, because a line saying the model has not answered would
/// otherwise still be saying it over an answer that had started to arrive.
///
/// The first attempt is not reported: it is not a retry, and a line announcing "trying" before
/// anything has failed would be a line about nothing.
async test "a retry is reported and then taken back" {
  let dir = scratch("retry-reported")
  let seen : Array[String] = []
  let reported : Array[String] = []
  let on_retry : async (@agent.RetryAttempt?) -> Unit = attempt => {
    match attempt {
      Some(pending) =>
        reported.push("about to try \{pending.next} of \{pending.total}")
      None => reported.push("answered")
    }
  }
  // One refused request rather than two: the wait before a retry is real, and this test is about
  // what is said during it rather than about how many can be waited out.
  with_flaky_model(1, [text_sse("recovered")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let result = @agent.run_turn(
      ctx,
      "say something",
      FIXED_TIME,
      thinking_level="high",
      on_retry~,
    )
    assert_eq(result.replies, ["recovered"])
  })
  assert_eq(reported, ["about to try 2 of 4", "answered"])
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
  // Outside the group's closure, because it is read after the group has finished: a front end that
  // announced a retry for every failed request would have to be wrong about something the driver
  // never told it, and this is what says it was not told.
  let reported : Ref[Bool] = Ref(false)
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
    let on_retry : async (@agent.RetryAttempt?) -> Unit = _attempt => {
      reported.val = true
    }
    let raised = try {
      ignore(@agent.run_turn(ctx, "say something", FIXED_TIME, on_retry~))
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
  assert_false(reported.val, msg="a permanent failure is never retried")
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
/// This is the durable half of crash recovery. A check for calls nobody answered covers the case
/// where an assistant message asked for tools and no result came back; it cannot see a turn killed
/// between two completions, because such a turn leaves the conversation perfectly balanced. The open turn is
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

///|
/// A call to a tool this turn does not have runs nothing, and comes back as a refusal.
///
/// This is the failure the mode was supposed to prevent, measured: with `exec` and `wait` as the
/// entire schema, a resumed session emitted `bash` 165 times in one turn and every one of them ran,
/// because the mode only ever decided what was *declared*. The check is therefore here — at the one
/// place that acts on a call — and the assertions are about the three things that follow from it:
/// the command did not run, what the model got back says so and says what to use instead, and the
/// refusal is a tool result like any other rather than a turn that died.
async test "a tool this turn does not have is refused and nothing runs" {
  let dir = scratch("undeclared-tool")
  let seen : Array[String] = []
  // The model asks for `bash`, then — after being told — for `exec`. The reply is what the second
  // call produces, so a turn that failed to run the real tool could not reach it.
  with_fake_model(
    [
      bash_tool_call_sse("/usr/bin/touch should-not-exist"),
      exec_tool_call_sse("moonbit", "@builtin/nope"),
      text_sse("both behind me"),
    ],
    seen,
    async fn(base_url) {
      // A context whose tools are code mode's, which is what `--mode code` builds.
      let ctx = code_mode_context_for(dir, base_url)
      let result = @agent.run_turn(
        ctx,
        "touch a file",
        FIXED_TIME,
        thinking_level="high",
      )
      // Three calls: the attempt at `bash`, the attempt at `exec`, and the answer.
      assert_eq(result.model_calls, 3)
      // One tool call, not two: the count is what *ran*, and a refused call ran nothing. That is
      // also what keeps the figure in the footer honest — it says how many tools did something.
      assert_eq(result.tool_calls, 1)
      assert_false(
        @platform.path_exists("\{dir}/should-not-exist"),
        msg="a refused call ran the command anyway",
      )

      let session = logged(ctx.session_path)
      let refusals : Array[String] = []
      for entry in session.entries {
        match entry.kind {
          @core.Message(message~) =>
            match message {
              @core.ToolResult(result) =>
                if result.is_error && result.tool_name == "bash" {
                  for block in result.content {
                    match block {
                      @core.Text(text) => refusals.push(text)
                      _ => ()
                    }
                  }
                }
              _ => ()
            }
          _ => ()
        }
      }
      assert_eq(refusals.length(), 1, msg="expected exactly one refusal")
      assert_true(
        refusals[0].contains("no tool named `bash`, so nothing ran"),
        msg=refusals[0],
      )
      assert_true(refusals[0].contains("`exec`, `wait`"), msg=refusals[0])
      assert_true(
        refusals[0].contains("`exec`'s `bash` field"),
        msg=refusals[0],
      )
      // The refusal is in the request the next call was built from, so the model read it.
      assert_true(
        seen[1].contains("no tool named"),
        msg="the refusal was not sent back",
      )
      // And the two tool names are in the prompt the turn opened with, because a fresh session has
      // no history to be stale — this one was built by hand, so what is checked is that the prompt
      // was built from the code-mode tool set at all.
      assert_true(ctx.system_prompt.contains("- exec:"), msg=ctx.system_prompt)
      assert_false(ctx.system_prompt.contains("- bash:"), msg=ctx.system_prompt)
    },
  )
}

///|
/// A call that is refused never becomes a job, however it is spelled.
///
/// The order of the two checks in the driver is the point: the tool set is consulted before the
/// background record is opened, so a refused `bash` in a code-mode turn cannot leave a job row
/// pointing at a process that was never started — nor spend one of the session's ten slots.
async test "a refused call does not open a job record" {
  let dir = scratch("refused-job")
  let seen : Array[String] = []
  with_fake_model(
    [bash_tool_call_sse("/bin/sleep 30 &"), text_sse("done")],
    seen,
    async fn(base_url) {
      let ctx = code_mode_context_for(dir, base_url)
      let result = @agent.run_turn(
        ctx,
        "background something",
        FIXED_TIME,
        thinking_level="high",
      )
      // Nothing ran, so nothing is counted as having run.
      assert_eq(result.tool_calls, 0)
      assert_eq(ctx.jobs.live_count(ctx.session_path), 0)
      assert_eq(
        ctx.jobs.list().length(),
        0,
        msg="a refused call left a job behind",
      )
    },
  )
}

///|
/// A log left with an unanswered tool call is closed before the next request goes out.
///
/// The situation is ordinary rather than exotic: the reader presses Stop while a tool round is
/// running. The assistant message with its `tool_calls` is already committed, the results are not —
/// and that transcript is one a provider refuses outright, because an assistant message that asks
/// for tools must be followed by the answers to them. Measured, in the app: two prompts in a row
/// went out, died on the endpoint's rejection, and left the session looking like it would not run
/// anything again. Nothing in the log said why, because the failure happened before the first entry
/// of the new turn could be written.
///
/// What is asserted is the shape of the first request: the call has an answer, and the answer says
/// the truth about what happened rather than pretending the tool ran.
async test "an unanswered tool call is closed before the next request" {
  let dir = scratch("repair")
  // A log that stopped between the call and its result, exactly as a Stop leaves one.
  let entries : Array[@core.Entry] = [
    {
      id: "u1",
      parent_id: None,
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("read the note")],
          timestamp: FIXED_TIME,
        }),
      ),
    },
    {
      id: "a1",
      parent_id: Some("u1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.Assistant({
          content: [
            @core.ToolCall(
              id="call_interrupted",
              name="read",
              arguments=Json::object(Map([("path", Json::string("note.txt"))])),
            ),
          ],
          api: "openai-completions",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          usage: @core.Usage::zero(),
          stop_reason: @core.ToolUse,
          timestamp: FIXED_TIME,
          response_id: None,
          response_model: None,
          raw_stop_reason: Some("tool_calls"),
          error_message: None,
        }),
      ),
    },
  ]
  let seen : Array[String] = []
  with_fake_model([text_sse("carrying on")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, entries)
    let result = @agent.run_turn(
      ctx,
      "continue",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_eq(result.replies, ["carrying on"])

    assert_eq(seen.length(), 1)
    // The call is answered in the very first request: no round trip is spent learning that the
    // transcript is not acceptable.
    assert_true(
      seen[0].contains("\"role\":\"tool\""),
      msg="the request carried an unanswered tool call: \{seen[0]}",
    )
    assert_true(seen[0].contains("call_interrupted"), msg=seen[0])

    // And the log says so, so that the next process to open the session sends the same thing.
    let session = logged(ctx.session_path)
    assert_false(
      has_unanswered_call(session),
      msg="the log still has an unanswered call",
    )
    let kinds : Array[String] = []
    for entry in session.entries {
      match entry.kind {
        @core.Message(message~) =>
          match message {
            @core.User(_) => kinds.push("user")
            @core.Assistant(_) => kinds.push("assistant")
            @core.ToolResult(_) => kinds.push("toolResult")
          }
        _ => ()
      }
    }
    assert_eq(kinds, ["user", "assistant", "toolResult", "user", "assistant"])
  })
}

///|
/// A turn stopped while the model was asking for tools leaves a gap, and the next turn closes it.
///
/// This is the whole of the reported symptom, end to end: press Stop at the wrong moment, and the
/// log holds an assistant message whose `tool_calls` nothing answers. The loop breaks on `stopping()`
/// at the top *before* running the tools — which is deliberate, since a stop must not start new work
/// — so the gap is what a stop leaves rather than a mistake in the stop.
///
/// What matters is what happens next, which is where it used to fail: the reader types again, the
/// request carries the unanswered call, and the provider refuses the whole thing. The turn never
/// starts, nothing is written, and the session looks like it will not run anything again.
async test "a gap left by a stop is closed by the turn after it" {
  let dir = scratch("stop-gap")
  let seen : Array[String] = []
  with_fake_model([bash_tool_call_sse("echo never-runs")], seen, async fn(
    base_url,
  ) {
    let ctx = context_for(dir, base_url, [])
    let stop = Ref(false)
    // The stop is raised from `on_commit`, which is the moment that matters and the one a reader
    // cannot aim at: the assistant message with its tool call has just been written, and the tools
    // have not started. `stopping()` is checked immediately after that commit, so the turn ends
    // between the call and its answer — which is exactly what pressing Stop at the wrong moment
    // does, and what leaves a transcript a provider will not accept.
    let stop_after_the_call : async (@core.Session) -> Unit = fn(session) {
      for entry in session.entries {
        match entry.kind {
          @core.Message(message~) =>
            match message {
              @core.Assistant(a) => if !a.content.is_empty() { stop.val = true }
              _ => ()
            }
          _ => ()
        }
      }
    }
    let result = @agent.run_turn(
      ctx,
      "run something",
      FIXED_TIME,
      thinking_level="high",
      should_stop=() => stop.val,
      on_commit=stop_after_the_call,
    )
    assert_eq(result.tool_calls, 0)

    // The gap is real: the model asked for a tool, the answer is committed, and no result was
    // written. This is what the reader's next prompt used to run into.
    let left = logged(ctx.session_path)
    assert_true(
      has_unanswered_call(left),
      msg="the stop did not leave the unanswered call this test is about",
    )

    // The next turn — the reader typing again — is sent a transcript the provider will accept.
    let seen2 : Array[String] = []
    with_fake_model([text_sse("carrying on")], seen2, async fn(base2) {
      let ctx2 = context_for(dir, base2, left.entries)
      let second = @agent.run_turn(
        ctx2,
        "try again",
        FIXED_TIME,
        thinking_level="high",
      )
      assert_eq(second.replies, ["carrying on"])
      assert_eq(seen2.length(), 1)
      assert_true(
        seen2[0].contains("\"role\":\"tool\""),
        msg="the repaired request has no tool result: \{seen2[0]}",
      )
      assert_false(has_unanswered_call(logged(ctx2.session_path)))
    })
  })
}

///|
/// A prompt after a failed turn opens one turn, not two.
///
/// The invariant `continuing` exists to keep is "at most one turn is open", and it is kept by asking
/// the *caller's* session whether a turn is in flight. That answer is only as current as the last
/// commit the caller was told about — and a turn that failed on a network error never reaches its
/// end, so the caller keeps whatever it was last handed. The turn opening is now reported like any
/// other commit for exactly this reason: without it the caller's copy stops at the prompt, the next
/// prompt sees no turn in flight, and the log ends up with two openings and one outcome.
async test "a prompt after a failure leaves one open turn, not two" {
  let dir = scratch("after-failure")
  let path = "\{dir}/session.jsonl"
  let tools = @core.builtin_tools()
  let header : @core.SessionHeader = {
    id: "test",
    timestamp: @core.format_iso_utc(FIXED_TIME),
    cwd: dir,
    parent_session: None,
    version: Some(3),
  }
  @platform.create_session(path, header)
  // The caller's copy of the session, kept the way the app keeps its own: every commit it is told
  // about, and — after a turn that finished — the session the turn handed back. A turn that *failed*
  // never hands one back, which is the whole of this test.
  let current = Ref(@core.Session::new(header, []))
  let ctx_for = (base_url : String) => {
    @agent.AgentContext::new(
      session=current.val,
      session_path=path,
      cwd=dir,
      api_key="fixture-key",
      system_prompt=@core.build_system_prompt(dir, tools),
      tools~,
      base_url~,
      context_window=@core.deepseek_v4_flash_context_window(),
    )
  }
  let remember : async (@core.Session) -> Unit = session => {
    current.val = session
  }
  // The first turn dies on a connection that is never there: the one failure that leaves the caller
  // holding an open turn, because the cleanup after the loop never runs.
  let dead = "http://127.0.0.1:9"
  let raised = try {
    let _ = @agent.run_turn(
      ctx_for(dead),
      "first prompt",
      FIXED_TIME,
      thinking_level="high",
      max_rounds=1,
      on_commit=remember,
    )
    false
  } catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
  assert_true(
    current.val.turn_in_flight(),
    msg="the failed turn should have left the caller with an open turn",
  )

  let seen : Array[String] = []
  with_fake_model([text_sse("second answer")], seen, async fn(base_url) {
    let second = @agent.run_turn(
      ctx_for(base_url),
      "second prompt",
      FIXED_TIME,
      thinking_level="high",
      on_commit=remember,
    )
    assert_eq(second.replies, ["second answer"])
    // The reader's words reached the model: this is the half of the bug that was silent.
    assert_eq(seen.length(), 1)
    assert_true(seen[0].contains("second prompt"), msg=seen[0])

    // One opening per prompt, each closed: the failed turn is abandoned rather than left open
    // beside the new one, so the log never claims two turns in flight.
    let log = logged(path)
    let mut starts = 0
    let mut outcomes = 0
    let mut trace = ""
    for entry in log.entries {
      match entry.kind {
        @core.Custom(custom_type~, ..) => {
          trace = trace + "\n  " + custom_type
          if custom_type == @core.turn_start_type() {
            starts += 1
          } else if custom_type == @core.turn_outcome_type() {
            outcomes += 1
          }
        }
        @core.Message(message~) =>
          match message {
            @core.User(_) => trace = trace + "\n  user"
            @core.Assistant(_) => trace = trace + "\n  assistant"
            @core.ToolResult(_) => trace = trace + "\n  toolResult"
          }
        _ => ()
      }
    }
    if starts != 2 || outcomes != 2 {
      fail("starts=\{starts} outcomes=\{outcomes}\{trace}")
    }
    assert_false(log.turn_in_flight())
    assert_false(has_unanswered_call(log))
  })
}

///|
/// The answers to an interrupted call land next to the call, not at the end of the file.
///
/// This is the shape a real session had, and it is the one that made a session unrecoverable: the
/// reader pressed Stop during a model call, the assistant message with its `tool_calls` was committed,
/// and then they typed again — so the gap was no longer at the leaf when the repair ran. An answer
/// appended at the end landed *after* the new prompt:
///
///     assistant(tool_calls: exec "")     ← asks for a tool
///     user("继续吧")                       ← the reader's next prompt
///     tool("The tool call was interrupted…")   ← the answer, three messages too late
///
/// A provider checks that a `tool` message directly follows the assistant message that asked for it,
/// so every request built from that log was refused — `HTTP 400`, every turn, forever. The repair now
/// writes the answer where it belongs and re-parents what came after it.
async test "an interrupted call is answered where it was asked" {
  let dir = scratch("gap-not-at-leaf")
  let path = "\{dir}/session.jsonl"
  let header : @core.SessionHeader = {
    id: "test",
    timestamp: @core.format_iso_utc(FIXED_TIME),
    cwd: dir,
    parent_session: None,
    version: Some(3),
  }
  @platform.create_session(path, header)
  // The log as the Stop left it: a call, the turn closed, then the reader typing again and a second
  // turn opened. Nothing answers `call_gap`.
  let entries : Array[@core.Entry] = [
    {
      id: "u1",
      parent_id: None,
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("run something")],
          timestamp: FIXED_TIME,
        }),
      ),
    },
    {
      id: "a1",
      parent_id: Some("u1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.Assistant({
          content: [
            @core.ToolCall(
              id="call_gap",
              name="exec",
              arguments=Json::object(Map([("bash", Json::string(""))])),
            ),
          ],
          api: "openai-completions",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          usage: @core.Usage::zero(),
          stop_reason: @core.ToolUse,
          timestamp: FIXED_TIME,
          response_id: None,
          response_model: None,
          raw_stop_reason: Some("tool_calls"),
          error_message: None,
        }),
      ),
    },
    {
      id: "o1",
      parent_id: Some("a1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.turn_outcome_entry(
        @core.Stopped,
        1,
        0.0,
        Some("a1"),
        FIXED_TIME,
      ).kind,
    },
    {
      id: "u2",
      parent_id: Some("o1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("carry on")],
          timestamp: FIXED_TIME + 1L,
        }),
      ),
    },
    {
      id: "t2",
      parent_id: Some("u2"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Custom(
        custom_type=@core.turn_start_type(),
        data=Some(Json::object(Map([("prompt", Json::string("carry on"))]))),
      ),
    },
  ]
  @platform.append_entries(path, entries)

  let seen : Array[String] = []
  with_fake_model([text_sse("answered")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, entries)
    let result = @agent.run_turn(
      ctx,
      "carry on",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_eq(result.replies, ["answered"])

    // The message the provider checks: the answer is adjacent to the call that asked for it, and it
    // comes before the prompt the reader typed afterwards. A position in the request is enough —
    // what is being checked is the order of two strings, not the JSON around them.
    let sent = seen[0]
    let at = (needle : String) => {
      match sent.find(needle) {
        Some(index) => index
        None => -1
      }
    }
    let gap_at = at("call_gap")
    let answer_at = at("interrupted before its result")
    let prompt_at = at("carry on")
    assert_true(gap_at >= 0, msg="the call is not in the request")
    assert_true(answer_at >= 0, msg="the answer is not in the request")
    assert_true(
      answer_at > gap_at && (prompt_at < 0 || answer_at < prompt_at),
      msg="the answer is not next to the call (call=\{gap_at} answer=\{answer_at} prompt=\{prompt_at})",
    )

    // And nothing was lost: every message the reader and the model had is still on the path.
    let log = logged(path)
    let texts : Array[String] = []
    for entry in log.context_entries() {
      match entry.kind {
        @core.Message(message~) =>
          match message {
            @core.User(user) =>
              for block in user.content {
                match block {
                  @core.Text(text) => texts.push(text)
                  _ => ()
                }
              }
            _ => ()
          }
        _ => ()
      }
    }
    assert_true(
      texts.contains("run something"),
      msg="the reader's messages are not all on the path",
    )
    assert_true(
      texts.contains("carry on"),
      msg="the reader's messages are not all on the path",
    )
    assert_false(has_unanswered_call(log))
    assert_false(log.turn_in_flight())
  })
}

///|
/// An answer that is on the path but not next to its call is moved next to it.
///
/// This is the case that made a real session unusable, and it is the one a repair that only looks for
/// *missing* results cannot see: the answer was there, three messages too late —
///
///     assistant(tool_calls: exec "…")           ← asks
///     turn-outcome(stopped)                     ← the turn closed
///     user("继续吧")                              ← the reader typed again
///     turn-start("继续吧")
///     tool("The tool call was interrupted…")    ← the answer, at the end of the file
///
/// — because the turn that stopped had already been closed and the reader's next prompt written before
/// anything answered the call. A provider checks that a `tool` message directly follows the assistant
/// message that asked for it, so every request built from that log was refused.
///
/// The repair moves the answer rather than adding a second one: a duplicate `tool_call_id` would be
/// refused too, and the entry's own id is kept so the log still refers to the same things.
async test "an answer in the wrong place is moved to its call" {
  let dir = scratch("answer-misplaced")
  let path = "\{dir}/session.jsonl"
  let header : @core.SessionHeader = {
    id: "test",
    timestamp: @core.format_iso_utc(FIXED_TIME),
    cwd: dir,
    parent_session: None,
    version: Some(3),
  }
  @platform.create_session(path, header)
  let call : @core.Message = @core.Assistant({
    content: [
      @core.ToolCall(
        id="call_late",
        name="exec",
        arguments=Json::object(Map([("bash", Json::string("echo hi"))])),
      ),
    ],
    api: "openai-completions",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    usage: @core.Usage::zero(),
    stop_reason: @core.ToolUse,
    timestamp: FIXED_TIME,
    response_id: None,
    response_model: None,
    raw_stop_reason: Some("tool_calls"),
    error_message: None,
  })
  let entries : Array[@core.Entry] = [
    {
      id: "u1",
      parent_id: None,
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("do it")],
          timestamp: FIXED_TIME,
        }),
      ),
    },
    {
      id: "a1",
      parent_id: Some("u1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(message=call),
    },
    {
      id: "o1",
      parent_id: Some("a1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.turn_outcome_entry(
        @core.Stopped,
        1,
        0.0,
        Some("a1"),
        FIXED_TIME,
      ).kind,
    },
    {
      id: "u2",
      parent_id: Some("o1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("try again")],
          timestamp: FIXED_TIME + 1L,
        }),
      ),
    },
    {
      id: "t2",
      parent_id: Some("u2"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Custom(
        custom_type=@core.turn_start_type(),
        data=Some(Json::object(Map([("prompt", Json::string("try again"))]))),
      ),
    },
    // The answer: written, and written in the wrong place.
    {
      id: "late",
      parent_id: Some("t2"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.aborted_tool_result(
          call_id="call_late",
          tool_name="exec",
          timestamp=FIXED_TIME,
        ),
      ),
    },
  ]
  @platform.append_entries(path, entries)

  // A repair that only asked "which calls have no result" would leave this session alone, which is
  // exactly what happened in the app.
  assert_false(has_unanswered_call(logged(path)))

  let seen : Array[String] = []
  with_fake_model([text_sse("done")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, entries)
    let result = @agent.run_turn(
      ctx,
      "try again",
      FIXED_TIME,
      thinking_level="high",
    )
    assert_eq(result.replies, ["done"])

    let sent = seen[0]
    let at = (needle : String) => {
      match sent.find(needle) {
        Some(index) => index
        None => -1
      }
    }
    let call_at = at("call_late")
    let answer_at = at("interrupted before its result")
    let prompt_at = at("try again")
    assert_true(call_at >= 0, msg="the call is not in the request")
    assert_true(answer_at >= 0, msg="the answer is not in the request")
    assert_true(
      answer_at > call_at && (prompt_at < 0 || answer_at < prompt_at),
      msg="the answer did not move next to its call (call=\\{call_at} answer=\\{answer_at} prompt=\\{prompt_at})",
    )

    // Moved, not copied: the log has one answer to that call, and everything else is still there.
    let log = logged(path)
    let mut answers = 0
    let ids : Array[String] = []
    for entry in log.path() {
      ids.push(entry.id)
      match entry.kind {
        @core.Message(message~) =>
          match message {
            @core.ToolResult(r) =>
              if r.tool_call_id == "call_late" {
                answers += 1
              }
            _ => ()
          }
        _ => ()
      }
    }
    assert_eq(answers, 1, msg="the answer was copied instead of moved")
    assert_true(ids.contains("u2"), msg="the reader's prompt was lost")
    assert_true(ids.contains("o1"), msg="the closed turn was lost")
    assert_false(log.turn_in_flight())
  })
}

///|
/// Opening a session repairs the transcript without answering the reader's question.
///
/// The two are separate decisions and this is the test that keeps them apart. `repair_session` is what
/// a host calls when it opens a file — the app resuming one, the web UI showing one — and it must fix
/// what a provider would reject while leaving the interrupted turn *open*, because that entry is what
/// the reader is shown: "this turn was interrupted; continue it, or start fresh". A host that closed it
/// on open would have answered that for them, and the notice would never appear.
///
/// "Start fresh" is not a cancel — see `TurnEnding::Abandoned` — which is why this is not a rewrite of
/// the turn's history but a refusal to touch it.
async test "opening a session repairs it but leaves the interrupted turn open" {
  let dir = scratch("repair-on-open")
  let path = "\{dir}/session.jsonl"
  let header : @core.SessionHeader = {
    id: "test",
    timestamp: @core.format_iso_utc(FIXED_TIME),
    cwd: dir,
    parent_session: None,
    version: Some(3),
  }
  @platform.create_session(path, header)
  let entries : Array[@core.Entry] = [
    {
      id: "u1",
      parent_id: None,
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.User({
          content: [@core.Text("go")],
          timestamp: FIXED_TIME,
        }),
      ),
    },
    {
      id: "t1",
      parent_id: Some("u1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Custom(
        custom_type=@core.turn_start_type(),
        data=Some(Json::object(Map([("prompt", Json::string("go"))]))),
      ),
    },
    {
      id: "a1",
      parent_id: Some("t1"),
      timestamp: @core.format_iso_utc(FIXED_TIME),
      kind: @core.Message(
        message=@core.Assistant({
          content: [
            @core.ToolCall(
              id="call_open",
              name="exec",
              arguments=Json::object(Map([("bash", Json::string("echo hi"))])),
            ),
          ],
          api: "openai-completions",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          usage: @core.Usage::zero(),
          stop_reason: @core.ToolUse,
          timestamp: FIXED_TIME,
          response_id: None,
          response_model: None,
          raw_stop_reason: Some("tool_calls"),
          error_message: None,
        }),
      ),
    },
  ]
  @platform.append_entries(path, entries)

  let opened = @agent.repair_session(
    @core.parse_session_file(@platform.read_text(path)),
    path,
    FIXED_TIME,
  )
  // The gap is closed…
  assert_false(has_unanswered_call(opened), msg="the call was not answered")
  // …and the turn is still open, so whoever draws the session can still offer to continue it.
  assert_true(
    opened.turn_in_flight(),
    msg="opening the session decided the reader's turn for them",
  )
  assert_eq(opened.in_flight_prompt(), Some("go"))

  // Nothing was lost, and the answer is next to the call it answers.
  let after = logged(path)
  let ids : Array[String] = []
  for entry in after.path() {
    ids.push(entry.id)
  }
  assert_true(ids.contains("u1"))
  assert_true(ids.contains("a1"))
  assert_true(ids.contains("t1"))
}

///|
/// Pictures attached to a prompt travel inside it, and the provider is sent them.
///
/// The whole feature is this one thing: an image is part of the question, so it is committed in the
/// same entry as the text. Appending it as its own message would leave a replayed session with the
/// picture after the answer to the question it belonged to — and the request would be a message the
/// provider reads as a new turn.
async test "an attached image is committed with its prompt and sent" {
  let dir = scratch("prompt-image")
  let seen : Array[String] = []
  with_fake_model([text_sse("looked at it")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    let png = @core.Content::Image(data="aGVsbG8=", mime_type="image/png")
    let result = @agent.run_turn(
      ctx,
      "what is this?",
      FIXED_TIME,
      thinking_level="high",
      prompt_images=[png],
    )
    assert_eq(result.replies, ["looked at it"])
    // One request, and the picture is in it as the data URL the wire wants.
    assert_eq(seen.length(), 1)
    assert_true(seen[0].contains("data:image/png;base64,aGVsbG8="), msg=seen[0])

    let session = logged(ctx.session_path)
    let mut user_content : Array[@core.Content] = []
    for entry in session.entries {
      match entry.kind {
        @core.Message(message=@core.User(user)) => user_content = user.content
        _ => ()
      }
    }
    // The text, then the picture, in one message rather than two.
    assert_eq(user_content.length(), 2)
    assert_true(user_content[0] is @core.Text("what is this?"))
    assert_true(user_content[1] is @core.Image(..))
  })
}

///|
/// A prompt with no pictures is the message it always was.
///
/// The default has to be exactly this, because `prompt_images` is optional and four front ends pass
/// none: a stray empty block would be a change to every request this project has ever recorded.
async test "a prompt with no images is just its text" {
  let dir = scratch("prompt-no-image")
  let seen : Array[String] = []
  with_fake_model([text_sse("hello")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    ignore(@agent.run_turn(ctx, "hi", FIXED_TIME, thinking_level="high"))
    let session = logged(ctx.session_path)
    for entry in session.entries {
      match entry.kind {
        @core.Message(message=@core.User(user)) =>
          assert_eq(user.content.length(), 1)
        _ => ()
      }
    }
  })
}

///|
/// A call that never ran leaves no job behind.
///
/// The bug: a job record is created as soon as a call is seen to be the kind that leaves a process,
/// and the record is normally settled by the tool reporting its pids. A tool that refuses *before*
/// executing — an empty command, a dialect the tool does not take — never reports, so the record sat
/// in the store claiming to be running forever: a row in the background panel with no process behind
/// it, a Kill that reaches nothing, and one of the session's ten slots spent.
///
/// `call_open` is the flag that says "the call has not reported yet". A call that has *returned*
/// with it still set is a call that never will.
async test "a tool call that refuses before running leaves no job" {
  let dir = scratch("empty-command-job")
  let seen : Array[String] = []
  with_fake_model([bash_tool_call_sse(""), text_sse("ok then")], seen, async fn(
    base_url,
  ) {
    let jobs = @core.JobStore::new()
    let ctx = context_for(dir, base_url, [], jobs~)
    let result = @agent.run_turn(
      ctx,
      "run nothing",
      FIXED_TIME,
      thinking_level="high",
    )
    // The turn is unaffected: the refusal is a tool result like any other.
    assert_eq(result.replies, ["ok then"])
    // And nothing is left claiming to be running.
    assert_eq(jobs.list().length(), 0, msg="a phantom job outlived its call")
  })
}

///|
/// The level a turn is asked for reaches the wire, and the *off* level reaches it as thinking off.
///
/// Two halves of one fact, and the second is the one that was wrong until `ThinkingLevels::resolve`
/// learned the name: a level is recorded in the log as a string, so a session that ran with thinking
/// disabled reads back as `"off"`, and a resume that sent `reasoning_effort: "off"` would be asking
/// for an effort the API does not have rather than for no thinking.
async test "the thinking level a turn asks for is the one the model is sent" {
  let dir = scratch("thinking-level")
  let seen : Array[String] = []
  with_fake_model([text_sse("ok")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    ignore(
      @agent.run_turn(ctx, "think a little", FIXED_TIME, thinking_level="low"),
    )
    assert_eq(seen.length(), 1)
    assert_true(
      seen[0].contains("\"thinking\":{\"type\":\"enabled\"}"),
      msg=seen[0],
    )
    assert_true(seen[0].contains("\"reasoning_effort\":\"low\""), msg=seen[0])
    // And the log records the level, so a resume asks for the same thing.
    let session = logged(ctx.session_path)
    assert_eq(session.context().thinking_level, Some("low"))
  })
}

///|
/// A turn asked for no level at all is a turn with thinking **off**, and it is written down.
///
/// `None` used to be indistinguishable from a log nobody had set a level in, which is what made a
/// reader's choice impossible to remember *and* impossible to override: a front end had no way to
/// tell "this session runs at off" from "this session has not decided". The driver writing the
/// resolution down is what separates them — and the request it sends is the disabled form, not an
/// effort called `off`.
async test "a turn with no level is recorded as off and sent as disabled" {
  let dir = scratch("thinking-default")
  let seen : Array[String] = []
  with_fake_model([text_sse("ok")], seen, async fn(base_url) {
    let ctx = context_for(dir, base_url, [])
    ignore(@agent.run_turn(ctx, "just answer", FIXED_TIME))
    assert_eq(seen.length(), 1)
    assert_true(
      seen[0].contains("\"thinking\":{\"type\":\"disabled\"}"),
      msg=seen[0],
    )
    assert_false(seen[0].contains("reasoning_effort"), msg=seen[0])
    let session = logged(ctx.session_path)
    assert_eq(session.context().thinking_level, Some("off"))
  })
}

// ── MCP through the gateway ────────────────────────────────────────────────

///|
/// A fake MCP server that echoes, so the driver test can reach a real child process.
///
/// Python because what is under test is the *routing* — model calls `mcp`, the driver hands it to a
/// connection, the connection's answer goes back to the model — and not a server. The script is
/// written per test for the reason `scratch` exists: the tests run concurrently.
fn mcp_echo_server_source() -> String {
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
    #|             "inputSchema": {"type": "object",
    #|                             "properties": {"text": {"type": "string"}},
    #|                             "required": ["text"]}}]}})
    #|    elif m == "tools/call":
    #|        args = (msg.get("params") or {}).get("arguments") or {}
    #|        send({"jsonrpc": "2.0", "id": msg.get("id"),
    #|              "result": {"content": [{"type": "text",
    #|                                      "text": "server said: " + str(args.get("text"))}]}})
    #|
  source
}

///|
async fn write_mcp_echo_server(dir : String) -> String {
  let relative = "\{dir}/echo_server.py"
  @platform.write_text(relative, mcp_echo_server_source())
  // Absolute, because the server is started with the session's cwd: a real config's `command`
  // points at an absolute path or a bare name on `PATH`, and a relative one would be resolved
  // against whatever directory the session happens to be in.
  @fs.realpath(relative)
}

///|
fn mcp_config_for(name : String, script : String) -> @core.McpConfig {
  Stdio({
    name,
    command: "python3",
    args: [script],
    env: [],
    description: "Says things back.",
  })
}

///|
/// Every `ToolResult` in the log, in order, as strings.
fn tool_results(session : @core.Session) -> Array[String] {
  let out : Array[String] = []
  for entry in session.context_entries() {
    match entry.kind {
      @core.Message(message~) =>
        match message {
          @core.ToolResult(result) => {
            let text = StringBuilder()
            for block in result.content {
              match block {
                @core.Text(value) => text.write_string(value)
                _ => ()
              }
            }
            out.push(text.to_string())
          }
          _ => ()
        }
      _ => ()
    }
  }
  out
}

///|
/// A turning point: the model asks the gateway for a server's tools, then calls one, and the
/// server's answer reaches the model.
///
/// This is the whole path in one test, and it is the reason the gateway is worth having: the model
/// sees only `mcp` in its schema, the driver routes by the name, the platform layer talks to a real
/// child process, and the result comes back as ordinary tool content. Nothing in between is
/// simulated.
async test "a turn reaches a server's tool through the gateway" {
  let dir = scratch("mcp-gateway")
  let script = write_mcp_echo_server(dir)
  let seen : Array[String] = []
  @async.with_task_group(group => {
    // The server is started the way the shell starts one: at session open, before the turn.
    let connection = match
      @platform.start_mcp_session(group, mcp_config_for("echo", script), dir) {
      Ok(connection) => connection
      Err(reason) => fail("the server should have started: \{reason}")
    }
    let responses : Array[String] = [
      // 1. Ask what the server has.
      tool_call_sse("mcp", "{\\\"server\\\":\\\"echo\\\"}"),
      // 2. Call the tool, with the arguments nested under `arguments`.
      tool_call_sse(
        "mcp", "{\\\"server\\\":\\\"echo\\\",\\\"tool\\\":\\\"say\\\",\\\"arguments\\\":{\\\"text\\\":\\\"hi\\\"}}",
      ),
      text_sse("done"),
    ]
    with_fake_model(responses, seen, async fn(base_url) {
      let path = "\{dir}/session.jsonl"
      let header : @core.SessionHeader = {
        id: "test",
        timestamp: @core.format_iso_utc(FIXED_TIME),
        cwd: dir,
        parent_session: None,
        version: Some(3),
      }
      @platform.create_session(path, header)
      // The tool set the turn is given: the built-ins plus the gateway, because the platform has a
      // connection to offer. Without the gateway in `tools`, `has_tool` would refuse the call — and
      // that refusal is what the next test checks.
      let tools = @platform.tools_with_mcp(@core.builtin_tools(), [connection])
      let ctx = @agent.AgentContext::new(
        session=@core.Session::new(header, []),
        session_path=path,
        cwd=dir,
        api_key="fixture-key",
        system_prompt=@core.build_system_prompt(
          dir,
          tools,
          servers=@platform.mcp_catalogs([connection]),
        ),
        tools~,
        base_url~,
        mcp=[connection],
      )
      let result = @agent.run_turn(ctx, "say hi on echo", FIXED_TIME)
      assert_eq(result.model_calls, 3)
      assert_eq(result.tool_calls, 2)
      assert_eq(result.replies, ["done"])
      // The catalog reached the model, so it could know the server exists at all.
      assert_true(seen[0].contains("## MCP servers"), msg=seen[0])
      assert_true(seen[0].contains("echo"), msg=seen[0])
      // And the description it asked for, with the schema, reached it before the call did.
      assert_true(seen[1].contains("Say it back."), msg=seen[1])
      assert_true(seen[1].contains("\"required\""), msg=seen[1])
      // The call's result: the server's own words, as ordinary tool content.
      assert_true(seen[2].contains("server said: hi"), msg=seen[2])

      let results = tool_results(logged(path))
      assert_eq(results.length(), 2)
      assert_true(results[0].contains("Say it back."), msg=results[0])
      assert_eq(results[1], "server said: hi")
    })
    connection.close()
  })
}

///|
/// The gateway is only in the request when a server is up, and a call to it with no server is told
/// what there is rather than quietly running something.
async test "with no servers the gateway is not declared and the call is refused" {
  let dir = scratch("mcp-none")
  let seen : Array[String] = []
  // No connections, so `tools_with_mcp` adds nothing and this is the plain built-in set.
  let tools = @platform.tools_with_mcp(@core.builtin_tools(), [])
  assert_false(@core.has_tool(tools, "mcp"))
  with_fake_model(
    [tool_call_sse("mcp", "{\\\"server\\\":\\\"echo\\\"}"), text_sse("done")],
    seen,
    async fn(base_url) {
      let path = "\{dir}/session.jsonl"
      let header : @core.SessionHeader = {
        id: "test",
        timestamp: @core.format_iso_utc(FIXED_TIME),
        cwd: dir,
        parent_session: None,
        version: Some(3),
      }
      @platform.create_session(path, header)
      let ctx = @agent.AgentContext::new(
        session=@core.Session::new(header, []),
        session_path=path,
        cwd=dir,
        api_key="fixture-key",
        system_prompt=@core.build_system_prompt(dir, tools),
        tools~,
        base_url~,
      )
      let result = @agent.run_turn(ctx, "use echo", FIXED_TIME)
      // A refused call is not a call that ran: the refusal is written where a result would have
      // been, and the count that says how many tools *executed* stays zero. That difference is the
      // point of enforcing the mode here rather than trusting the schema.
      assert_eq(result.tool_calls, 0)
      let results = tool_results(logged(path))
      assert_eq(results.length(), 1)
      assert_true(results[0].has_prefix("Refused:"), msg=results[0])
      assert_true(results[0].contains("`mcp`"), msg=results[0])
      // The request never carried the gateway, so the model was told there is no such tool.
      assert_false(seen[0].contains("\"name\":\"mcp\""), msg=seen[0])
    },
  )
}
