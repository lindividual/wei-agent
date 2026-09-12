///|
/// The wire protocol between the server and the browser.
///
/// It is deliberately tiny — four operations, all of which act on one element.
/// There is no state in it and no ordering requirement beyond the order the
/// frames arrive in, because the server is the only writer of the document.
///
/// The payload is JSON rather than raw HTML. SSE frames are newline-delimited and
/// HTML is full of newlines, so encoding the markup as a JSON string is what
/// keeps the frame structure from being broken by its own contents.

///|
pub(all) enum Patch {
  /// Append inside a container.
  Append(target~ : String, html~ : String)
  /// Replace an element with a new one.
  Replace(target~ : String, html~ : String)
  /// Replace an element's text content.
  ///
  /// Used while text is streaming. Re-parsing HTML on every delta would be wasted
  /// work, and a half-received markdown document renders wrongly anyway — `**bo`
  /// is not bold until the closing `**` arrives.
  SetText(target~ : String, text~ : String)
  /// Update the status line.
  Status(text~ : String)
} derive(Eq, Debug)

///|
pub fn Patch::to_json(self : Patch) -> Json {
  match self {
    Append(target~, html~) =>
      Json::object(
        Map([
          ("op", Json::string("append")),
          ("target", Json::string(target)),
          ("html", Json::string(html)),
        ]),
      )
    Replace(target~, html~) =>
      Json::object(
        Map([
          ("op", Json::string("replace")),
          ("target", Json::string(target)),
          ("html", Json::string(html)),
        ]),
      )
    SetText(target~, text~) =>
      Json::object(
        Map([
          ("op", Json::string("text")),
          ("target", Json::string(target)),
          ("text", Json::string(text)),
        ]),
      )
    Status(text~) =>
      Json::object(
        Map([("op", Json::string("status")), ("text", Json::string(text))]),
      )
  }
}

///|
/// Encode as one SSE frame.
pub fn Patch::to_sse(self : Patch) -> String {
  "event: patch\ndata: \{self.to_json().stringify()}\n\n"
}

///|
pub fn append_node(target : String, node : Node) -> Patch {
  Append(target~, html=node.render())
}

///|
pub fn replace_node(target : String, node : Node) -> Patch {
  Replace(target~, html=node.render())
}

// ── Streaming text ─────────────────────────────────────────────────────────

///|
/// Accumulates a streaming text block and says what to send.
///
/// The point of the buffer is to avoid two extremes: sending every delta (which
/// floods the connection with frames of a few bytes) and sending nothing until
/// the block ends (which is not streaming at all). Callers feed deltas and emit
/// whenever the buffer says the accumulated text is worth sending.
pub(all) struct StreamBuffer {
  /// Element the text is written into.
  id : String
  /// Everything received so far.
  mut text : String
  /// What was last sent, so an unchanged flush sends nothing.
  mut sent : String
  /// Characters accumulated since the last flush.
  mut pending : Int
  /// Flush once this many characters have piled up.
  threshold : Int
} derive(Eq, Debug)

///|
/// Count characters, not bytes.
///
/// `String::length()` is backend dependent — bytes natively, UTF-16 units in
/// JavaScript — so a threshold expressed with it would flush at different points
/// depending on which backend the renderer was compiled for.
fn char_count(value : String) -> Int {
  let mut count = 0
  for _ in value {
    count += 1
  }
  count
}

///|
pub fn StreamBuffer::new(id : String, threshold? : Int = 48) -> StreamBuffer {
  { id, text: "", sent: "", pending: 0, threshold, }
}

///|
/// Add a delta. Returns a patch when enough has accumulated to be worth a frame.
pub fn StreamBuffer::push(self : StreamBuffer, delta : String) -> Patch? {
  self.text = self.text + delta
  self.pending = self.pending + char_count(delta)
  if self.pending >= self.threshold {
    self.sent = self.text
    self.pending = 0
    return Some(SetText(target=self.id, text=self.text))
  }
  None
}

///|
/// Flush whatever is left, if anything. Used when the stream ends.
pub fn StreamBuffer::flush(self : StreamBuffer) -> Patch? {
  if self.text == self.sent {
    return None
  }
  self.sent = self.text
  self.pending = 0
  Some(SetText(target=self.id, text=self.text))
}
