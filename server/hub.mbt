///|
/// Fan-out from the agent to every connected browser.
///
/// One agent, potentially several tabs. Each subscriber gets its own queue, and
/// the agent writes into all of them.
///
/// Two properties matter.
///
/// Mutating the subscriber list needs no lock: MoonBit's async is cooperative and
/// single-threaded, so a stretch of code with no `await` in it cannot be
/// interrupted.
///
/// Delivery is non-blocking. A browser that has stopped reading must not be able
/// to stall the agent, so a full queue drops the frame instead of waiting. Dropping
/// is safe because a client that fell behind reconnects and re-fetches the whole
/// transcript.

///|
/// A connected browser.
///
/// The queue carries pre-encoded SSE frames rather than structured events: the
/// encoding is pure and cheap, and doing it once serves every subscriber.
pub struct Hub {
  mut subscribers : Array[(Int, @aqueue.Queue[String])]
  mut next_id : Int
}

///|
pub fn Hub::new() -> Hub {
  { subscribers: [], next_id: 1, }
}

///|
/// Attach a subscriber, returning its id and the queue to read from.
pub fn Hub::subscribe(self : Hub) -> (Int, @aqueue.Queue[String]) {
  let id = self.next_id
  self.next_id = id + 1
  let queue = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)
  self.subscribers.push((id, queue))
  (id, queue)
}

///|
pub fn Hub::unsubscribe(self : Hub, id : Int) -> Unit {
  let kept : Array[(Int, @aqueue.Queue[String])] = []
  for entry in self.subscribers {
    let (existing, _) = entry
    if existing != id {
      kept.push(entry)
    }
  }
  self.subscribers = kept
}

///|
/// Send a frame to everyone.
pub fn Hub::broadcast(self : Hub, frame : String) -> Unit {
  for entry in self.subscribers {
    let (_, queue) = entry
    // `try_put` rather than `put`: a subscriber that is not draining its queue
    // drops frames, which is the behaviour that keeps the agent responsive.
    let _ = try queue.try_put(frame) catch {
      _ => false
    } noraise {
      queued => queued
    }
  }
}

///|
pub fn Hub::count(self : Hub) -> Int {
  self.subscribers.length()
}
