///|
/// The agent scheduling state machine.
///
/// These tests are the specification: they say when a queued message is admitted,
/// what a turn boundary is, and what cancellation does to work already started.

///|
fn msg(text : String) -> Message {
  User({ content: [Text(text)], timestamp: 0L, })
}

///|
fn text_of(message : Message) -> String {
  match message {
    User({ content: [Text(t)], .. }) => t
    _ => "?"
  }
}

///|
/// Feed events in order and collect every action produced.
fn run(
  initial : AgentState,
  events : Array[AgentEvent],
) -> (AgentState, Array[Action]) {
  let mut state = initial
  let actions : Array[Action] = []
  for event in events {
    let (next, produced) = state.step(event)
    state = next
    for action in produced {
      actions.push(action)
    }
  }
  (state, actions)
}

///|
/// Describe actions compactly so a sequence can be asserted in one comparison.
fn shape(actions : Array[Action]) -> String {
  let parts : Array[String] = []
  for action in actions {
    parts.push(
      match action {
        RequestModel(messages~) =>
          if messages.is_empty() {
            "request"
          } else {
            "request(\{messages.map(text_of).join("+")})"
          }
        ExecuteTools => "tools"
        EndTurn => "end"
        Stop => "stop"
      },
    )
  }
  parts.join(",")
}

// ── A plain turn ───────────────────────────────────────────────────────────

///|
/// The ordinary case: ask, answer, done.
test "a question with no tool calls ends the turn" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("hi")),
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(hi),end")
  assert_eq(state.phase, Phase::Idle)
}

///|
/// A turn that uses tools keeps going: the results have to go back to the model.
test "a turn with tool calls continues after the tools" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("read it")),
    ModelFinished(has_tool_calls=true),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(read it),tools,request,end")
  assert_eq(state.phase, Phase::Idle)
}

///|
/// Several tool rounds in one turn: the loop only ends when the model stops
/// asking for tools.
test "several tool rounds stay inside one turn" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("a")),
    ModelFinished(has_tool_calls=true),
    ToolsFinished,
    ModelFinished(has_tool_calls=true),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(a),tools,request,tools,request,end")
  assert_eq(state.phase, Phase::Idle)
}

// ── Interjections ──────────────────────────────────────────────────────────

///|
/// An interjection is delivered with the next request, which is the one issued
/// once the running tools have settled.
test "a steer is admitted after the tools settle" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("start")),
    ModelFinished(has_tool_calls=true),
    Steer(message=msg("wait")),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(start),tools,request(wait),end")
  assert_eq(state.phase, Phase::Idle)
}

///|
/// A steer arriving while the model is thinking waits for the response rather
/// than starting a second request.
test "a steer during a model call does not start a request" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("start")),
    Steer(message=msg("note")),
    // The steer is not sent yet.
    ModelFinished(has_tool_calls=true),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(start),tools,request(note),end")
  let _ = state
}

///|
/// A steer can keep a turn alive even though the model asked to stop: the user
/// is waiting on this turn, so it must not be closed underneath them.
test "a steer reopens a turn the model wanted to end" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("start")),
    Steer(message=msg("one more")),
    ModelFinished(has_tool_calls=false),
  ])
  // The turn does not close: the steer opened a second request instead.
  assert_eq(shape(actions), "request(start),request(one more)")
  assert_eq(state.phase, Phase::AwaitingModel)
  // Only once that request is answered with nothing left queued does it end.
  let (after, more) = run(state, [ModelFinished(has_tool_calls=false)])
  assert_eq(shape(more), "end")
  assert_eq(after.phase, Phase::Idle)
}

///|
/// A prompt sent while the agent is working is treated as an interjection: the
/// user is talking to a busy agent, not starting a second one.
test "a prompt while busy is queued as a steer" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("first")),
    Prompt(message=msg("second")),
    ModelFinished(has_tool_calls=true),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(first),tools,request(second),end")
  let _ = state
}

// ── Appends ────────────────────────────────────────────────────────────────

///|
/// An append waits for the turn to end, unlike an interjection.
test "a follow-up waits for the turn to end" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("start")),
    FollowUp(message=msg("and then")),
    ModelFinished(has_tool_calls=true),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
    ModelFinished(has_tool_calls=false),
  ])
  // The first turn ends, then the follow-up opens a second one.
  assert_eq(
    shape(actions),
    "request(start),tools,request,request(and then),end",
  )
  assert_eq(state.phase, Phase::Idle)
}

