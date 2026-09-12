///|
/// Compaction: deciding when a conversation has outgrown its context window,
/// where to cut it, and what to tell the model about the part being dropped.
///
/// Only the decision and the prompt live here. Producing a summary means calling
/// a model, which is the driver's job — this module answers "should we, and from
/// where", so those questions are testable without a model or a clock.
///
/// This is the minimal version: one summary of everything before the cut. pi also
/// retries a failed summarization call, and dsh additionally prunes oversized tool
/// output before summarizing so there is less to condense. Neither is needed to
/// make long sessions work.

///|
/// Headroom left below the context window. Summarizing right at the limit would
/// leave no room for the summary itself plus the response.
pub fn default_reserve_tokens() -> Int {
  16384
}

///|
/// How much recent conversation to keep verbatim. Older material is summarized,
/// but the last stretch stays exact because it is what the next turn builds on.
pub fn default_keep_recent_tokens() -> Int {
  20000
}

///|
/// The two knobs, together, because they only make sense as a pair: the reserve
/// decides when to compact and the keep decides how much survives.
pub(all) struct CompactionSettings {
  reserve_tokens : Int
  keep_recent_tokens : Int
} derive(Eq, Debug)

///|
/// Derive settings from the model's context window.
///
/// pi uses fixed values — 16,384 and 20,000 — which were tuned on 200K windows.
/// Applied to a 1M-token window those numbers keep only 2% of the conversation
/// verbatim, so a compaction throws away history it could have afforded to keep.
///
/// Scaling the keep with the window fixes that while leaving the 200K case
/// untouched, so the tuned behaviour is preserved where it was measured.
pub fn CompactionSettings::for_window(
  context_window : Int,
) -> CompactionSettings {
  // A tenth of the window is the working memory worth preserving.
  let scaled = context_window / 10
  // Never more than a quarter: the summary and the next exchange have to fit in
  // whatever is left, and the point of compacting is to make room.
  let affordable = context_window / 4
  // pi's value becomes the floor where the window can afford it, and the ceiling
  // where it cannot — a 32K window cannot spare 20K for history.
  let floor = if affordable < 20000 { affordable } else { 20000 }
  let keep = if scaled < floor {
    floor
  } else if scaled > 100000 {
    // Past this, more verbatim history stops buying anything: the model has to
    // re-read files either way, and a larger keep just means compacting sooner.
    100000
  } else {
    scaled
  }
  // The reserve has to cover the summary's own output plus the next exchange.
  let reserve = if context_window / 50 < 16384 {
    16384
  } else {
    context_window / 50
  }
  { reserve_tokens: reserve, keep_recent_tokens: keep, }
}

///|
/// Whether the conversation has grown past the point where summarizing is worth
/// it, using settings derived from this model's window.
pub fn CompactionSettings::should_compact(
  self : CompactionSettings,
  context_tokens : Int,
  context_window : Int,
) -> Bool {
  should_compact(
    context_tokens,
    context_window,
    reserve_tokens=self.reserve_tokens,
  )
}

///|
/// What a summarization prompt is asked to produce. Structured rather than free
/// prose so the next model can find the parts it needs.
///
/// Copied from pi: the section list is the difference between a summary that
/// keeps file paths and error messages and one that says "we discussed the code".
pub fn summarization_prompt() -> String {
  "The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.\n\nUse this EXACT format:\n\n## Goal\n[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]\n\n## Constraints & Preferences\n- [Any constraints, preferences, or requirements mentioned by user]\n- [Or \"(none)\" if none were mentioned]\n\n## Progress\n### Done\n- [x] [Completed tasks/changes]\n\n### In Progress\n- [ ] [Current work]\n\n### Blocked\n- [Issues preventing progress, if any]\n\n## Key Decisions\n- **[Decision]**: [Brief rationale]\n\n## Next Steps\n1. [Ordered list of what should happen next]\n\n## Critical Context\n- [Any data, examples, or references needed to continue]\n- [Or \"(none)\" if not applicable]\n\nKeep each section concise. Preserve exact file paths, function names, and error messages."
}

// ── Estimation ─────────────────────────────────────────────────────────────

///|
/// Approximate token cost of an image attachment, from pi. Images are counted by
/// a flat figure because the real cost depends on resolution and tiling.
fn estimated_image_chars() -> Int {
  4800
}

///|
/// Character count of a content list.
///
/// Measured in UTF-8 bytes rather than `String::length()`, which means different
/// things on different backends (UTF-8 bytes natively, UTF-16 code units in
/// JavaScript). A count that changes with the backend would make the compaction
/// threshold back-end dependent, and core has to behave identically everywhere.
fn content_chars(content : Array[Content]) -> Int {
  let mut chars = 0
  for block in content {
    match block {
      Text(text) => chars += utf8_bytes(text)
      Image(..) => chars += estimated_image_chars()
      // Thinking is generated but still occupies context on replay.
      Thinking(thinking~, ..) => chars += utf8_bytes(thinking)
      ToolCall(name~, arguments~, ..) =>
        chars += utf8_bytes(name) + utf8_bytes(arguments.stringify())
    }
  }
  chars
}

