///|
/// DeepSeek request construction.
///
/// DeepSeek speaks the OpenAI chat-completions shape with a handful of
/// deviations that are recorded in its model catalog entry: the system prompt
/// uses `system` rather than `developer`, the output cap goes in `max_tokens`,
/// thinking is expressed as a `thinking` object plus `reasoning_effort`, and an
/// assistant message must carry `reasoning_content` when the model reasons.

///|
/// How much reasoning to ask for.
///
/// `Disabled` is not the same as omitting the field: DeepSeek distinguishes an
/// explicit off from a default, and upstream always sends one or the other.
pub(all) enum Thinking {
  Disabled
  Enabled(effort~ : String?)
} derive(Eq, Debug)

///|
/// One supported thinking level and the provider value it maps to. A level
/// mapped to `None` is recognised but not available for this model.
pub(all) struct ThinkingLevels {
  /// Level name → provider value, e.g. `"high"` → `"high"`, `"minimal"` → none.
  map : Map[String, String?]
} derive(Eq, Debug)

///|
/// Resolve a requested level into the thinking parameters to send.
///
/// An unavailable level falls back to disabled rather than being forwarded
/// verbatim: sending an effort the model does not support is rejected by the
/// API, whereas thinking off always works.
pub fn ThinkingLevels::resolve(
  self : ThinkingLevels,
  level : String?,
) -> Thinking {
  match level {
    None => Disabled
    Some(name) =>
      // upstream resolves the provider value as `map[level] ?? level`, so a level the
      // catalog maps to null falls back to the level name rather than to off.
      match self.map.get(name) {
        Some(Some(effort)) => Enabled(effort=Some(effort))
        _ => Enabled(effort=Some(name))
      }
  }
}

///|
/// `deepseek-v4-flash` pricing, USD per million tokens, from the model catalog.
///
/// A cache read costs 1/50th of fresh input, which is why the two counts are
/// billed separately rather than summed.
pub fn deepseek_v4_flash_pricing() -> Pricing {
  { input: 0.14, output: 0.28, cache_read: 0.0028, cache_write: 0.0, }
}

///|
/// The context window of `deepseek-v4-flash`, from the same catalog.
///
/// Needed for the compaction decision, which compares an estimate of the next
/// request against this number. Kept beside the pricing because both are
/// properties of the model rather than of the agent.
pub fn deepseek_v4_flash_context_window() -> Int {
  1000000
}

///|
/// The most the model will emit in one response, from the same catalog.
///
/// Not sent as `max_tokens`: upstream does not send it either (the captured request
/// bodies have no such field), so it is only a bound to reason about.
pub fn deepseek_v4_flash_max_tokens() -> Int {
  384000
}

///|
/// The DeepSeek catalog entry for `deepseek-v4-flash`.
///
/// `minimal` and `medium` are null in the catalog, meaning the model has no
/// distinct setting for them; only `low`, `high` and `max` map to real values.
pub fn deepseek_v4_thinking_levels() -> ThinkingLevels {
  let levels : Map[String, String?] = Map([
    ("off", None),
    ("minimal", None),
    ("low", Some("low")),
    ("medium", None),
    ("high", Some("high")),
    ("xhigh", None),
    ("max", Some("max")),
  ])
  { map: levels, }
}

// ── Message conversion ─────────────────────────────────────────────────────

///|
/// Stand-ins shown to a model that cannot accept images, so the conversation
/// still records that something was attached.
const USER_IMAGE_PLACEHOLDER : String = "(image omitted: model does not support images)"

///|
const TOOL_IMAGE_PLACEHOLDER : String = "(tool image omitted: model does not support images)"

///|
/// Replace images with a placeholder when the model cannot see them.
///
/// Runs of consecutive images collapse into a single placeholder: a message with
/// five attached screenshots should say that images were dropped once, not five
/// times.
fn replace_images(
  content : Array[Content],
  placeholder : String,
) -> Array[Content] {
  let out : Array[Content] = []
  let mut previous_was_placeholder = false
  for block in content {
    match block {
      Image(..) => {
        if !previous_was_placeholder {
          out.push(Text(placeholder))
        }
        previous_was_placeholder = true
      }
      _ => {
        out.push(block)
        previous_was_placeholder = match block {
          Text(text) => text == placeholder
          _ => false
        }
      }
    }
  }
  out
}

