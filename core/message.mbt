///|
/// One block inside a message's `content` array.
///
/// The shapes mirror pi's session file format exactly; `message_json.mbt` is
/// the only place that translates between these and JSON.
pub(all) enum Content {
  /// Plain text.
  Text(String)
  /// Reasoning output. `signature` is `"reasoning_content"` for DeepSeek, and
  /// must be sent back under that field name when the assistant message is
  /// replayed, or the API rejects the request.
  Thinking(thinking~ : String, signature~ : String)
  /// A tool call. `arguments` stays raw JSON: the tool decides its own shape,
  /// so there is nothing useful to type here.
  ToolCall(id~ : String, name~ : String, arguments~ : Json)
  /// A base64 encoded image.
  Image(data~ : String, mime_type~ : String)
} derive(Eq, Debug)

///|
/// Cost in USD, split by token category. `cache_read` is billed separately
/// (and far cheaper than `input`), so it cannot be folded into `input`.
pub(all) struct Cost {
  input : Double
  output : Double
  cache_read : Double
  cache_write : Double
  total : Double
} derive(Eq, Debug)

///|
/// Token accounting for one assistant message.
pub(all) struct Usage {
  input : Int
  output : Int
  cache_read : Int
  cache_write : Int
  /// Reasoning tokens, reported only by models that expose them.
  reasoning : Int?
  total_tokens : Int
  cost : Cost
} derive(Eq, Debug)

///|
/// Per-model token pricing in USD per million tokens, mirroring how pi stores
/// `model.cost`. Cache reads are billed separately and are far cheaper than
/// fresh input on providers that support prompt caching.
pub(all) struct Pricing {
  input : Double
  output : Double
  cache_read : Double
  cache_write : Double
} derive(Eq, Debug)

///|
/// Fill in `cost` from a price table.
///
/// pi supports tiered pricing (a second rate above a token threshold); DeepSeek
/// has a single tier, so the simpler form is implemented here. The tier case can
/// be added when a model actually needs it.
pub fn Usage::with_cost(self : Usage, pricing : Pricing) -> Usage {
  let per_million = 1000000.0
  let partial : Cost = {
    input: pricing.input / per_million * self.input.to_double(),
    output: pricing.output / per_million * self.output.to_double(),
    cache_read: pricing.cache_read / per_million * self.cache_read.to_double(),
    cache_write: pricing.cache_write /
    per_million *
    self.cache_write.to_double(),
    total: 0.0,
  }
  let total = partial.input +
    partial.output +
    partial.cache_read +
    partial.cache_write
  { ..self, cost: { ..partial, total, }, }
}

///|
/// Zero usage, used before any usage chunk arrives.
pub fn Usage::zero() -> Usage {
  {
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    // Absent rather than zero: before a provider reports usage there is no
    // reasoning count, and pi's own default omits the field entirely.
    reasoning: None,
    total_tokens: 0,
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
/// Why the model stopped generating.
pub(all) enum StopReason {
  Stop
  ToolUse
  Length
  Error
  Aborted
  /// A reason this build does not know about, preserved verbatim.
  Unknown(String)
} derive(Eq, Debug)

///|
pub impl Show for StopReason with fn output(self, logger) {
  match self {
    Stop => logger.write_string("stop")
    ToolUse => logger.write_string("toolUse")
    Length => logger.write_string("length")
    Error => logger.write_string("error")
    Aborted => logger.write_string("aborted")
    Unknown(reason) => logger.write_string(reason)
  }
}

///|
pub(all) struct UserMessage {
  content : Array[Content]
  timestamp : Int64
} derive(Eq, Debug)

///|
/// The optional fields are the ones pi itself writes conditionally: a message
/// that came from a cache hit has no `responseId`, an aborted turn has no
/// `responseModel`, and so on. They are kept optional so a round trip does not
/// invent fields.
pub(all) struct AssistantMessage {
  content : Array[Content]
  api : String
  provider : String
  model : String
  usage : Usage
  stop_reason : StopReason
  timestamp : Int64
  response_id : String?
  response_model : String?
  /// The provider's own stop token, e.g. `"tool_calls"`.
  raw_stop_reason : String?
  error_message : String?
} derive(Eq, Debug)

///|
/// `details` carries tool specific metadata (diffs, truncation info) that is
/// not sent to the model.
pub(all) struct ToolResultMessage {
  tool_call_id : String
  tool_name : String
  content : Array[Content]
  is_error : Bool
  timestamp : Int64
  details : Json?
} derive(Eq, Debug)

///|
pub(all) enum Message {
  User(UserMessage)
  Assistant(AssistantMessage)
  ToolResult(ToolResultMessage)
} derive(Eq, Debug)
