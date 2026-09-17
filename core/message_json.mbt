///|
/// Raised when session JSON does not have the shape this build understands.
///
/// A malformed *known* message is an error rather than a silently skipped
/// entry: losing an assistant turn quietly would corrupt the context sent to
/// the model, which is worse than refusing to load the session.
pub suberror DecodeError {
  Malformed(String)
}

///|
/// The message already carries its own context (which field, what was
/// expected), so the rendering is just the message.
pub impl Show for DecodeError with fn output(self, logger) {
  match self {
    Malformed(msg) => logger.write_string(msg)
  }
}

// ── JSON construction ──────────────────────────────────────────────────────

///|
fn obj(fields : Array[(String, Json)]) -> Json {
  Json::object(Map(fields))
}

///|
/// Build an object while dropping absent keys. Field order follows the array,
/// which the callers keep aligned with upstream's own ordering.
fn obj_opt(fields : Array[(String, Json?)]) -> Json {
  let out : Array[(String, Json)] = []
  for entry in fields {
    let (k, v) = entry
    match v {
      Some(value) => out.push((k, value))
      None => ()
    }
  }
  Json::object(Map(out))
}

// ── JSON access ────────────────────────────────────────────────────────────

///|
fn req(j : Json, key : String) -> Json raise DecodeError {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(v) => v
        None => raise Malformed("missing field: \{key}")
      }
    _ => raise Malformed("not an object while reading \{key}")
  }
}