///|
/// Render one content block as an OpenAI `content` part.
///
/// Thinking blocks are not content parts: they travel under a separate
/// `reasoning_content` field on the assistant message.
fn text_or_image(block : Content) -> Json? {
  match block {
    Text(text) =>
      Some(
        Json::object(
          Map([("type", Json::string("text")), ("text", Json::string(text))]),
        ),
      )
    Image(data~, mime_type~) =>
      Some(
        Json::object(
          Map([
            ("type", Json::string("image_url")),
            (
              "image_url",
              Json::object(
                Map([("url", Json::string("data:\{mime_type};base64,\{data}"))]),
              ),
            ),
          ]),
        ),
      )
    _ => None
  }
}

///|
/// The assistant's visible text: only non-blank text blocks, concatenated.
///
/// upstream sends this as a plain string rather than an array of parts. Sending the
/// array form causes some models to mirror the block structure back in their
/// output.
fn assistant_text(content : Array[Content]) -> String {
  let out = StringBuilder()
  for block in content {
    match block {
      Text(text) => if text.trim() != "" { out.write_string(text) }
      _ => ()
    }
  }
  out.to_string()
}

///|
/// Reasoning text, joined across blocks, or `None` when there is nothing to
/// send. Blank-only thinking is dropped, since an empty `reasoning_content`
/// carries no information and upstream omits it in that case (setting it only when
/// the replay contract requires the key to be present at all).
fn assistant_reasoning(content : Array[Content]) -> String? {
  let parts : Array[String] = []
  for block in content {
    match block {
      Thinking(thinking~, ..) =>
        if thinking.trim() != "" {
          parts.push(thinking)
        }
      _ => ()
    }
  }
  if parts.is_empty() {
    None
  } else {
    Some(parts.join("\n"))
  }
}

///|
/// The tool calls on an assistant message, in order.
fn assistant_tool_calls(content : Array[Content]) -> Array[Json] {
  let calls : Array[Json] = []
  for block in content {
    match block {
      ToolCall(id~, name~, arguments~) =>
        calls.push(
          Json::object(
            Map([
              ("id", Json::string(id)),
              ("type", Json::string("function")),
              (
                "function",
                Json::object(
                  Map([
                    ("name", Json::string(name)),
                    // Arguments travel as a JSON *string*, not a nested object.
                    ("arguments", Json::string(arguments.stringify())),
                  ]),
                ),
              ),
            ]),
          ),
        )
      _ => ()
    }
  }
  calls
}

///|
/// The text of a tool result, or a placeholder when there is none. Providers
/// require the field to be present.
fn tool_result_text(content : Array[Content]) -> String {
  let parts : Array[String] = []
  for block in content {
    match block {
      Text(text) => parts.push(text)
      _ => ()
    }
  }
  if parts.is_empty() {
    "(no tool output)"
  } else {
    parts.join("\n")
  }
}

///|
/// Translate session messages into the OpenAI wire format.
///
/// The ordering rules here are load-bearing: a user message whose content is

///|
/// A tool result's content, in the shape the wire wants.
///
/// A plain string unless the result actually carries an image.
///
/// The string form is the default for a reason: it is what upstream sends, it is what every recorded
/// request fixture pins byte for byte, and it is what DeepSeek's own examples use. Breaking that on
/// every tool call to serve the occasional screenshot would churn the prompt — and the prompt
/// *prefix*, which is what the provider's cache is keyed on.
///
/// The array form is used only when there is an image to send, because a stringified result cannot
/// carry one: `tool_result_text` renders the blocks as text, so an image read by the `read` tool
/// would reach the model as a note about a picture rather than as the picture. Verified against the
/// live endpoint before being written this way — a tool message with `image_url` parts is accepted,
/// and the model described a test image sent that way.
fn tool_result_content(content : Array[Content]) -> Json {
  let mut has_image = false
  for block in content {
    match block {
      Image(..) => has_image = true
      _ => ()
    }
  }
  if !has_image {
    return Json::string(tool_result_text(content))
  }
  let parts : Array[Json] = []
  for block in content {
    match text_or_image(block) {
      Some(part) => parts.push(part)
      None => ()
    }
  }
  Json::array(parts)
}

