///|
/// Logging that survives a crash.
///
/// MoonBit's stdout is block-buffered when redirected to a file, so the lines
/// explaining a failure sit in the buffer while the process dies. stderr is not
/// buffered, and a log nobody can read afterwards is worth nothing.
///
/// The writes are serialized because they have to be. Turns run in parallel — one per open
/// session — and each one logs as it goes, so two coroutines reaching this function at the same
/// moment is the normal case rather than a corner: it happens whenever two sessions are working.
/// Concurrent writes to `@stdio.stderr` are not safe, and the failure is not a garbled line: the
/// process aborts with `PanicError` from the runtime's write path. That was found by the white-box
/// tests, which run concurrently and were aborting about two runs in three once enough of them
/// logged; the same thing would take the server down the first time two turns logged at once.
///
/// A mutex rather than a lock-free queue: the log is a handful of lines per turn, so the contention
/// is nothing, and the ordering it gives (one line fully written before the next begins) is what
/// makes the log readable in the first place.
///
/// This has to be a top-level `let`: a mutex created per call would serialize nothing.
let log_lock : @async.Mutex = @async.Mutex()

///|
pub async fn log(line : String) -> Unit {
  log_lock.acquire()
  defer log_lock.release()
  @stdio.stderr.write(line + "\n")
}
