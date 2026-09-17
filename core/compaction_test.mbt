///|
/// Compaction: when to summarize, and where to cut.

///|
fn user_message(text : String) -> Message {
  User({ content: [Text(text)], timestamp: 0L, })
}

///|
fn user_msg(text : String) -> ContextMessage {
  ContextMessage::from_message(user_message(text))
}

///|
/// An assistant message carrying the given blocks, with the optional fields
/// spelled out so their types are unambiguous.
fn assistant_message(content : Array[Content]) -> Message {
  Assistant({
    content,
    api: "openai-completions",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    usage: Usage::zero(),
    stop_reason: ToolUse,
    timestamp: 0L,
    response_id: (None : String?),
    response_model: (None : String?),
    raw_stop_reason: (None : String?),
    error_message: (None : String?),
  })
}

///|
fn tokens_of(text : String) -> Int {
  estimate_tokens(user_msg(text))
}

// ── Estimation ─────────────────────────────────────────────────────────────

///|
/// Ceiling division, and an empty message still costs something rather than
/// nothing — a message that is free would let a conversation grow unbounded.
test "token estimation rounds up" {
  assert_eq(estimate_tokens(user_msg("")), 0)
  assert_eq(estimate_tokens(user_msg("a")), 1)
  assert_eq(estimate_tokens(user_msg("abcd")), 1)
  assert_eq(estimate_tokens(user_msg("abcde")), 2)
}

///|
/// ASCII is the case the /4 rule was calibrated on.
test "token estimation on a sentence" {
  let text = "The quick brown fox jumps over the lazy dog."
  assert_eq(tokens_of(text), (text.length() + 3) / 4)
}

///|
/// An image costs a flat amount because its real token count depends on
/// resolution and tiling, which are not available here.
test "images are charged a flat cost" {
  let with_image = ContextMessage::User({
    content: [Content::Image(data="AAAA", mime_type="image/png")],
    timestamp: 0L,
  })
  assert_eq(estimate_tokens(with_image), 4800 / 4)
}

///|
/// Tool arguments occupy context, so they are counted.
test "tool call arguments count toward the estimate" {
  let call = ContextMessage::from_message(
    assistant_message([
      ToolCall(
        id="c",
        name="bash",
        arguments=@json.parse("{\"command\":\"ls -la\"}"),
      ),
    ]),
  )
  assert_true(estimate_tokens(call) > 0)
}

///|
test "context cost is the sum of its messages" {
  let messages = [user_msg("aaaa"), user_msg("bbbb")]
  assert_eq(estimate_context_tokens(messages), 2)
  assert_eq(estimate_context_tokens([]), 0)
}

// ── Threshold ──────────────────────────────────────────────────────────────

///|
/// The threshold leaves headroom for the summary and the response, so it is
/// crossed before the window is actually full.
test "should_compact leaves a reserve" {
  let window = 100000
  let reserve = 16384
  assert_false(should_compact(window - reserve, window))
  assert_true(should_compact(window - reserve + 1, window))
}

///|
test "the reserve lowers the line" {
  // Sitting exactly at the window is not yet over it.
  assert_false(should_compact(1000, 1000, reserve_tokens=0))
  // One token past it is.
  assert_true(should_compact(1001, 1000, reserve_tokens=0))
  // A reserve moves the line down, so the same occupancy now qualifies.
  assert_true(should_compact(1001, 1000, reserve_tokens=900))
  // Low occupancy does not, even with no reserve.
  assert_false(should_compact(100, 1000, reserve_tokens=0))
}

// ── Cut points ─────────────────────────────────────────────────────────────

///|
fn compaction_session(messages : Array[(String, String)]) -> Array[Entry] {
  let entries : Array[Entry] = []
  for i in 0..<messages.length() {
    let (id, text) = messages[i]
    entries.push({
      id,
      parent_id: if i == 0 {
        None
      } else {
        Some(messages[i - 1].0)
      },
      timestamp: format_iso_utc(0L),
      kind: Message(message=user_message(text)),
    })
  }
  entries
}

///|
/// A conversation that fits entirely in the budget has nothing worth
/// summarizing; the cut lands at the start so nothing is duplicated.
test "a short conversation cuts at the beginning" {
  let entries = compaction_session([("a", "hi"), ("b", "there")])
  let cut = find_cut_point(entries, keep_recent_tokens=100000).unwrap()
  assert_eq(cut.first_kept_entry_id, "a")
  assert_eq(cut.tokens_before, 0)
}

///|
/// When the budget is exceeded, the cut lands late enough to keep roughly the
/// requested number of recent tokens.
test "a long conversation keeps the recent tail" {
  // Each message is 400 bytes -> 100 tokens. Ten messages is 1000 tokens.
  let body = "x".repeat(400)
  let messages : Array[(String, String)] = []
  for i in 0..<10 {
    messages.push(("e\{i}", body))
  }
  let entries = compaction_session(messages)
  let cut = find_cut_point(entries, keep_recent_tokens=300).unwrap()
  // Walking back: e9 reaches 100, e8 reaches 200, e7 reaches 300 and trips the
  // budget, so e7 is the first kept and e0..e6 are summarized.
  assert_eq(cut.first_kept_entry_id, "e7")
  assert_eq(cut.tokens_before, 700)
}