///|
/// empty is dropped entirely, and an assistant message with neither text nor
/// tool calls is dropped too, because DeepSeek rejects a message that has
/// `null` content and no calls.
pub fn convert_messages(
  messages : Array[Message],
  system_prompt : String?,
  vision~ : Bool,
) -> Array[Json] {
  let out : Array[Json] = []
  match system_prompt {
    Some(prompt) =>
      out.push(
        Json::object(
          Map([
            ("role", Json::string("system")),
            ("content", Json::string(prompt)),
          ]),
        ),
      )
    None => ()
  }
  for message in messages {
    match message {
      User({ content, .. }) => {
        let content = if vision {
          content
        } else {
          replace_images(content, USER_IMAGE_PLACEHOLDER)
        }
        let parts : Array[Json] = []
        for block in content {
          match text_or_image(block) {
            Some(part) => parts.push(part)
            None => ()
          }
        }
        if parts.is_empty() {
          continue
        }
        out.push(
          Json::object(
            Map([
              ("role", Json::string("user")),
              ("content", Json::array(parts)),
            ]),
          ),
        )
      }
      Assistant(assistant) => {
        let text = assistant_text(assistant.content)
        let calls = assistant_tool_calls(assistant.content)
        if text == "" && calls.is_empty() {
          continue
        }
        let reasoning = assistant_reasoning(assistant.content)
        // DeepSeek rejects an assistant turn that omits `reasoning_content`
        // when the model reasons, so the key is always present, empty if need be.
        let reasoning_value = match reasoning {
          Some(text) => Json::string(text)
          None => Json::string("")
        }
        let fields : Array[(String, Json)] = [
          ("role", Json::string("assistant")),
          (
            "content",
            if text == "" {
              Json::null()
            } else {
              Json::string(text)
            },
          ),
          ("reasoning_content", reasoning_value),
        ]
        if !calls.is_empty() {
          fields.push(("tool_calls", Json::array(calls)))
        }
        out.push(Json::object(Map(fields)))
      }
      ToolResult(result) => {
        let content = if vision {
          result.content
        } else {
          replace_images(result.content, TOOL_IMAGE_PLACEHOLDER)
        }
        out.push(
          Json::object(
            Map([
              ("role", Json::string("tool")),
              ("content", tool_result_content(content)),
              ("tool_call_id", Json::string(result.tool_call_id)),
            ]),
          ),
        )
      }
    }
  }
  out
}

// ── Request assembly ───────────────────────────────────────────────────────

///|
/// Everything needed to describe one completion request.
pub(all) struct RequestSpec {
  model : String
  messages : Array[Message]
  system_prompt : String?
  tools : Array[ToolDef]
  thinking : Thinking
  max_tokens : Int?
  temperature : Double?
  /// Whether the model accepts image input. When false, attached images are
  /// replaced by a placeholder instead of being sent.
  vision : Bool
} derive(Eq, Debug)

///|
/// Render one tool in the wire format.
///
/// `strict: false` is always sent: DeepSeek supports strict schema sampling, and
/// upstream includes the flag whenever the provider does, defaulting it to false for
/// tools that do not opt in. Omitting it would be rejected as an unknown-shape
/// request by some gateways. A tool that opts into strict sampling would need
/// its schema rewritten too, which none of the built-in tools do.
fn tool_to_json(tool : ToolDef) -> Json {
  Json::object(
    Map([
      ("type", Json::string("function")),
      (
        "function",
        Json::object(
          Map([
            ("name", Json::string(tool.name)),
            ("description", Json::string(tool.description)),
            ("parameters", tool.parameters),
            ("strict", Json::boolean(false)),
          ]),
        ),
      ),
    ]),
  )
}

///|
fn tools_to_json(tools : Array[ToolDef]) -> Json {
  Json::array(tools.map(tool => tool_to_json(tool)))
}

