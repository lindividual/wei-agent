///|
/// Trimming the context before it needs compacting.
///
/// Measured against real sessions, half of all context is tool output — `read`
/// alone is 30% — and another fifth is reasoning. Both have a short useful life:
/// a file read informs one decision and then sits in the window being re-sent on
/// every subsequent turn.
///
/// This runs as a projection, not as an edit: the session keeps every byte, and
/// only what is handed to the model is reduced. That makes it reversible, which
/// compaction is not, and it means a trimmed conversation can always be
/// reconstructed exactly by re-deriving without the policy.
///
/// Trimming before compacting is worth doing even though compacting would also
/// shrink the past, for three reasons: less noise makes a better summary,
/// trimming can remove the need to compact at all, and it costs no API call.

///|
/// What to leave alone.
pub(all) struct TrimPolicy {
  /// Messages at the end of the conversation that are left untouched. The model
  /// is working on these, so they must stay exact.
  recent_window : Int
  /// How many messages must pile up beyond the window before the trim boundary moves.
  ///
  /// One means the boundary follows the conversation message by message, which is the
  /// obvious behaviour and the wrong one: the request changes at that position on every
  /// turn, and a change at a position invalidates the provider's prefix cache from there
  /// to the end. Since the boundary sits just outside the window, that re-bills the newest
  /// and largest stretch of the conversation at full price on every request.
  ///
  /// A larger step quantizes the boundary, so it holds still for `advance_step - 1` turns
  /// and then moves in one jump. While it holds still the previous request is a prefix of
  /// the new one and almost nothing is re-billed. The price is that the window protects up
  /// to `advance_step - 1` messages more than `recent_window` asks for — content that is
  /// sent verbatim a little longer, at cache prices, instead of being re-sent fresh.
  advance_step : Int
  /// Tool output larger than this many bytes is trimmed once it falls outside the
  /// window. Small results are left alone: the bookkeeping would cost more than
  /// the bytes saved.
  tool_result_limit : Int
  /// Lines kept from the start and end of a trimmed result. The head usually
  /// carries the shape of the output and the tail the error or the last of it.
  head_lines : Int
  tail_lines : Int
  /// Whether reasoning outside the window is blanked.
  drop_old_thinking : Bool
} derive(Eq, Debug)

///|
/// Defaults chosen from measurement over real sessions.
///
/// The size threshold turns out to matter far more than the window: tightening
/// it from 8 KB to 4 KB saves another 4.4 points, while shrinking the window from
/// twenty messages to none saves only 1.6. That is because most of the recoverable
/// space sits in results that are large but not enormous, spread throughout the
/// conversation rather than concentrated in a few huge ones.
///
/// Four kilobytes is about a hundred lines — enough that a trimmed result still
/// shows the shape of a file, with the whole thing one `read` away.
pub fn TrimPolicy::default() -> TrimPolicy {
  {
    recent_window: 20,
    // Eight messages, so the request prefix is stable for seven turns out of eight. Chosen
    // against the window above: a step much smaller than the window still moves often relative
    // to it, and one much larger holds verbatim more of the conversation than trimming was
    // meant to leave alone. Under a cache read billed at a fiftieth of fresh input, the seven
    // stable turns pay for the eighth many times over.
    advance_step: 8,
    tool_result_limit: 4 * 1024,
    head_lines: 40,
    tail_lines: 20,
    drop_old_thinking: true,
  }
}

///|
/// A policy that does nothing, for comparing against an untrimmed derivation.
pub fn TrimPolicy::none() -> TrimPolicy {
  {
    recent_window: 0,
    advance_step: 1,
    tool_result_limit: 0,
    head_lines: 0,
    tail_lines: 0,
    drop_old_thinking: false,
  }
}

///|
fn trim_text(text : String, policy : TrimPolicy) -> String {
  if policy.tool_result_limit <= 0 ||
    utf8_bytes(text) <= policy.tool_result_limit {
    return text
  }
  let raw : Array[String] = []
  for line in text.split("\n") {
    raw.push(line.to_owned())
  }
  // A trailing newline produces a final empty element that is not a line of
  // content; counting it would inflate the total and shift the tail window.
  let lines = if raw.length() > 0 && raw[raw.length() - 1] == "" {
    raw[:raw.length() - 1]
  } else {
    raw
  }
  let total = lines.length()
  let kept = policy.head_lines + policy.tail_lines
  if total <= kept + 1 {
    // Fewer lines than the keep budget: the size is in line length, not count, so
    // dropping lines would either do nothing or gut the output.
    return text
  }
  let omitted = total - kept
  let out = StringBuilder()
  for i in 0..<policy.head_lines {
    out.write_string(lines[i])
    out.write_string("\n")
  }
  // Saying how much was dropped matters: without it the model reads a truncated
  // file as if it were the whole file.
  out.write_string(
    "\n… \{omitted} of \{total} lines omitted (\{utf8_bytes(text) / 1024} KB total), re-read the file if you need them …\n\n",
  )
  for i in (total - policy.tail_lines)..<total {
    out.write_string(lines[i])
    out.write_string("\n")
  }
  out.to_string()
}

