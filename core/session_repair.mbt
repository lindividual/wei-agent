///|
/// The one piece of crash recovery that lives in `core`: the shape of a synthetic tool result.
///
/// A process that dies after the model requests tools but before their results are written leaves a
/// transcript a provider refuses. Closing that gap is `agent/driver.mbt`'s `plan_repair`, and the
/// *detection* is there rather than here because the question is not the one this file used to ask.
///
/// **What this file used to answer, and why it was wrong.** It asked "which tool calls have no result".
/// That is not what a provider checks. The failure that produced the current implementation was a
/// transcript where every call *had* a result and the results were in the wrong place — so a check for
/// missing answers found nothing to fix, while every request built from that log came back `HTTP 400`,
/// on every turn, for every reader of that session. `plan_repair`'s comment has the measurement; the
/// weaker check and its tests were deleted rather than left beside it.
///
/// What is left here is the half both sides have to agree on: the words a synthesized result carries.

///|
/// The prompt a synthesized result carries.
///
/// Taken from dsh's crash repair, which is careful about the one thing that
/// matters here: a model that sees an interrupted tool call must not simply
/// repeat it. Re-running a read is harmless; re-running a command that already
/// had an effect is not.
const INTERRUPTED_TOOL_NOTICE : String = "The tool call was interrupted before its result was recorded. Retry only if the operation is read-only or idempotent; if it may have side effects, check the current state first."

///|
/// A synthetic result for a tool call that never got one.
pub fn aborted_tool_result(
  call_id~ : String,
  tool_name~ : String,
  timestamp~ : Int64,
) -> Message {
  ToolResult({
    tool_call_id: call_id,
    tool_name,
    content: [Text(INTERRUPTED_TOOL_NOTICE)],
    is_error: true,
    timestamp,
    details: None,
  })
}
