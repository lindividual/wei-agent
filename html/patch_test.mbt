///|
/// The patch protocol and the streaming buffer.

///|
/// Split a frame on newlines to inspect its structure.
fn frame_lines(frame : String) -> Array[String] {
  let out : Array[String] = []
  for line in frame.split("\n") {
    out.push(line.to_owned())
  }
  out
}

// ── Frames ─────────────────────────────────────────────────────────────────

///|
test "an append frame carries the operation and the markup" {
  let frame = append_node("transcript", el("div", children=[txt("hi")])).to_sse()
  assert_true(frame.has_prefix("event: patch\n"), msg=frame)
  assert_true(frame.contains("\"op\":\"append\""), msg=frame)
  assert_true(frame.contains("\"target\":\"transcript\""), msg=frame)
  assert_true(frame.contains("<div>hi</div>"), msg=frame)
  assert_true(frame.has_suffix("\n\n"), msg=frame)
}

///|
/// The reason the payload is JSON: SSE frames are newline-delimited, and markup
/// is full of newlines. Sent raw, a multi-line block would split one frame into
/// several malformed ones.
test "newlines in markup do not split the frame" {
  let patch = Patch::Append(
    target="t",
    html="<div>\nline one\nline two\n</div>",
  )
  let lines = frame_lines(patch.to_sse())
  // event line, data line, and the two trailing empties from the final blank line.
  assert_eq(lines.length(), 4, msg=patch.to_sse())
  assert_true(lines[0] == "event: patch", msg=lines[0])
  assert_true(lines[1].has_prefix("data: "), msg=lines[1])
  // The newlines survive as escapes rather than as real breaks.
  assert_true(lines[1].contains("\\n"), msg=lines[1])
}

///|
/// Quotes in markup must not terminate the JSON string early — which is the same
/// escaping requirement the renderer already satisfies, checked here at the
/// protocol layer.
test "quotes in markup survive the frame" {
  let patch = Patch::Append(target="t", html="<div class=\"a\">x</div>")
  let frame = patch.to_sse()
  assert_true(frame.contains("\\\"a\\\""), msg=frame)
  // Parsing it back gives the original markup.
  let payload = match @json.parse(frame_lines(frame)[1][6:]) {
    Object(fields) =>
      match fields.get("html") {
        Some(String(html)) => html
        _ => ""
      }
    _ => ""
  }
  assert_eq(payload, "<div class=\"a\">x</div>")
}

///|
test "each operation encodes its own shape" {
  assert_true(
    Patch::SetText(target="t", text="hi").to_sse().contains("\"op\":\"text\""),
  )
  assert_true(
    Patch::Status(text="working").to_sse().contains("\"op\":\"status\""),
  )
  assert_true(
    replace_node("t", el("div")).to_sse().contains("\"op\":\"replace\""),
  )
  // A status update has no target: it is about the page, not an element.
  assert_false(Patch::Status(text="x").to_sse().contains("\"target\""))
}

// ── Streaming buffer ───────────────────────────────────────────────────────

///|
/// Deltas below the threshold accumulate rather than each becoming a frame.
test "small deltas are batched" {
  let buffer = StreamBuffer::new("t", threshold=10)
  assert_true(buffer.push("abc") is None) // 3 characters
  assert_true(buffer.push("def") is None) // 6
  assert_eq(buffer.text, "abcdef")
  // Ten characters is the threshold, so this delta is the one that flushes.
  let patch = buffer.push("ghij")
  assert_true(patch is Some(_), msg="expected a flush at the threshold")
  match patch {
    Some(SetText(target~, text~)) => {
      assert_eq(target, "t")
      assert_eq(text, "abcdefghij")
    }
    Some(_) => fail("expected a SetText patch")
    None => fail("expected a patch")
  }
}

///|
/// Flushing the same content twice sends nothing the second time, so an idle
/// stream does not keep repainting.
test "a redundant flush sends nothing" {
  let buffer = StreamBuffer::new("t", threshold=1000)
  let _ = buffer.push("hello")
  let first = buffer.flush()
  assert_true(first is Some(_))
  assert_true(buffer.flush() is None, msg="second flush should be a no-op")
  // New content makes it worth sending again.
  let _ = buffer.push("!")
  assert_true(buffer.flush() is Some(_))
}

///|
/// The end-of-stream flush is what delivers the tail that never reached the
/// threshold — without it the last few characters would be lost.
test "the final flush delivers the tail" {
  let buffer = StreamBuffer::new("t", threshold=1000)
  let _ = buffer.push("the end")
  match buffer.flush() {
    Some(SetText(text~, ..)) => assert_eq(text, "the end")
    Some(_) => fail("expected a SetText patch")
    None => fail("expected the tail to be flushed")
  }
}

///|
/// Nothing received means nothing to send.
test "an empty buffer flushes to nothing" {
  let buffer = StreamBuffer::new("t")
  assert_true(buffer.flush() is None)
}

///|
/// The threshold counts characters, so a multi-byte delta is not charged three
/// times for being three bytes long.
test "the threshold counts characters" {
  let buffer = StreamBuffer::new("t", threshold=3)
  // Three CJK characters are nine UTF-8 bytes; by character count this is
  // exactly the threshold.
  let patch = buffer.push("中文字")
  assert_true(
    patch is Some(_),
    msg="three characters should reach a threshold of three",
  )
}
