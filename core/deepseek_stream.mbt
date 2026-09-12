///|
/// DeepSeek streaming response parsing.
///
/// Input is the complete SSE body, output is one `AssistantMessage`. pi consumes
/// the stream incrementally, but the final state depends only on the accumulated
/// deltas, so parsing the whole body at once produces the same result while being
/// far easier to test against recorded fixtures.

// ── SSE framing ────────────────────────────────────────────────────────────

///|
priv enum SseEvent {
  /// A `data:` payload holding one JSON chunk.
  Payload(String)
  /// The `data: [DONE]` sentinel.
  Done
}

///|
/// Split an SSE body into events.
///
/// Per the SSE spec several `data:` lines can belong to one event and are joined
/// with newlines; a blank line ends it. OpenAI-style endpoints send one line per
/// event with a trailing blank line, which this handles as the degenerate case.
/// Other fields (`event:`, `id:`, `:` comments) are ignored, as are keep-alive
/// blank lines.
fn sse_events(body : String) -> Array[SseEvent] {
  let events : Array[SseEvent] = []
  let pending : Array[String] = []
  let mut saw_done = false
  for raw in body.split("\n") {
    let line = raw.trim()
    if line.is_empty() {
      flush_event(pending, saw_done, events)
      saw_done = false
      continue
    }
    if line.has_prefix("data:") {
      let payload = line[5:].trim_start()
      if payload == "[DONE]" {
        saw_done = true
      } else {
        pending.push(payload.to_owned())
      }
    }
  }
  flush_event(pending, saw_done, events)
  events
}

///|
fn flush_event(
  pending : Array[String],
  saw_done : Bool,
  events : Array[SseEvent],
) -> Unit {
  if saw_done {
    events.push(Done)
    pending.clear()
    return
  }
  if pending.is_empty() {
    return
  }
  events.push(Payload(pending.join("\n")))
  pending.clear()
}

// ── Accumulation ───────────────────────────────────────────────────────────

///|
/// A tool call being assembled. `arguments` arrives as a JSON string split
/// across many chunks, so it is buffered as text and parsed once at the end.
priv struct ToolAccum {
  mut id : String
  mut name : String
  mut args_text : String
  /// Index into `Accum::blocks` once the block has been materialised.
  block_at : Int
}

///|
priv struct Accum {
  /// The model id that was requested. A chunk naming a *different* model is
  /// recorded as `responseModel`; one naming the same model is not, because
  /// that carries no information.
  requested_model : String
  mut response_id : String?
  mut response_model : String?
  mut usage : Usage?
  mut stop_reason : StopReason
  mut raw_stop_reason : String?
  mut error_message : String?
  mut has_finish_reason : Bool
  /// Set when the stream is aborted by a malformed payload.
  mut failed : Bool
  /// Content blocks in first-appearance order, matching how pi emits them.
  blocks : Array[Content]
  /// Block index of the single text block, or -1.
  mut text_at : Int
  /// Block index of the single thinking block, or -1.
  mut thinking_at : Int
  tools : Array[ToolAccum]
  /// Stream `index` -> position in `tools`.
  tool_at : Map[Int, Int]
}

///|
fn Accum::new(requested_model : String) -> Accum {
  {
    requested_model,
    response_id: None,
    response_model: None,
    usage: None,
    stop_reason: Stop,
    raw_stop_reason: None,
    error_message: None,
    has_finish_reason: false,
    failed: false,
    blocks: [],
    text_at: -1,
    thinking_at: -1,
    tools: [],
    tool_at: Map([]),
  }
}

// ── Chunk decoding ─────────────────────────────────────────────────────────

///|
fn parse_json_or_none(text : String) -> Json? {
  try @json.parse(text) catch {
    _ => None
  } noraise {
    j => Some(j)
  }
}