///|
fn utf8_bytes(text : String) -> Int {
  @utf8.encode(text).length()
}

///|
/// Estimate the token cost of one context message.
///
/// Characters divided by four, which is pi's rule. It is a heuristic, not a
/// tokenizer: it over-counts ASCII slightly and under-counts CJK, because three
/// UTF-8 bytes stand for one character there. That is acceptable for a threshold
/// with sixteen thousand tokens of headroom — the question being answered is
/// "roughly how full is the window", not "how many tokens exactly".
pub fn estimate_tokens(message : ContextMessage) -> Int {
  let chars = match message {
    User(m) => content_chars(m.content)
    Assistant(m) => content_chars(m.content)
    ToolResult(m) => content_chars(m.content)
    CompactionSummary(summary~, ..) => utf8_bytes(summary)
    BranchSummary(summary~, ..) => utf8_bytes(summary)
    Custom(content~, ..) => utf8_bytes(content.stringify())
  }
  // Ceiling division, so a short message still costs at least one token.
  (chars + 3) / 4
}

///|
/// Total estimated cost of a conversation.
pub fn estimate_context_tokens(messages : Array[ContextMessage]) -> Int {
  let mut total = 0
  for message in messages {
    total += estimate_tokens(message)
  }
  total
}

///|
/// Whether the conversation has grown past the point where summarizing is worth
/// it. The comparison is against the window minus a reserve, not the window
/// itself.
pub fn should_compact(
  context_tokens : Int,
  context_window : Int,
  reserve_tokens? : Int = 16384,
) -> Bool {
  context_tokens > context_window - reserve_tokens
}

// ── Cut points ─────────────────────────────────────────────────────────────

///|
/// Whether a cut may start at this message.
///
/// A tool result may not: it has to follow the call it answers, or the transcript
/// stops making sense.
fn is_cut_point(message : ContextMessage) -> Bool {
  match message {
    ToolResult(_) => false
    _ => true
  }
}

///|
/// Whether this message opens a turn.
fn is_turn_start(message : ContextMessage) -> Bool {
  match message {
    User(_) => true
    _ => false
  }
}

///|
/// Where a compaction should start keeping.
pub(all) struct CutPoint {
  /// Entry id to keep from; everything before it is summarized.
  first_kept_entry_id : String
  /// Number of tokens being summarized away, for the record.
  tokens_before : Int
  /// True when the cut lands mid-turn, which means the summary has to describe a
  /// turn that is still in progress.
  split_turn : Bool
} derive(Eq, Debug)

///|
/// Choose where to cut so that roughly `keep_recent_tokens` of recent
/// conversation survives verbatim.
///
/// Walks backwards accumulating cost until the budget is met, then cuts at the
/// nearest valid point at or after that one. Returns `None` when there is nothing
/// worth compacting, which is what stops an empty or tiny session from producing
/// a summary of itself.
pub fn find_cut_point(
  entries : Array[Entry],
  keep_recent_tokens? : Int = 20000,
) -> CutPoint? {
  // Only message entries contribute to the conversation.
  let visible : Array[Int] = []
  for i in 0..<entries.length() {
    if entries[i].kind is Message(..) {
      visible.push(i)
    }
  }
  if visible.is_empty() {
    return None
  }

  let mut accumulated = 0
  let mut chosen = visible[0]
  let mut found = false
  for back in 0..<visible.length() {
    let index = visible[visible.length() - 1 - back]
    let entry = entries[index]
    let message = match entry.kind {
      Message(message~) => message
      _ => continue
    }
    accumulated += estimate_tokens(ContextMessage::from_message(message))
    if accumulated >= keep_recent_tokens {
      // Cut at the first valid point at or after here.
      for candidate in visible {
        if candidate >= index {
          let entry_at = entries[candidate]
          let is_valid = match entry_at.kind {
            Message(message~) =>
              is_cut_point(ContextMessage::from_message(message))
            _ => false
          }
          if is_valid {
            chosen = candidate
            found = true
            break
          }
        }
      }
      break
    }
  }
  if !found {
    // The whole conversation fits in the budget: cut at the start, so the summary
    // covers everything and nothing is kept twice.
    chosen = visible[0]
  }

  let chosen_entry = entries[chosen]
  let at_turn_start = match chosen_entry.kind {
    Message(message~) => is_turn_start(ContextMessage::from_message(message))
    _ => false
  }
  // How much is being summarized away: everything before the cut.
  let mut tokens_before = 0
  for i in 0..<chosen {
    match entries[i].kind {
      Message(message~) =>
        tokens_before += estimate_tokens(ContextMessage::from_message(message))
      _ => ()
    }
  }
  Some({
    first_kept_entry_id: chosen_entry.id,
    tokens_before,
    split_turn: !at_turn_start,
  })
}
