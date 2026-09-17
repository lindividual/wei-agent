///|
/// Incremental parsing.
///
/// The value of this test is what it inherits: `parse_deepseek_stream` is checked
/// against the recorded parse on every fixture, so if the streaming parser
/// produces the same message from the same bytes, it inherits that verification
/// rather than needing its own set of expectations.
///
/// The chunk sizes matter as much as the content. A network delivers whatever it
/// feels like, so the parser has to be correct when a frame is split mid-JSON,
/// mid-escape, and mid-multi-byte-character.

///|
/// Split into pieces of at most `size` characters.
///
/// By character, not byte, so a chunk boundary never lands inside a UTF-8
/// sequence — a case the parser will not see in practice but which would make the
/// test failure confusing rather than informative.
fn chunks_of(source : String, size : Int) -> Array[String] {
  let chars : Array[Char] = []
  for c in source {
    chars.push(c)
  }
  let out : Array[String] = []
  let mut i = 0
  while i < chars.length() {
    let end = if i + size < chars.length() { i + size } else { chars.length() }
    let piece = StringBuilder()
    for j in i..<end {
      piece.write_char(chars[j])
    }
    out.push(piece.to_string())
    i = end
  }
  out
}

///|
fn parser() -> StreamParser {
  StreamParser::new(
    api="openai-completions",
    provider="deepseek",
    model="deepseek-v4-flash",
    timestamp=1700000000000L,
    pricing=deepseek_v4_flash_pricing(),
  )
}

///|
fn one_shot(body : String) -> Message {
  parse_deepseek_stream(
    body,
    api="openai-completions",
    provider="deepseek",
    model="deepseek-v4-flash",
    timestamp=1700000000000L,
    pricing=deepseek_v4_flash_pricing(),
  )
}

///|
/// The streaming parser must reproduce the one-shot result exactly, whatever the
/// chunk boundaries happen to be.
test "incremental parsing matches the one-shot parse" {
  for entry in sse_fixtures {
    let (name, _, body, _) = entry
    let expected = one_shot(body)
    for size in [1, 3, 17, 64, 4096] {
      let stream = parser()
      for chunk in chunks_of(body, size) {
        let _ = stream.feed(chunk)
      }
      let actual = stream.finish()
      if actual != expected {
        fail(
          "\{name} differs at chunk size \{size}\n  one-shot: \{expected.to_json().stringify()}\n  streamed: \{actual.to_json().stringify()}",
        )
      }
    }
  }
}

///|
/// Reasoning and text are reported as they arrive, not only at the end — which is
/// the entire point of the incremental path.
test "deltas are reported while the stream is open" {
  let body = "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"think \"},\"finish_reason\":null}]}\n\n" +
    "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"more\"},\"finish_reason\":null}]}\n\n" +
    "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello \"},\"finish_reason\":null}]}\n\n" +
    "data: {\"id\":\"c\",\"model\":\"deepseek-v4-flash\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"world\"},\"finish_reason\":\"stop\"}]}\n\n"
  let stream = parser()
  let seen : Array[StreamEvent] = []
  for chunk in chunks_of(body, 32) {
    for event in stream.feed(chunk) {
      seen.push(event)
    }
  }
  let _ = stream.finish()
  assert_eq(seen, [
    Thinking(delta="think "),
    Thinking(delta="more"),
    Text(delta="hello "),
    Text(delta="world"),
  ])
}

///|
/// A frame split across three calls is assembled once the last piece arrives.
test "a frame split across chunks is assembled" {
  let stream = parser()
  // The newline is what completes a line, so nothing is reported until it comes.
  assert_eq(stream.feed("data: {\"id\":\"c\",\"model\":\"m\",").length(), 0)
  assert_eq(stream.feed("\"choices\":[{\"index\":0,\"delta\":{").length(), 0)
  // The line is complete but the event is not: SSE ends an event at a blank
  // line, so nothing has been absorbed yet.
  assert_eq(
    stream.feed("\"content\":\"hi\"},\"finish_reason\":null}]}\n").length(),
    0,
  )
  // The blank line closes it.
  let events = stream.feed("\n")
  assert_eq(events.length(), 1)
  assert_eq(events, [Text(delta="hi")])
}

///|
/// `[DONE]` ends the stream but is not content.
test "the done sentinel produces no event" {
  let stream = parser()
  let events = stream.feed("data: [DONE]\n\n")
  assert_eq(events.length(), 0)
  assert_true(stream.is_done())
}

///|
/// A keep-alive comment must not be mistaken for a payload, which is exactly the
/// kind of thing a proxy injects.
test "comment lines are ignored" {
  let stream = parser()
  let events = stream.feed(
    ": keep-alive\n\ndata: {\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"stop\"}]}\n\n",
  )
  assert_eq(events, [Text(delta="x")])
}

///|
/// A stream cut mid-flight still yields what arrived, so a cancelled request
/// leaves something usable rather than nothing.
test "an interrupted stream still finishes" {
  let stream = parser()
  let _ = stream.feed(
    "data: {\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n",
  )
  let message = stream.finish()
  match message {
    Assistant({ content: [Text(text)], stop_reason: Error, .. }) => {
      assert_eq(text, "partial")
      // The reason is recorded: the stream stopped without saying it was done.
      assert_true(true)
    }
    _ => fail("expected the partial text to survive")
  }
}