///|
fn opt(j : Json, key : String) -> Json? {
  match j {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
fn as_string(j : Json, what : String) -> String raise DecodeError {
  match j {
    String(s) => s
    _ => raise Malformed("\{what} must be a string")
  }
}

///|
fn as_double(j : Json, what : String) -> Double raise DecodeError {
  match j {
    Number(n, ..) => n
    _ => raise Malformed("\{what} must be a number")
  }
}

///|
fn as_int(j : Json, what : String) -> Int raise DecodeError {
  match j {
    Number(n, ..) => n.to_int()
    _ => raise Malformed("\{what} must be a number")
  }
}

///|
fn as_int64(j : Json, what : String) -> Int64 raise DecodeError {
  match j {
    Number(n, ..) => n.to_int64()
    _ => raise Malformed("\{what} must be a number")
  }
}

///|
fn as_bool(j : Json, what : String) -> Bool raise DecodeError {
  match j {
    True => true
    False => false
    _ => raise Malformed("\{what} must be a boolean")
  }
}

///|
fn as_array(j : Json, what : String) -> Array[Json] raise DecodeError {
  match j {
    Array(a) => a
    _ => raise Malformed("\{what} must be an array")
  }
}

///|
/// Absent optional fields decode to `None`; present-but-wrong-typed ones are
/// an error, matching how strict the required fields are.
fn opt_string(j : Json, key : String) -> String? raise DecodeError {
  match opt(j, key) {
    None => None
    Some(v) => Some(as_string(v, key))
  }
}

// ── Content ────────────────────────────────────────────────────────────────

///|
pub fn Content::to_json(self : Content) -> Json {
  match self {
    Text(text) =>
      obj([("type", Json::string("text")), ("text", Json::string(text))])
    Thinking(thinking~, signature~) =>
      obj([
        ("type", Json::string("thinking")),
        ("thinking", Json::string(thinking)),
        ("thinkingSignature", Json::string(signature)),
      ])
    ToolCall(id~, name~, arguments~) =>
      obj([
        ("type", Json::string("toolCall")),
        ("id", Json::string(id)),
        ("name", Json::string(name)),
        ("arguments", arguments),
      ])
    Image(data~, mime_type~) =>
      obj([
        ("type", Json::string("image")),
        ("data", Json::string(data)),
        ("mimeType", Json::string(mime_type)),
      ])
  }
}

///|
pub fn Content::from_json(j : Json) -> Content raise DecodeError {
  let kind = as_string(req(j, "type"), "content.type")
  match kind {
    "text" => Text(as_string(req(j, "text"), "content.text"))
    "thinking" =>
      Thinking(
        thinking=as_string(req(j, "thinking"), "content.thinking"),
        signature=as_string(
          req(j, "thinkingSignature"),
          "content.thinkingSignature",
        ),
      )
    "toolCall" =>
      ToolCall(
        id=as_string(req(j, "id"), "content.id"),
        name=as_string(req(j, "name"), "content.name"),
        arguments=req(j, "arguments"),
      )
    "image" =>
      Image(
        data=as_string(req(j, "data"), "content.data"),
        mime_type=as_string(req(j, "mimeType"), "content.mimeType"),
      )
    other => raise Malformed("unknown content type: \{other}")
  }
}

// ── Usage ──────────────────────────────────────────────────────────────────

///|
pub fn Cost::to_json(self : Cost) -> Json {
  obj([
    ("input", Json::number(self.input)),
    ("output", Json::number(self.output)),
    ("cacheRead", Json::number(self.cache_read)),
    ("cacheWrite", Json::number(self.cache_write)),
    ("total", Json::number(self.total)),
  ])
}

///|
pub fn Cost::from_json(j : Json) -> Cost raise DecodeError {
  {
    input: as_double(req(j, "input"), "cost.input"),
    output: as_double(req(j, "output"), "cost.output"),
    cache_read: as_double(req(j, "cacheRead"), "cost.cacheRead"),
    cache_write: as_double(req(j, "cacheWrite"), "cost.cacheWrite"),
    total: as_double(req(j, "total"), "cost.total"),
  }
}

///|
pub fn Usage::to_json(self : Usage) -> Json {
  obj_opt([
    ("input", Some(Json::number(self.input.to_double()))),
    ("output", Some(Json::number(self.output.to_double()))),
    ("cacheRead", Some(Json::number(self.cache_read.to_double()))),
    ("cacheWrite", Some(Json::number(self.cache_write.to_double()))),
    ("reasoning", self.reasoning.map(n => Json::number(n.to_double()))),
    ("totalTokens", Some(Json::number(self.total_tokens.to_double()))),
    ("cost", Some(self.cost.to_json())),
  ])
}

///|
pub fn Usage::from_json(j : Json) -> Usage raise DecodeError {
  {
    input: as_int(req(j, "input"), "usage.input"),
    output: as_int(req(j, "output"), "usage.output"),
    cache_read: as_int(req(j, "cacheRead"), "usage.cacheRead"),
    cache_write: as_int(req(j, "cacheWrite"), "usage.cacheWrite"),
    reasoning: match opt(j, "reasoning") {
      None => None
      Some(v) => Some(as_int(v, "usage.reasoning"))
    },
    total_tokens: as_int(req(j, "totalTokens"), "usage.totalTokens"),
    cost: Cost::from_json(req(j, "cost")),
  }
}

// ── StopReason ─────────────────────────────────────────────────────────────

///|
pub fn StopReason::to_json(self : StopReason) -> Json {
  match self {
    Stop => Json::string("stop")
    ToolUse => Json::string("toolUse")
    Length => Json::string("length")
    Error => Json::string("error")
    Aborted => Json::string("aborted")
    Unknown(s) => Json::string(s)
  }
}

///|
/// An unrecognised reason becomes `Unknown` rather than an error, so a newer
/// provider cannot make an old session unreadable.
pub fn StopReason::from_json(j : Json) -> StopReason raise DecodeError {
  match as_string(j, "stopReason") {
    "stop" => Stop
    "toolUse" => ToolUse
    "length" => Length
    "error" => Error
    "aborted" => Aborted
    other => Unknown(other)
  }
}

// ── Message ────────────────────────────────────────────────────────────────

///|
pub fn UserMessage::to_json(self : UserMessage) -> Json {
  obj([
    ("role", Json::string("user")),
    ("content", Json::array(self.content.map(c => c.to_json()))),
    ("timestamp", Json::number(self.timestamp.to_double())),
  ])
}

///|
pub fn AssistantMessage::to_json(self : AssistantMessage) -> Json {
  obj_opt([
    ("role", Some(Json::string("assistant"))),
    ("content", Some(Json::array(self.content.map(c => c.to_json())))),
    ("api", Some(Json::string(self.api))),
    ("provider", Some(Json::string(self.provider))),
    ("model", Some(Json::string(self.model))),
    ("usage", Some(self.usage.to_json())),
    ("stopReason", Some(self.stop_reason.to_json())),
    ("timestamp", Some(Json::number(self.timestamp.to_double()))),
    ("responseId", self.response_id.map(s => Json::string(s))),
    ("responseModel", self.response_model.map(s => Json::string(s))),
    ("rawStopReason", self.raw_stop_reason.map(s => Json::string(s))),
    ("errorMessage", self.error_message.map(s => Json::string(s))),
  ])
}

///|
pub fn ToolResultMessage::to_json(self : ToolResultMessage) -> Json {
  obj_opt([
    ("role", Some(Json::string("toolResult"))),
    ("toolCallId", Some(Json::string(self.tool_call_id))),
    ("toolName", Some(Json::string(self.tool_name))),
    ("content", Some(Json::array(self.content.map(c => c.to_json())))),
    ("details", self.details),
    ("isError", Some(Json::boolean(self.is_error))),
    ("timestamp", Some(Json::number(self.timestamp.to_double()))),
  ])
}

///|
pub fn Message::to_json(self : Message) -> Json {
  match self {
    User(m) => m.to_json()
    Assistant(m) => m.to_json()
    ToolResult(m) => m.to_json()
  }
}

///|
pub fn Message::from_json(j : Json) -> Message raise DecodeError {
  let role = as_string(req(j, "role"), "message.role")
  match role {
    "user" =>
      User({
        content: decode_content(req(j, "content")),
        timestamp: as_int64(req(j, "timestamp"), "message.timestamp"),
      })
    "assistant" =>
      Assistant({
        content: decode_content(req(j, "content")),
        api: as_string(req(j, "api"), "message.api"),
        provider: as_string(req(j, "provider"), "message.provider"),
        model: as_string(req(j, "model"), "message.model"),
        usage: Usage::from_json(req(j, "usage")),
        stop_reason: StopReason::from_json(req(j, "stopReason")),
        timestamp: as_int64(req(j, "timestamp"), "message.timestamp"),
        response_id: opt_string(j, "responseId"),
        response_model: opt_string(j, "responseModel"),
        raw_stop_reason: opt_string(j, "rawStopReason"),
        error_message: opt_string(j, "errorMessage"),
      })
    "toolResult" =>
      ToolResult({
        tool_call_id: as_string(req(j, "toolCallId"), "message.toolCallId"),
        tool_name: as_string(req(j, "toolName"), "message.toolName"),
        content: decode_content(req(j, "content")),
        is_error: as_bool(req(j, "isError"), "message.isError"),
        timestamp: as_int64(req(j, "timestamp"), "message.timestamp"),
        details: opt(j, "details"),
      })
    other => raise Malformed("unknown message role: \{other}")
  }
}

///|
fn decode_content(j : Json) -> Array[Content] raise DecodeError {
  as_array(j, "message.content").map(c => Content::from_json(c))
}
