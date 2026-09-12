///|
/// Crash recovery: detecting and closing a turn that was interrupted mid-flight.

///|
fn assistant_with_calls(
  id : String,
  parent : String?,
  calls : Array[(String, String)],
) -> Entry {
  {
    id,
    parent_id: parent,
    timestamp: format_iso_utc(0L),
    kind: Message(
      message=Assistant({
        content: calls.map(c => {
          let (call_id, name) = c
          ToolCall(id=call_id, name~, arguments=Json::object(Map([])))
        }),
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: Usage::zero(),
        stop_reason: ToolUse,
        timestamp: 0L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ),
  }
}

///|
fn tool_result_entry(
  id : String,
  parent : String?,
  call_id : String,
  name : String,
  is_error : Bool,
) -> Entry {
  {
    id,
    parent_id: parent,
    timestamp: format_iso_utc(0L),
    kind: Message(
      message=ToolResult({
        tool_call_id: call_id,
        tool_name: name,
        content: [Text("ok")],
        is_error,
        timestamp: 0L,
        details: None,
      }),
    ),
  }
}

///|
/// A turn where every call has an answer needs nothing done to it.
test "a balanced turn needs no repair" {
  let session = session_with([
    assistant_with_calls("a", None, [("c1", "read")]),
    tool_result_entry("b", Some("a"), "c1", "read", false),
  ])
  assert_false(session.needs_repair())
  assert_eq(session.unanswered_tool_calls().length(), 0)
  assert_eq(session.repair_entries(0L).length(), 0)
}

///|
/// The common crash: the model asked for tools and the process died before any
/// result was written.
test "an unanswered call is detected in request order" {
  let session = session_with([
    assistant_with_calls("a", None, [("c1", "read"), ("c2", "bash")]),
  ])
  assert_true(session.needs_repair())
  let pending = session.unanswered_tool_calls()
  assert_eq(pending.length(), 2)
  assert_eq(pending[0], ("c1", "read"))
  assert_eq(pending[1], ("c2", "bash"))
}

///|
/// Only the calls without an answer are repaired; a partially completed batch
/// keeps the results it already has.
test "answered calls are left alone" {
  let session = session_with([
    assistant_with_calls("a", None, [("c1", "read"), ("c2", "bash")]),
    tool_result_entry("b", Some("a"), "c1", "read", false),
  ])
  let pending = session.unanswered_tool_calls()
  assert_eq(pending.length(), 1)
  assert_eq(pending[0], ("c2", "bash"))
}

///|
/// Repair produces a chain: each synthesized result parents the next, and the
/// first parents the leaf. A flat set of entries would lose the ordering the
/// transcript depends on.
test "repair entries form a chain from the leaf" {
  let session = session_with([
    assistant_with_calls("a", None, [("c1", "read"), ("c2", "bash")]),
  ])
  let repairs = session.repair_entries(1700000000000L)
  assert_eq(repairs.length(), 2)
  assert_eq(repairs[0].parent_id, Some("a"))
  assert_eq(repairs[1].parent_id, Some(repairs[0].id))
  assert_eq(repairs[0].timestamp, "2023-11-14T22:13:20.000Z")
  // Both are error results naming the right call.
  assert_true(
    repairs[0].kind
    is Message(message=ToolResult({ tool_call_id: "c1", is_error: true, .. })),
  )
  assert_true(
    repairs[1].kind
    is Message(message=ToolResult({ tool_call_id: "c2", is_error: true, .. })),
  )
}

///|
/// After appending the repairs the session is balanced, so resuming it twice
/// cannot pile up synthetic results.
test "a repaired session is balanced" {
  let session = session_with([assistant_with_calls("a", None, [("c1", "read")])])
  let repairs = session.repair_entries(0L)
  let entries : Array[Entry] = []
  for entry in session.entries {
    entries.push(entry)
  }
  for entry in repairs {
    entries.push(entry)
  }
  let repaired = Session::new(session.header, entries)
  assert_false(repaired.needs_repair())
  assert_eq(repaired.repair_entries(0L).length(), 0)
}

///|
/// A previous turn's unanswered call is not repaired once a later turn closed:
/// only the active path matters, and a completed exchange is not an interruption.
test "a call answered in a later turn is not pending" {
  let session = session_with([
    assistant_with_calls("a", None, [("c1", "read")]),
    tool_result_entry("b", Some("a"), "c1", "read", false),
    assistant_with_calls("c", Some("b"), [("c2", "bash")]),
    tool_result_entry("d", Some("c"), "c2", "bash", true),
  ])
  assert_false(session.needs_repair())
}