///|
fn json_field(j : Json, key : String) -> Json? {
  match j {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
fn json_string_field(j : Json, key : String) -> String? {
  match json_field(j, key) {
    Some(String(s)) if s != "" => Some(s)
    _ => None
  }
}

///|
fn json_number_field(j : Json, key : String) -> Double? {
  match json_field(j, key) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// Read a token count, treating anything missing or non-numeric as zero. This
/// mirrors pi's `|| 0` handling: providers omit these fields freely and a missing
/// count is legitimately zero, not an error.
fn token_count(j : Json, key : String) -> Int {
  match json_number_field(j, key) {
    Some(n) => n.to_int()
    None => 0
  }
}

///|
/// Apply one decoded chunk to the accumulator.
fn Accum::absorb(self : Accum, chunk : Json) -> Unit {
  if self.response_id is None {
    self.response_id = json_string_field(chunk, "id")
  }
  match json_string_field(chunk, "model") {
    Some(m) =>
      if m != self.requested_model && self.response_model is None {
        self.response_model = Some(m)
      }
    None => ()
  }
  match json_field(chunk, "usage") {
    Some(usage) if usage is Object(_) => self.usage = Some(decode_usage(usage))
    _ => ()
  }
  let choices = match json_field(chunk, "choices") {
    Some(Array(a)) => a
    _ => return
  }
  if choices.is_empty() {
    return
  }
  let choice = choices[0]
  match json_field(choice, "finish_reason") {
    Some(String(reason)) => {
      self.raw_stop_reason = Some(reason)
      let (stop_reason, error_message) = map_stop_reason(reason)
      self.stop_reason = stop_reason
      match error_message {
        Some(msg) => self.error_message = Some(msg)
        None => ()
      }
      self.has_finish_reason = true
    }
    _ => ()
  }
  match json_field(choice, "delta") {
    Some(delta) => self.absorb_delta(delta)
    None => ()
  }
}

///|
fn Accum::absorb_delta(self : Accum, delta : Json) -> Unit {
  match json_string_field(delta, "content") {
    Some(text) => self.append_text(text)
    None => ()
  }
  // Several compatible endpoints report reasoning under different names. Take
  // the first non-empty one so a provider echoing two names is not counted twice.
  let reasoning_fields = ["reasoning_content", "reasoning", "reasoning_text"]
  for field in reasoning_fields {
    match json_string_field(delta, field) {
      Some(text) => {
        // The field the text arrived under becomes the block's signature: the
        // replay path reads it back to decide which field to send it in.
        self.append_thinking(text, field)
        break
      }
      None => ()
    }
  }
  match json_field(delta, "tool_calls") {
    Some(Array(calls)) =>
      for call in calls {
        self.absorb_tool_call(call)
      }
    _ => ()
  }
}

///|
fn Accum::append_text(self : Accum, text : String) -> Unit {
  if self.text_at < 0 {
    self.text_at = self.blocks.length()
    self.blocks.push(Text(""))
  }
  let i = self.text_at
  match self.blocks[i] {
    Text(existing) => self.blocks[i] = Text(existing + text)
    _ => ()
  }
}

///|
fn Accum::append_thinking(
  self : Accum,
  text : String,
  signature : String,
) -> Unit {
  if self.thinking_at < 0 {
    self.thinking_at = self.blocks.length()
    self.blocks.push(Thinking(thinking="", signature~))
  }
  let i = self.thinking_at
  match self.blocks[i] {
    Thinking(thinking~, signature~) =>
      self.blocks[i] = Thinking(thinking=thinking + text, signature~)
    _ => ()
  }
}

///|
/// Tool calls are keyed by the stream's `index` rather than by position in the
/// delta array: providers send them interleaved, and the same call reappears
/// across many chunks with only a fragment of `arguments` each time.
fn Accum::absorb_tool_call(self : Accum, call : Json) -> Unit {
  let stream_index = match json_number_field(call, "index") {
    Some(n) => n.to_int()
    None => 0
  }
  let slot = match self.tool_at.get(stream_index) {
    Some(existing) => existing
    None => {
      let at = self.blocks.length()
      self.blocks.push(
        ToolCall(id="", name="", arguments=Json::object(Map([]))),
      )
      self.tools.push({ id: "", name: "", args_text: "", block_at: at, })
      let slot = self.tools.length() - 1
      self.tool_at.set(stream_index, slot)
      slot
    }
  }
  let tool = self.tools[slot]
  match json_string_field(call, "id") {
    Some(new_id) => if tool.id == "" { tool.id = new_id }
    None => ()
  }
  match json_field(call, "function") {
    Some(func) => {
      match json_string_field(func, "name") {
        Some(new_name) => if tool.name == "" { tool.name = new_name }
        None => ()
      }
      match json_string_field(func, "arguments") {
        Some(fragment) => tool.args_text = tool.args_text + fragment
        None => ()
      }
    }
    None => ()
  }
}

///|
/// Materialise the accumulated tool calls into their blocks. Arguments are parsed
/// once here rather than on every delta: only the final text matters, and a
/// half-received JSON fragment is not worth repairing mid-stream.
fn Accum::finish_tool_calls(self : Accum) -> Unit {
  for tool in self.tools {
    let arguments = match parse_json_or_none(tool.args_text) {
      Some(j) => j
      // pi falls back to partial-JSON repair here; a non-object or unparsable
      // buffer is reported by the tool layer as a bad call, so an empty object
      // keeps the shape without inventing arguments.
      None => Json::object(Map([]))
    }
    self.blocks[tool.block_at] = ToolCall(
      id=tool.id,
      name=tool.name,
      arguments~,
    )
  }
}

///|
fn decode_usage(raw : Json) -> Usage {
  let prompt_tokens = token_count(raw, "prompt_tokens")
  let output = token_count(raw, "completion_tokens")
  let details = match json_field(raw, "prompt_tokens_details") {
    Some(d) => d
    None => Json::object(Map([]))
  }
  let cache_read = match json_number_field(details, "cached_tokens") {
    Some(n) => n.to_int()
    None => token_count(raw, "prompt_cache_hit_tokens")
  }
  let cache_write = token_count(details, "cache_write_tokens")
  // Cache hits are billed separately and are part of `prompt_tokens`, so the
  // fresh-input count is what remains.
  let fresh_input = prompt_tokens - cache_read - cache_write
  let input = if fresh_input < 0 { 0 } else { fresh_input }
  let completion_details = match json_field(raw, "completion_tokens_details") {
    Some(d) => d
    None => Json::object(Map([]))
  }
  let reasoning = match
    json_number_field(completion_details, "reasoning_tokens") {
    Some(n) => n.to_int()
    None => 0
  }
  {
    input,
    output,
    cache_read,
    cache_write,
    reasoning: Some(reasoning),
    total_tokens: input + output + cache_read + cache_write,
    // Cost is filled in by the caller once the model's price table is known.
    cost: {
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    },
  }
}

///|
fn map_stop_reason(reason : String) -> (StopReason, String?) {
  match reason {
    "stop" | "end" => (Stop, None)
    "length" => (Length, None)
    "function_call" | "tool_calls" => (ToolUse, None)
    "content_filter" => (Error, Some("Provider finish_reason: content_filter"))
    "network_error" => (Error, Some("Provider finish_reason: network_error"))
    other => (Error, Some("Provider finish_reason: \{other}"))
  }
}

// ── Entry point ────────────────────────────────────────────────────────────

///|
/// Parse a complete SSE response body into an assistant message.
///
/// Failure is reported through the message rather than by raising, because that
/// is what pi hands to the UI: a stream that dies mid-flight still carries the
/// partial content and whatever usage was already reported.
///
/// Two failure modes matter, and both are errors rather than something to paper
/// over. A payload that is not JSON aborts the stream where pi's JSON decoder
/// would throw. A stream that ends without `finish_reason` is rejected too, since
/// DeepSeek does report one and its absence means the response was truncated.
pub fn parse_deepseek_stream(
  body : String,
  api~ : String,
  provider~ : String,
  model~ : String,
  timestamp~ : Int64,
  pricing~ : Pricing,
) -> Message {
  let accum = Accum::new(model)
  for event in sse_events(body) {
    if accum.failed {
      break
    }
    match event {
      Done => ()
      Payload(text) =>
        match parse_json_or_none(text) {
          Some(chunk) => accum.absorb(chunk)
          None => {
            // The exact wording differs between JSON implementations, so only
            // the fact of the failure is reproduced here; pi surfaces V8's
            // message, which no other runtime can match byte for byte.
            accum.stop_reason = Error
            accum.error_message = Some("Invalid JSON in stream payload")
            accum.failed = true
          }
        }
    }
  }
  accum.finish_tool_calls()
  if !accum.has_finish_reason && !accum.failed {
    accum.stop_reason = Error
    accum.error_message = Some("Stream ended without finish_reason")
  }
  let final_usage = match accum.usage {
    Some(u) => u.with_cost(pricing)
    None => Usage::zero()
  }
  Assistant({
    content: accum.blocks,
    api,
    provider,
    model,
    usage: final_usage,
    stop_reason: accum.stop_reason,
    timestamp,
    response_id: accum.response_id,
    response_model: accum.response_model,
    raw_stop_reason: accum.raw_stop_reason,
    error_message: accum.error_message,
  })
}

// ── Incremental parsing ────────────────────────────────────────────────────
//
// The function above consumes a complete body, which is what the fixtures and
// the differential tests use: comparing a finished parse against pi's is how the
// rules get verified. Streaming needs the same rules applied as bytes arrive, so
// the parser below wraps the same accumulator.
//
// Having both is deliberate. The incremental path is checked by feeding it the
// same fixtures in chunks and asserting it produces exactly what the one-shot
// parse produced — so the streaming code cannot drift from the verified one.

///|
/// Something worth telling the UI about while a response is still arriving.
///
/// Only content, not bookkeeping: the caller renders text and reasoning as they
/// grow, and everything else (usage, ids, stop reason) is only meaningful once
/// the response is complete.
pub(all) enum StreamEvent {
  /// More assistant text.
  Text(delta~ : String)
  /// More reasoning.
  Thinking(delta~ : String)
} derive(Eq, Debug)

///|
/// Parses a DeepSeek SSE response incrementally.
pub struct StreamParser {
  priv accum : Accum
  /// Bytes after the last newline: a partial line, held until the rest arrives.
  priv mut pending_line : String
  /// `data:` payloads of the event currently being assembled, joined by newlines
  /// as the SSE spec requires.
  priv mut data : String
  /// Set once `data: [DONE]` is seen.
  priv mut done : Bool
  priv events : Array[StreamEvent]
  priv api : String
  priv provider : String
  priv model : String
  priv timestamp : Int64
  priv pricing : Pricing
}

///|
pub fn StreamParser::new(
  api~ : String,
  provider~ : String,
  model~ : String,
  timestamp~ : Int64,
  pricing~ : Pricing,
) -> StreamParser {
  {
    accum: Accum::new(model),
    pending_line: "",
    data: "",
    done: false,
    events: [],
    api,
    provider,
    model,
    timestamp,
    pricing,
  }
}

///|
/// Feed one chunk of bytes. Returns whatever became visible because of it.
///
/// A chunk may contain several events, part of one, or none; the parser keeps
/// whatever it cannot yet use.
pub fn StreamParser::feed(
  self : StreamParser,
  chunk : String,
) -> Array[StreamEvent] {
  self.events.clear()
  self.pending_line = self.pending_line + chunk
  let text = self.pending_line
  // Everything up to the last newline is complete lines; the rest is a partial
  // line to carry forward.
  let mut cut = -1
  let length = text.length()
  for i in 0..<length {
    if text[i].unsafe_to_char() == '\n' {
      cut = i
    }
  }
  if cut < 0 {
    // No complete line yet.
    return []
  }
  let complete = text[:cut].to_owned()
  self.pending_line = text[cut + 1:].to_owned()
  for raw in complete.split("\n") {
    self.consume_line(raw.to_owned())
  }
  // Hand back a copy: the parser will clear its own array on the next feed.
  let out : Array[StreamEvent] = []
  for event in self.events {
    out.push(event)
  }
  out
}

///|
fn StreamParser::consume_line(self : StreamParser, line : String) -> Unit {
  let trimmed = line.trim()
  if trimmed == "" {
    // A blank line ends the event.
    self.flush_event()
    return
  }
  if trimmed.has_prefix("data:") {
    let payload = trimmed[5:].trim_start().to_owned()
    if payload == "[DONE]" {
      self.done = true
      self.flush_event()
      return
    }
    if self.data != "" {
      self.data = self.data + "\n"
    }
    self.data = self.data + payload
  }
  // `event:`, `id:`, and `:` comments are ignored: DeepSeek uses none of them,
  // and a keep-alive comment must not be mistaken for content.
}

///|
fn StreamParser::flush_event(self : StreamParser) -> Unit {
  if self.accum.failed {
    // Already aborted by a malformed payload. The one-shot parser stops at that
    // point, so absorbing more here would make the two disagree.
    self.data = ""
    return
  }
  if self.data == "" {
    return
  }
  let payload = self.data
  self.data = ""
  match parse_json_or_none(payload) {
    None => {
      // Matches the one-shot parser: malformed JSON aborts the stream.
      self.accum.stop_reason = Error
      self.accum.error_message = Some("Invalid JSON in stream payload")
      self.accum.failed = true
    }
    Some(chunk) => {
      self.accum.absorb(chunk)
      self.emit_from_absorb(chunk)
    }
  }
}

///|
/// Work out what the chunk that was just absorbed should make visible.
///
/// The accumulator already folded the delta into its blocks; this re-reads the
/// chunk to report the delta itself, which is much simpler than diffing blocks.
fn StreamParser::emit_from_absorb(self : StreamParser, chunk : Json) -> Unit {
  let choices = match json_field(chunk, "choices") {
    Some(Array(items)) => items
    _ => return
  }
  if choices.is_empty() {
    return
  }
  let delta = match json_field(choices[0], "delta") {
    Some(d) => d
    None => return
  }
  match json_string_field(delta, "content") {
    Some(text) => self.events.push(Text(delta=text))
    None => ()
  }
  for field in ["reasoning_content", "reasoning", "reasoning_text"] {
    match json_string_field(delta, field) {
      Some(text) => {
        self.events.push(Thinking(delta=text))
        break
      }
      None => ()
    }
  }
}

///|
/// Whether `data: [DONE]` has been seen.
pub fn StreamParser::is_done(self : StreamParser) -> Bool {
  self.done
}

///|
/// Finish the stream and produce the message.
///
/// Call this even when the connection dropped: whatever arrived is what the
/// caller gets, which is the same behaviour as the one-shot parse and what makes
/// a cancelled request leave a usable transcript.
///
/// `aborted` says the caller stopped reading on purpose. A stream cut short that
/// way is recorded the way pi records it — `aborted` with "Operation aborted" —
/// rather than as a transport failure. The distinction is not cosmetic: on resume
/// an `error` assistant message reads as a broken connection, which invites
/// retrying work the user deliberately cancelled.
pub fn StreamParser::finish(
  self : StreamParser,
  aborted? : Bool = false,
) -> Message {
  self.accum.finish_tool_calls()
  if !self.accum.has_finish_reason && !self.accum.failed {
    if aborted {
      self.accum.stop_reason = Aborted
      self.accum.error_message = Some("Operation aborted")
    } else {
      self.accum.stop_reason = Error
      self.accum.error_message = Some("Stream ended without finish_reason")
    }
  }
  let usage = match self.accum.usage {
    Some(u) => u.with_cost(self.pricing)
    None => Usage::zero()
  }
  Assistant({
    content: self.accum.blocks,
    api: self.api,
    provider: self.provider,
    model: self.model,
    usage,
    stop_reason: self.accum.stop_reason,
    timestamp: self.timestamp,
    response_id: self.accum.response_id,
    response_model: self.accum.response_model,
    raw_stop_reason: self.accum.raw_stop_reason,
    error_message: self.accum.error_message,
  })
}
