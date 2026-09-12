///|
/// The agent's scheduling state machine.
///
/// The loop is expressed as a pure function — state plus event gives new state
/// plus actions — rather than as async control flow. The parts that are easy to
/// get wrong (when a queued message is admitted, what cancellation does to
/// in-flight work, when a turn actually ends) are then testable without a model,
/// a filesystem, or a clock, and the async driver becomes a thin dispatcher.
///
/// The two queues are pi's, not dsh's single inbox: "interject while it is
/// working" and "append after it finishes" are different user intentions and
/// deserve different timing.

///|
/// How many queued messages are admitted at once.
pub(all) enum QueueMode {
  /// Admit everything waiting.
  All
  /// Admit one, leaving the rest for later.
  OneAtATime
} derive(Eq, Debug)

///|
pub(all) enum Phase {
  /// Nothing in flight.
  Idle
  /// A model request is outstanding.
  AwaitingModel
  /// Tools are running.
  RunningTools
  /// Cancellation requested; waiting for in-flight work to settle.
  Cancelling
  /// Terminal.
  Stopped
} derive(Eq, Debug)

///|
pub(all) struct AgentState {
  phase : Phase
  /// Interjections, admitted before the next model request.
  steering : Array[Message]
  /// Appends, admitted only once the current turn would otherwise end.
  follow_up : Array[Message]
  steering_mode : QueueMode
  follow_up_mode : QueueMode
} derive(Eq, Debug)

///|
pub fn AgentState::new(
  steering_mode? : QueueMode = All,
  follow_up_mode? : QueueMode = All,
) -> AgentState {
  { phase: Idle, steering: [], follow_up: [], steering_mode, follow_up_mode, }
}

///|
/// Whether the loop is busy.
pub fn AgentState::is_busy(self : AgentState) -> Bool {
  match self.phase {
    Idle | Stopped => false
    _ => true
  }
}

// ── Events and actions ─────────────────────────────────────────────────────

///|
/// Something the loop reacts to.
pub(all) enum AgentEvent {
  /// A user message arriving with nothing in flight.
  Prompt(message~ : Message)
  /// A user message arriving mid-turn.
  Steer(message~ : Message)
  /// A user message arriving for after the turn.
  FollowUp(message~ : Message)
  /// The model finished a response.
  ModelFinished(has_tool_calls~ : Bool)
  /// Tool execution settled.
  ToolsFinished
  /// Cancellation was requested.
  Cancel
  /// In-flight work settled while cancelling.
  Settled
} derive(Eq, Debug)

///|
/// Something the driver must do. Data carried here is what the driver needs, not
/// a description of how to get it.
pub(all) enum Action {
  /// Send a request containing these newly admitted messages.
  RequestModel(messages~ : Array[Message])
  /// Run the tool calls from the last response.
  ExecuteTools
  /// The turn is over.
  EndTurn
  /// Stop and tear down.
  Stop
} derive(Eq, Debug)

// ── Queue admission ────────────────────────────────────────────────────────

///|
/// Split a queue into the part to admit now and the part to keep.
///
/// `OneAtATime` exists so a user can drop several notes into a running turn
/// without the model seeing them all at once; the rest stay queued.
fn admit(
  queue : Array[Message],
  mode : QueueMode,
) -> (Array[Message], Array[Message]) {
  match mode {
    All => (queue, [])
    OneAtATime =>
      if queue.is_empty() {
        ([], [])
      } else {
        ([queue[0]], queue[1:].to_owned())
      }
  }
}

///|
fn push(queue : Array[Message], message : Message) -> Array[Message] {
  let out : Array[Message] = []
  for existing in queue {
    out.push(existing)
  }
  out.push(message)
  out
}

// ── The transition ─────────────────────────────────────────────────────────

///|
/// Advance the state machine.
///
/// Every event is handled in every phase: an unhandled combination would be a
/// silently dropped user message, which is worse than an explicit no-op. The
/// no-op cases are documented where they occur.
pub fn AgentState::step(
  self : AgentState,
  event : AgentEvent,
) -> (AgentState, Array[Action]) {
  // Cancellation is checked first so a cancel is never lost to a racing event.
  match event {
    Cancel =>
      return match self.phase {
        Stopped => (self, [])
        // Nothing in flight: stop immediately.
        Idle => ({ ..self, phase: Stopped, }, [Stop])
        // Otherwise wait for the outstanding work to settle, so a tool that
        // already started is not abandoned mid-write.
        _ => ({ ..self, phase: Cancelling, }, [])
      }
    Settled =>
      return match self.phase {
        Cancelling => ({ ..self, phase: Stopped, }, [Stop])
        // A settle in any other phase is the normal completion path, not a
        // cancellation; there is nothing to do here.
        _ => (self, [])
      }
    _ => ()
  }

  match self.phase {
    Stopped => (self, [])
    Idle =>
      match event {
        Prompt(message~) =>
          (
            { ..self, phase: AwaitingModel, },
            [RequestModel(messages=[message])],
          )
        // Without a prompt there is nothing to answer.
        _ => (self, [])
      }
    AwaitingModel =>
      match event {
        // An interjection waits for the current request to come back.
        Steer(message~) =>
          ({ ..self, steering: push(self.steering, message), }, [])
        FollowUp(message~) =>
          ({ ..self, follow_up: push(self.follow_up, message), }, [])
        // A prompt arriving mid-request is treated as an interjection: the user
        // is talking to an agent that is already working.
        Prompt(message~) =>
          ({ ..self, steering: push(self.steering, message), }, [])
        ModelFinished(has_tool_calls~) =>
          if has_tool_calls {
            ({ ..self, phase: RunningTools, }, [ExecuteTools])
          } else {
            self.end_turn()
          }
        _ => (self, [])
      }
    RunningTools =>
      match event {
        ToolsFinished => {
          // Interjections land here: the tools have settled, so the next
          // request can carry them.
          let (admitted, remaining) = admit(self.steering, self.steering_mode)
          if admitted.is_empty() {
            ({ ..self, phase: AwaitingModel, }, [RequestModel(messages=[])])
          } else {
            (
              { ..self, phase: AwaitingModel, steering: remaining, },
              [RequestModel(messages=admitted)],
            )
          }
        }
        Steer(message~) =>
          ({ ..self, steering: push(self.steering, message), }, [])
        FollowUp(message~) =>
          ({ ..self, follow_up: push(self.follow_up, message), }, [])
        Prompt(message~) =>
          ({ ..self, steering: push(self.steering, message), }, [])
        _ => (self, [])
      }
    // While cancelling, further input is refused rather than queued: the turn is
    // on its way out and admitting a message would strand it.
    Cancelling => (self, [])
  }
}

///|
/// The turn would end here; whether it does depends on what is queued.
///
/// Interjections are preferred over appends: a user who interrupted is waiting on
/// this turn, while an append can wait for the next one.
fn AgentState::end_turn(self : AgentState) -> (AgentState, Array[Action]) {
  let (steering, steering_left) = admit(self.steering, self.steering_mode)
  if !steering.is_empty() {
    return (
      { ..self, phase: AwaitingModel, steering: steering_left, },
      [RequestModel(messages=steering)],
    )
  }
  let (follow_up, follow_up_left) = admit(self.follow_up, self.follow_up_mode)
  if !follow_up.is_empty() {
    return (
      { ..self, phase: AwaitingModel, follow_up: follow_up_left, },
      [RequestModel(messages=follow_up)],
    )
  }
  ({ ..self, phase: Idle, }, [EndTurn])
}