///|
/// An interjection outranks an append: the interrupting user is waiting now, the
/// appending one can wait.
test "a steer is served before a follow-up" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("start")),
    FollowUp(message=msg("later")),
    Steer(message=msg("now")),
    ModelFinished(has_tool_calls=false),
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(start),request(now),request(later)")
  let (after, more) = run(state, [ModelFinished(has_tool_calls=false)])
  assert_eq(shape(more), "end")
  assert_eq(after.phase, Phase::Idle)
}

// ── Queue modes ────────────────────────────────────────────────────────────

///|
/// One-at-a-time admits a single message per boundary, so several notes do not
/// arrive as one blob.
test "one-at-a-time admits a single message per boundary" {
  let state = AgentState::new(steering_mode=OneAtATime)
  let (state, actions) = run(state, [
    Prompt(message=msg("start")),
    ModelFinished(has_tool_calls=true),
    Steer(message=msg("a")),
    Steer(message=msg("b")),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
  ])
  // "a" went with the first boundary, "b" with the second; a turn boundary is
  // reached twice here, and each admits exactly one.
  assert_eq(shape(actions), "request(start),tools,request(a),request(b)")
  assert_eq(state.steering.length(), 0)
  assert_eq(state.phase, Phase::AwaitingModel)
}

///|
/// The remainder is not lost: it is admitted the next time a boundary is reached.
test "one-at-a-time keeps the rest queued" {
  let state = AgentState::new(steering_mode=OneAtATime)
  let (state, actions) = run(state, [
    Prompt(message=msg("start")),
    ModelFinished(has_tool_calls=true),
    Steer(message=msg("a")),
    Steer(message=msg("b")),
    ToolsFinished,
    ModelFinished(has_tool_calls=false),
    // The second steer reopens the turn.
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "request(start),tools,request(a),request(b),end")
  assert_eq(state.steering.length(), 0)
}

// ── Cancellation ───────────────────────────────────────────────────────────

///|
/// Cancelling an idle agent stops immediately.
test "cancel while idle stops at once" {
  let (state, actions) = run(AgentState::new(), [Cancel])
  assert_eq(shape(actions), "stop")
  assert_eq(state.phase, Phase::Stopped)
}

///|
/// Cancelling with work in flight waits for it to settle. A tool that has already
/// started a write must not be abandoned mid-operation.
test "cancel while running waits for the work to settle" {
  let (state, actions) = run(AgentState::new(), [
    Prompt(message=msg("go")),
    ModelFinished(has_tool_calls=true),
    Cancel,
  ])
  // Cancellation produced no action yet.
  assert_eq(shape(actions), "request(go),tools")
  assert_eq(state.phase, Phase::Cancelling)
  let (state, more) = run(state, [Settled])
  assert_eq(shape(more), "stop")
  assert_eq(state.phase, Phase::Stopped)
}

///|
/// Input arriving while cancelling is refused rather than queued: the turn is on
/// its way out, and accepting a message would leave it without an answer.
test "input while cancelling is not queued" {
  let (state, _) = run(AgentState::new(), [
    Prompt(message=msg("go")),
    ModelFinished(has_tool_calls=true),
    Cancel,
    Steer(message=msg("ignored")),
    FollowUp(message=msg("also ignored")),
  ])
  assert_eq(state.steering.length(), 0)
  assert_eq(state.follow_up.length(), 0)
  assert_eq(state.phase, Phase::Cancelling)
}

///|
/// Once stopped, the machine stays stopped: a late event cannot restart it.
test "a stopped agent ignores further events" {
  let (state, actions) = run(AgentState::new(), [
    Cancel,
    Prompt(message=msg("hello?")),
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "stop")
  assert_eq(state.phase, Phase::Stopped)
}

// ── Idle noise ─────────────────────────────────────────────────────────────

///|
/// Events that make no sense in the current phase do nothing rather than
/// corrupting state.
test "a model reply with no request in flight is ignored" {
  let (state, actions) = run(AgentState::new(), [
    ModelFinished(has_tool_calls=false),
  ])
  assert_eq(shape(actions), "")
  assert_eq(state.phase, Phase::Idle)
}

///|
test "is_busy reflects the phase" {
  assert_false(AgentState::new().is_busy())
  let (busy, _) = run(AgentState::new(), [Prompt(message=msg("x"))])
  assert_true(busy.is_busy())
  let (stopped, _) = run(AgentState::new(), [Cancel])
  assert_false(stopped.is_busy())
}
