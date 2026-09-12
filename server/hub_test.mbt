///|
/// Fan-out to connected clients.
///
/// The property worth testing is the one that keeps the agent responsive: a
/// subscriber that stops reading must not be able to stall delivery or grow the
/// process. The queue is what enforces it, and "keeps the newest frames" is the part
/// a reconnecting browser depends on — the frames it missed are the ones it needs
/// least.

///|
/// Drain a subscriber's queue.
fn drain(queue : @aqueue.Queue[String]) -> Array[String] {
  let out : Array[String] = []
  let mut next = try queue.try_get() catch {
    _ => None
  } noraise {
    value => value
  }
  while next is Some(frame) {
    out.push(frame)
    next = try queue.try_get() catch {
      _ => None
    } noraise {
      value => value
    }
  }
  out
}

///|
async test "a broadcast reaches every subscriber" {
  let hub = Hub::new()
  let (first_id, first) = hub.subscribe()
  let (second_id, second) = hub.subscribe()
  hub.broadcast("one")
  hub.broadcast("two")
  assert_eq(drain(first), ["one", "two"])
  assert_eq(drain(second), ["one", "two"])
  // Unsubscribing stops delivery without disturbing the other subscriber.
  hub.unsubscribe(first_id)
  assert_eq(hub.count(), 1)
  hub.broadcast("three")
  assert_eq(drain(second), ["three"])
  hub.unsubscribe(second_id)
  assert_eq(hub.count(), 0)
  // Broadcasting with nobody listening is not an error.
  hub.broadcast("nobody")
}

///|
async test "a subscriber that falls behind keeps the newest frames" {
  let hub = Hub::new()
  let (id, queue) = hub.subscribe()
  let limit = subscriber_queue_limit()
  let total = limit + 3
  for i in 0..<total {
    hub.broadcast("frame-\{i}")
  }
  let frames = drain(queue)
  assert_eq(frames.length(), limit)
  // The oldest three were dropped, and the last frame is the newest one: losing the
  // tail instead would leave a client showing a stale transcript until it
  // reconnects.
  assert_eq(frames[0], "frame-3")
  assert_eq(frames[frames.length() - 1], "frame-\{total - 1}")
  ignore(id)
}

///|
/// A frame is encoded once and handed to every subscriber, so subscribers cannot
/// observe different encodings of the same patch.
async test "one encoding serves every subscriber" {
  let hub = Hub::new()
  let (_, first) = hub.subscribe()
  let (_, second) = hub.subscribe()
  let patch = @html.Patch::AppendText(target="stream-1", text="partial")
  hub.broadcast(patch.to_sse())
  assert_eq(drain(first), drain(second))
}