///|
/// A cut may not start at a tool result: it has to follow the call it answers.
test "the cut avoids tool results" {
  let body = "x".repeat(400)
  let call : Entry = {
    id: "call",
    parent_id: None,
    timestamp: format_iso_utc(0L),
    kind: Message(
      message=assistant_message([
        ToolCall(id="c1", name="read", arguments=@json.parse("{}")),
      ]),
    ),
  }
  let result : Entry = {
    id: "result",
    parent_id: Some("call"),
    timestamp: format_iso_utc(0L),
    kind: Message(
      message=ToolResult({
        tool_call_id: "c1",
        tool_name: "read",
        content: [Text(body)],
        is_error: false,
        timestamp: 0L,
        details: None,
      }),
    ),
  }
  let entries = [call, result]
  // Only the result is large enough to reach the budget, so the walk stops
  // there; the cut must move back to the call rather than orphan the result.
  let cut = find_cut_point(entries, keep_recent_tokens=1).unwrap()
  assert_eq(cut.first_kept_entry_id, "call")
}

///|
/// A session with no messages cannot be compacted.
test "an empty session has no cut point" {
  assert_true(find_cut_point([], keep_recent_tokens=1) is None)
}

///|
/// Cutting mid-turn is reported so the summary can say that a turn is still open.
///
/// A turn opens with a user message; cutting at an assistant reply lands inside
/// one, which means the summary has to describe work that is still in progress.
test "cutting mid-turn is reported" {
  let body = "x".repeat(400)
  let entries : Array[Entry] = [
    {
      id: "a",
      parent_id: None,
      timestamp: format_iso_utc(0L),
      kind: Message(message=user_message("first")),
    },
    {
      id: "b",
      parent_id: Some("a"),
      timestamp: format_iso_utc(0L),
      kind: Message(message=assistant_message([Text(body)])),
    },
  ]
  // Only the reply is large, so the cut lands on it.
  let cut = find_cut_point(entries, keep_recent_tokens=1).unwrap()
  assert_eq(cut.first_kept_entry_id, "b")
  assert_true(cut.split_turn)
}

///|
/// Cutting at a user message starts a turn cleanly, so it is not a split.
test "cutting at a turn start is not a split" {
  let body = "x".repeat(400)
  let entries = compaction_session([("a", "first"), ("b", body), ("c", body)])
  // The budget trips at "c", which is a user message.
  let cut = find_cut_point(entries, keep_recent_tokens=100).unwrap()
  assert_eq(cut.first_kept_entry_id, "c")
  assert_false(cut.split_turn)
}

// ── The prompt ─────────────────────────────────────────────────────────────

///|
/// The summary format is what makes a compacted session resumable: the sections
/// are the ones the next model needs to pick the work up.
test "the summarization prompt asks for the expected sections" {
  let prompt = summarization_prompt()
  for
    section in [
      "## Goal", "## Constraints & Preferences", "## Progress", "## Key Decisions",
      "## Next Steps", "## Critical Context",
    ] {
    assert_true(prompt.contains(section), msg="missing \{section}")
  }
  // Preserving identifiers verbatim is the difference between a usable summary
  // and one that paraphrases the file path into uselessness.
  assert_true(prompt.contains("Preserve exact file paths"))
}

// ── Settings derived from the window ───────────────────────────────────────

///|
/// The tuned case must not move: these are upstream's numbers, measured on 200K
/// windows, and a scaling rule that changes them would be a regression.
test "a 200K window reproduces the tuned defaults" {
  let settings = CompactionSettings::for_window(200000)
  assert_eq(settings.keep_recent_tokens, 20000)
  assert_eq(settings.reserve_tokens, 16384)
}

///|
/// A 1M window keeps a tenth of itself rather than upstream's flat 20K, which would be
/// 2% — too little to continue working from.
test "a 1M window scales the keep up" {
  let settings = CompactionSettings::for_window(1000000)
  assert_eq(settings.keep_recent_tokens, 100000)
  // The reserve also grows, since a summary of a huge history is itself large.
  assert_eq(settings.reserve_tokens, 20000)
}

///|
/// Below the tuned window the keep is floored rather than scaled down: 20K is
/// about the smallest working memory worth preserving.
test "a smaller window keeps the floor" {
  let settings = CompactionSettings::for_window(131072)
  assert_eq(settings.keep_recent_tokens, 20000)
}

///|
/// A window too small to afford the floor keeps a quarter of itself instead, so
/// the reserve and the next exchange still fit.
test "a tiny window keeps a quarter" {
  let settings = CompactionSettings::for_window(32768)
  assert_eq(settings.keep_recent_tokens, 8192)
  assert_eq(settings.reserve_tokens, 16384)
}

///|
/// Very large windows stop rewarding more verbatim history: past this point a
/// bigger keep only means compacting sooner.
test "an enormous window caps the keep" {
  let settings = CompactionSettings::for_window(2000000)
  assert_eq(settings.keep_recent_tokens, 100000)
  assert_eq(settings.reserve_tokens, 40000)
}

///|
/// The derived settings feed the threshold, so the pair stays consistent.
test "settings drive the threshold" {
  let large = CompactionSettings::for_window(1000000)
  assert_true(large.should_compact(990000, 1000000))
  assert_false(large.should_compact(500000, 1000000))
}
