///|
/// Crash recovery for an interrupted session.
///
/// A process that dies after the model requests tools but before their results
/// are written leaves assistant messages whose tool calls have no answer. A
/// provider rejects such a transcript, so the session cannot be resumed until
/// the gap is closed.
///
/// Detection lives in `core` because it is pure logic over the log; appending the
/// closers is the platform layer's job.

///|
/// The prompt a synthesized result carries.
///
/// Taken from dsh's crash repair, which is careful about the one thing that
/// matters here: a model that sees an interrupted tool call must not simply
/// repeat it. Re-running a read is harmless; re-running a command that already
/// had an effect is not.
const INTERRUPTED_TOOL_NOTICE : String = "The tool call was interrupted before its result was recorded. Retry only if the operation is read-only or idempotent; if it may have side effects, check the current state first."

///|
/// Tool calls on the active path that no tool result answers, in the order the
/// model requested them.
///
/// Order matters: the synthesized results must be appended in the same order the
/// calls appear, or the transcript stops matching what the model asked for.
pub fn Session::unanswered_tool_calls(
  self : Session,
) -> Array[(String, String)] {
  let answered : Map[String, Unit] = Map([])
  let calls : Array[(String, String)] = []
  for entry in self.context_entries() {
    match entry.kind {
      Message(message~) =>
        match message {
          ToolResult(result) => answered.set(result.tool_call_id, ())
          Assistant(assistant) =>
            for block in assistant.content {
              match block {
                ToolCall(id~, name~, ..) => calls.push((id, name))
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  let out : Array[(String, String)] = []
  for call in calls {
    let (id, name) = call
    if answered.get(id) is None {
      out.push((id, name))
    }
  }
  out
}

///|
/// Whether this session was left mid-turn and needs repair before it can be sent
/// to a provider.
pub fn Session::needs_repair(self : Session) -> Bool {
  !self.unanswered_tool_calls().is_empty()
}

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

///|
/// The entries that close an interrupted turn: one result per unanswered call,
/// each parented to the previous, starting from the session's current leaf.
///
/// Returns an empty array when the session is already balanced, so a caller can
/// append unconditionally.
pub fn Session::repair_entries(
  self : Session,
  timestamp : Int64,
) -> Array[Entry] {
  let pending = self.unanswered_tool_calls()
  let out : Array[Entry] = []
  let mut parent = self.leaf_id
  for call in pending {
    let (call_id, tool_name) = call
    let id = new_entry_id()
    out.push({
      id,
      parent_id: parent,
      timestamp: format_iso_utc(timestamp),
      kind: Message(
        message=aborted_tool_result(call_id~, tool_name~, timestamp~),
      ),
    })
    parent = Some(id)
  }
  out
}
