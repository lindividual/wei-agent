///|
/// How big the next request will be.
///
/// The naive answer is to add up the bytes of everything the request would carry and divide by
/// four. That estimator is all we have before the first response comes back, and it is wrong in
/// two ways that matter, both of them measured against real sessions rather than assumed.
///
/// It is systematically low: over 23,280 real assistant responses, the estimate came to 83% of
/// the prompt tokens the provider actually billed, and on the largest contexts — where the
/// compaction decision is made — it never once overshot. Four bytes per token is the rate for
/// English prose; JSON tool arguments and CJK text carry far more tokens per byte, and a
/// conversation made of those is under-counted by a fifth.
///
/// And it counts only the conversation. The system prompt and the tool schemas are roughly 1,300
/// tokens on every single request and were not in the sum at all, which is why a conversation
/// holding one word "estimates" as one token while the request is over a thousand.
///
/// Both errors are avoidable, because the provider reports the true prompt size of every request
/// it answered, and that number is already stored on the assistant message it produced. So the
/// expensive part — the bulk of a long conversation — does not have to be estimated at all. The
/// last reported size is a known fact, and only what has been appended since then is unknown.
///
/// That is the whole idea here: anchor on the last real measurement, and estimate the delta.

///|
/// Where a pressure figure came from, so a reader can tell a measurement from a guess.
pub(all) enum PressureSource {
  /// Anchored on a prompt size the provider reported, plus an estimated delta.
  Provider
  /// The heuristic alone: no response in this conversation has reported a size yet.
  Estimated
} derive(Eq, Debug)

///|
/// What the next request is expected to cost, and how sure we are.
pub(all) struct ContextPressure {
  /// The best figure available: the last reported prompt size plus what has been added since.
  tokens : Int
  /// The heuristic's own answer for the whole conversation, for comparison. Kept because the
  /// two numbers disagreeing is the only way to notice the estimator drifting.
  estimated : Int
  source : PressureSource
} derive(Eq, Debug)

///|
/// Fixed tokens every request carries regardless of the conversation: the system prompt and the
/// tool schemas.
///
/// Counted because their absence is the largest single error in the heuristic — not because the
/// figure is precise, but because zero is definitely wrong. Anchoring makes it moot from the
/// second request onward, since the reported size includes it.
///
/// The estimate is of the text, so it misses the JSON framing around each schema. That is
/// deliberate: being close is the point, and the anchor supplies the exact figure as soon as the
/// provider answers once.
pub fn request_overhead_tokens(
  system_prompt : String,
  tools : Array[ToolDef],
) -> Int {
  let mut chars = system_prompt.length()
  for tool in tools {
    chars = chars +
      tool.name.length() +
      tool.description.length() +
      tool.parameters.stringify().length()
  }
  (chars + 3) / 4
}

///|
/// Estimate the next request's prompt size, anchored on the last size the provider reported.
///
/// `overhead` is `request_overhead_tokens` and is used only until a measurement exists.
///
/// The anchor is the last assistant message whose usage reports a billed prompt. Its own content
/// is part of the delta rather than of the anchor: the request that produced it carried
/// everything *before* it, so the message itself is something the next request adds.
pub fn context_pressure(
  messages : Array[ContextMessage],
  overhead : Int,
) -> ContextPressure {
  // The heuristic's answer for the whole conversation, computed in one pass alongside the
  // search for an anchor.
  let mut estimated = overhead
  for message in messages {
    estimated = estimated + estimate_tokens(message)
  }
  let mut anchor : Int? = None
  let mut anchor_tokens = 0
  let mut seen = 0
  for message in messages {
    match message {
      Assistant(assistant) => {
        let billed = assistant.usage.billed_input()
        if billed > 0 {
          // Recorded before this message's own content is counted: the request that produced it
          // did not contain it.
          anchor = Some(seen)
          anchor_tokens = billed
        }
      }
      _ => ()
    }
    seen = seen + 1
  }
  match anchor {
    None => { tokens: estimated, estimated, source: Estimated, }
    Some(index) => {
      // Everything from the anchored message onward is what the next request adds to a prompt
      // whose true size the provider already told us.
      let mut delta = 0
      for i in index..<messages.length() {
        delta = delta + estimate_tokens(messages[i])
      }
      { tokens: anchor_tokens + delta, estimated, source: Provider, }
    }
  }
}
