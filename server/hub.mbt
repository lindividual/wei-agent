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
/// Delivery is non-blocking and lossy on purpose. A browser that has stopped
/// reading must not be able to stall the agent or grow the process without bound,
/// so a subscriber that falls behind has its *oldest* frames discarded — the
/// newest are the ones worth having. Dropping is safe because the next connection
/// re-fetches the whole mutable page, and because a turn ends by replacing the
/// region it streamed into.
///
/// The discard comes from `put`, not `try_put`: `try_put` refuses to add to a full
/// queue whatever the queue's kind, so a "full queue drops the frame" comment
/// written against it describes behaviour that does not exist.

///|
/// How many frames a single subscriber may fall behind by.
///
/// Generous next to the size of a turn: streaming emits a frame every few
/// characters, so a few hundred frames is a second or two of output, and a tab
/// that is further behind than that is better served by the reconnect snapshot.
pub fn subscriber_queue_limit() -> Int {
  1024
}

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
  let queue = @aqueue.Queue(
    kind=@aqueue.Kind::DiscardOldest(subscriber_queue_limit()),
  )
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
///
/// Async, but never awaits anything that blocks: dropping the oldest frame to make
/// room for the newest is a bounded amount of work, which is what lets this be
/// called from the middle of a turn without giving a stalled browser any influence
/// over how long the turn takes.
pub async fn Hub::broadcast(self : Hub, frame : String) -> Unit {
  for entry in self.subscribers {
    let (_, queue) = entry
    // A closed queue means the subscriber is gone; its id is removed when the
    // serving task ends, so ignoring the failure here is enough.
    try queue.put(frame) catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
}

///|
pub fn Hub::count(self : Hub) -> Int {
  self.subscribers.length()
}