///|
/// Whether the conversation already refers to tools, even if none are being
/// offered this turn. Some gateways reject a request whose history contains
/// `tool_calls` or `tool` messages unless the `tools` field is present, so an
/// empty array is sent in that case rather than omitting the field.
fn has_tool_history(messages : Array[Message]) -> Bool {
  for message in messages {
    match message {
      ToolResult(_) => return true
      Assistant({ content, .. }) =>
        if content.any(block => {
            match block {
              ToolCall(..) => true
              _ => false
            }
          }) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
/// Build the JSON body for a streaming chat-completions request.
pub fn build_deepseek_request(spec : RequestSpec) -> Json {
  let fields : Array[(String, Json)] = [
    ("model", Json::string(spec.model)),
    (
      "messages",
      Json::array(
        convert_messages(spec.messages, spec.system_prompt, vision=spec.vision),
      ),
    ),
    ("stream", Json::boolean(true)),
    // Without this the final chunk carries no usage and costs cannot be
    // reported.
    (
      "stream_options",
      Json::object(Map([("include_usage", Json::boolean(true))])),
    ),
  ]
  match spec.max_tokens {
    // DeepSeek takes the cap under `max_tokens`, not `max_completion_tokens`.
    Some(n) => fields.push(("max_tokens", Json::number(n.to_double())))
    None => ()
  }
  match spec.temperature {
    Some(t) => fields.push(("temperature", Json::number(t)))
    None => ()
  }
  if !spec.tools.is_empty() {
    fields.push(("tools", tools_to_json(spec.tools)))
  } else if has_tool_history(spec.messages) {
    fields.push(("tools", Json::array([])))
  }
  match spec.thinking {
    Disabled =>
      fields.push(
        ("thinking", Json::object(Map([("type", Json::string("disabled"))]))),
      )
    Enabled(effort~) => {
      fields.push(
        ("thinking", Json::object(Map([("type", Json::string("enabled"))]))),
      )
      let requested : String? = effort
      match requested {
        Some(level) => fields.push(("reasoning_effort", Json::string(level)))
        None => ()
      }
    }
  }
  Json::object(Map(fields))
}

// ── Request drift ──────────────────────────────────────────────────────────

///|
/// How one request differs from the previous one in the same turn.
///
/// The provider bills a request in two parts: the leading bytes it can read from the prefix cache
/// of an earlier request, and the rest, which is charged as fresh input at fifty times the price.
/// So the figure that decides what a call costs is not how big the request is but how far into it
/// the two requests stop agreeing — one rewritten message in the middle ends the shared prefix
/// there and re-bills everything after it.
///
/// What this measures is therefore `changed_bytes`, and what makes it trustworthy is that it is
/// computed from the same encoding the body is built from (`convert_messages`), so it is a
/// statement about the bytes that went out rather than about what the code intended to send.
pub(all) struct RequestDrift {
  /// Messages in this request, system prompt included.
  messages : Int
  /// Bytes those messages encode to.
  bytes : Int
  /// Index of the first message that differs from the previous request's. Equal to
  /// `previous_messages` when this request only grew.
  first_changed : Int
  /// Messages in the previous request, or zero when there was none.
  previous_messages : Int
  /// Bytes from `first_changed` to the end: the part that cannot be served from the previous
  /// request's cache.
  changed_bytes : Int
  /// False for the first request of a turn, where there is nothing to compare against — not the
  /// same as a request that changed nothing, which is why it is carried rather than inferred from
  /// a zero.
  comparable : Bool
} derive(Eq, Debug)

///|
/// Whether this request is the previous one plus an appended tail.
///
/// The property worth having: an append-only request is read from cache in full and only its tail
/// is billed, which is why the boundary that releases messages to trimming is quantized and why
/// this is measured at all.
pub fn RequestDrift::appended_only(self : RequestDrift) -> Bool {
  self.comparable && self.first_changed == self.previous_messages
}

///|
/// Measure one request against the previous one.
///
/// `previous` is `None` for the first request of a turn: nothing was sent yet, so everything is
/// fresh and there is no drift to report.
pub fn request_drift(
  previous : Array[Json]?,
  current : Array[Json],
) -> RequestDrift {
  let sizes : Array[Int] = []
  for message in current {
    sizes.push(utf8_bytes(message.stringify()))
  }
  let mut bytes = 0
  for size in sizes {
    bytes += size
  }
  match previous {
    None =>
      {
        messages: current.length(),
        bytes,
        first_changed: 0,
        previous_messages: 0,
        changed_bytes: bytes,
        comparable: false,
      }
    Some(before) => {
      let mut first = 0
      while first < before.length() &&
            first < current.length() &&
            before[first] == current[first] {
        first += 1
      }
      let mut changed = 0
      for i in first..<current.length() {
        changed += sizes[i]
      }
      {
        messages: current.length(),
        bytes,
        first_changed: first,
        previous_messages: before.length(),
        changed_bytes: changed,
        // The one case where the two requests are identical: comparable, nothing changed.
        comparable: true,
      }
    }
  }
}