///|
fn trim_content(
  content : Array[Content],
  policy : TrimPolicy,
) -> Array[Content] {
  content.map(block => {
    match block {
      Text(text) => Text(trim_text(text, policy))
      _ => block
    }
  })
}

///|
/// Blank a reasoning block while keeping its signature.
///
/// DeepSeek requires every assistant message to carry `reasoning_content`, but
/// only the field's presence is checked, not its contents. Emptying it satisfies
/// the API while dropping the tokens. The block itself stays so the transcript
/// keeps the shape it was recorded with.
fn blank_thinking(block : Content) -> Content {
  match block {
    Thinking(thinking~, signature~) =>
      if thinking == "" {
        // Already blank; leaving it alone keeps the equality check cheap.
        block
      } else {
        Thinking(thinking="", signature~)
      }
    _ => block
  }
}

///|
fn trim_message(
  message : ContextMessage,
  policy : TrimPolicy,
) -> ContextMessage {
  match message {
    ToolResult(result) =>
      ToolResult({ ..result, content: trim_content(result.content, policy), })
    Assistant(assistant) =>
      if policy.drop_old_thinking {
        Assistant({
          ..assistant,
          content: assistant.content.map(blank_thinking),
        })
      } else {
        message
      }
    // A user message is instructions, and a summary is already condensed. Neither
    // has anything safe to drop.
    _ => message
  }
}

///|
/// How many leading messages have been released to trimming.
///
/// The one place the boundary is computed, so the context that is sent and the report that
/// describes it cannot disagree.
///
/// The boundary is quantized to a multiple of `advance_step`, and that quantization is the
/// point rather than a detail. The request content at a position depends only on whether that
/// position is inside the cutoff, never on the cutoff's value, so holding the cutoff still for
/// a turn makes the previous request a byte-for-byte prefix of the new one. Moving it by one
/// every turn does the opposite: it changes the content at the boundary and shifts everything
/// after it, so the provider's cached prefix ends there and the whole recent window is billed
/// again.
fn trim_cutoff(length : Int, policy : TrimPolicy) -> Int {
  let released = if length > policy.recent_window {
    length - policy.recent_window
  } else {
    0
  }
  if policy.advance_step <= 1 {
    released
  } else {
    // Rounded down, so the window protects at most `advance_step - 1` messages more than it
    // asks for. Rounding up would release messages the window was meant to keep exact.
    released / policy.advance_step * policy.advance_step
  }
}

///|
/// Reduce old messages, leaving the most recent `recent_window` untouched.
///
/// Order is preserved and the array length never changes, so anything indexing
/// into the conversation keeps working.
///
/// Where trimming starts is `trim_cutoff`, which holds the boundary still between jumps so
/// that consecutive requests share a prefix. The cost of that is stated there.
pub fn trim_context(
  messages : Array[ContextMessage],
  policy : TrimPolicy,
) -> Array[ContextMessage] {
  let cutoff = trim_cutoff(messages.length(), policy)
  let out : Array[ContextMessage] = []
  for i in 0..<messages.length() {
    if i < cutoff {
      out.push(trim_message(messages[i], policy))
    } else {
      out.push(messages[i])
    }
  }
  out
}

///|
/// How much a policy would remove, for reporting and for deciding whether
/// trimming alone brought the conversation under the compaction threshold.
pub(all) struct TrimReport {
  before_tokens : Int
  after_tokens : Int
  tool_results_trimmed : Int
  thinking_blanked : Int
} derive(Eq, Debug)

///|
pub fn trim_context_reporting(
  messages : Array[ContextMessage],
  policy : TrimPolicy,
) -> (Array[ContextMessage], TrimReport) {
  let trimmed = trim_context(messages, policy)
  let cutoff = trim_cutoff(messages.length(), policy)
  let mut tool_results_trimmed = 0
  let mut thinking_blanked = 0
  for i in 0..<cutoff {
    match (messages[i], trimmed[i]) {
      (ToolResult(before), ToolResult(after)) =>
        if before.content != after.content {
          tool_results_trimmed += 1
        }
      (Assistant(before), Assistant(after)) =>
        if before.content != after.content {
          thinking_blanked += 1
        }
      _ => ()
    }
  }
  (
    trimmed,
    {
      before_tokens: estimate_context_tokens(messages),
      after_tokens: estimate_context_tokens(trimmed),
      tool_results_trimmed,
      thinking_blanked,
    },
  )
}

///|
/// Derive the context and trim it — what the driver does before every request.
///
/// One call rather than two because the order is not a choice: there is nothing
/// to trim until the conversation has been projected out of the log.
pub fn Session::prepared_context(
  self : Session,
  policy? : TrimPolicy,
) -> SessionContext {
  let resolved = match policy {
    Some(p) => p
    None => TrimPolicy::default()
  }
  let context = self.context()
  let trimmed = trim_context(context.messages, resolved)
  { ..context, messages: trimmed, }
}
