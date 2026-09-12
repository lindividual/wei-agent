///|
/// Session totals come from the log, so they survive a restart and cover the calls the
/// conversation no longer shows.
test "session usage sums replies and summarized calls" {
  let header : SessionHeader = {
    id: "s",
    timestamp: format_iso_utc(1700000000000L),
    cwd: "/tmp",
    parent_session: None,
    version: Some(3),
  }
  let first = usage_entry("a", None, 100, 20, 40, Some(7))
  let second = usage_entry("b", Some("a"), 200, 30, 50, None)
  // The compaction's own call cost money too, and the message it replaced stays in the total:
  // it was paid for even though the model no longer sees it.
  let compaction : Entry = {
    id: "c",
    parent_id: Some("b"),
    timestamp: format_iso_utc(1700000000000L),
    kind: Compaction(
      summary="earlier",
      first_kept_entry_id="b",
      tokens_before=1000,
      details=None,
      usage=Some(sample_usage(10, 5, 1, Some(2))),
      from_hook=Some(false),
    ),
  }
  let session = Session::new(header, [first, second, compaction])
  let total = session.usage()
  assert_eq(total.input, 310)
  assert_eq(total.output, 55)
  assert_eq(total.cache_read, 91)
  // Reasoning is summed where the field exists and skipped where it does not.
  assert_eq(total.reasoning, 9)
  // Two assistant replies plus the summarization call.
  assert_eq(total.replies, 3)
  assert_true(total.total_tokens > 0)
  assert_true(total.cost.total > 0.0)
}

///|
/// A session with nothing in it costs nothing.
test "an empty session has no usage" {
  let header : SessionHeader = {
    id: "s",
    timestamp: format_iso_utc(0L),
    cwd: "/tmp",
    parent_session: None,
    version: None,
  }
  let total = Session::new(header, []).usage()
  assert_eq(total.input, 0)
  assert_eq(total.replies, 0)
  assert_eq(total.cost.total, 0.0)
}

///|
fn sample_usage(
  input : Int,
  output : Int,
  cache_read : Int,
  reasoning : Int?,
) -> Usage {
  // Bound with an explicit type: a bare struct literal as a whole body is parsed as a block.
  let usage : Usage = {
    input,
    output,
    cache_read,
    cache_write: 0,
    reasoning,
    total_tokens: input + output + cache_read,
    cost: {
      input: input.to_double() / 1000000.0,
      output: output.to_double() / 1000000.0,
      cache_read: cache_read.to_double() / 1000000.0,
      cache_write: 0.0,
      total: (input + output + cache_read).to_double() / 1000000.0,
    },
  }
  usage
}

///|
fn usage_entry(
  id : String,
  parent : String?,
  input : Int,
  output : Int,
  cache_read : Int,
  reasoning : Int?,
) -> Entry {
  let entry : Entry = {
    id,
    parent_id: parent,
    timestamp: format_iso_utc(1700000000000L),
    kind: Message(
      message=Assistant({
        content: [Text("ok")],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: sample_usage(input, output, cache_read, reasoning),
        stop_reason: Stop,
        timestamp: 1700000000000L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ),
  }
  entry
}
