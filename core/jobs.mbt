///|
/// Background jobs: work that outlives the tool call that started it.
///
/// This is the layer dsh calls the background task runtime, and the reason it exists is the
/// reason it exists there: a command like `npm run dev &` returns immediately and leaves a
/// process running. Nothing in the tool call is still open, nothing in the turn is still
/// running, and the only trace is a process nobody is looking at — which is exactly the thing
/// they forget to close.
///
/// The records here are pure data plus the state machine over it. Starting and killing
/// processes is the platform layer's job; what a job *is*, and what "still running" means, is
/// decided here so it can be tested without a process table.

///|
/// Lifecycle of one job, with dsh's names.
pub(all) enum JobStatus {
  Running
  /// Cancellation asked for, waiting for the work to actually stop. Kept distinct from
  /// `Killed` because a process that ignores `SIGTERM` is a thing a reader needs to see.
  Stopping
  Completed
  Killed
  Failed
} derive(Eq, Debug)

///|
pub fn JobStatus::to_string(self : JobStatus) -> String {
  match self {
    Running => "running"
    Stopping => "stopping"
    Completed => "completed"
    Killed => "killed"
    Failed => "failed"
  }
}

///|
/// Whether the status is one the reader still has to do something about.
pub fn JobStatus::is_live(self : JobStatus) -> Bool {
  match self {
    Running | Stopping => true
    _ => false
  }
}

///|
/// Where a job's output is being written, and how much of it has been handed back.
///
/// Paths rather than file handles because the job's writer is a process of its own: the shell exits
/// the moment the command is backgrounded, and the child that inherits the file keeps writing to it
/// with nothing of ours left open.
pub(all) struct JobOutput {
  out_path : String
  err_path : String
  /// Bytes of each stream that the result of the call which started the job already showed. What
  /// `wait` returns starts after them, so waiting twice returns each line once.
  out_read : Int
  err_read : Int
} derive(Eq, Debug)

///|
/// One background job.
pub(all) struct Job {
  /// `<kind>-N`, as dsh issues them.
  id : String
  /// What kind of work it is. `bash` is the only kind today.
  kind : String
  /// One line for the reader: the command, as it was asked.
  label : String
  /// Owning session. Jobs belong to a session, so leaving one does not mean losing track of
  /// what it is still running.
  session : String
  mut status : JobStatus
  started_at : Int64
  mut finished_at : Int64?
  /// Kind-specific fact for the status line: the exit code, or why it was killed.
  mut detail : String
  /// Every pid ever recorded for this job, in the order first seen.
  ///
  /// A list rather than one pid because the shell is not the work: `cmd &` leaves a child whose
  /// parent exits immediately, and reparenting does not change its pid. Killing means killing
  /// all of them.
  pids : Array[Int]
  /// The last output seen, bounded, so the panel can say what it is doing.
  mut tail : String
  /// Where the output is, when there is somewhere to read it from.
  ///
  /// Not persisted, and `None` for a job read back from disk after a restart: the files belong to
  /// the run that made them, so a path from a previous run is a path that is gone. `wait` says so
  /// rather than reading whatever now happens to be at that name.
  mut output : JobOutput?
  /// Whether the tool call that started this job is still in flight.
  ///
  /// The pids are learned *from* that call, and that call is also what knows what the command left
  /// running: the shell of a backgrounded command exits within milliseconds, while the call that
  /// started it is still reading the process table. In that window the process table already looks
  /// finished and nothing has been recorded yet, so `settle_gone` leaves an open call alone.
  ///
  /// Measured: without this, a backgrounded `sh -c 'sleep 2; echo …'` was recorded as "exited on its
  /// own" 20ms after it started, on the first of three attempts — and the record that the whole
  /// feature exists for was gone, along with the running child it pointed at.
  ///
  /// Only ever true in the process that started the call, so it is not persisted; a job read back
  /// from disk has nothing left to wait for.
  mut call_open : Bool
} derive(Debug)

///|
pub fn Job::is_live(self : Job) -> Bool {
  self.status.is_live()
}

///|
/// How long ago it started, or how long it ran for.
pub fn Job::age_ms(self : Job, now : Int64) -> Int64 {
  match self.finished_at {
    Some(finished) => finished - self.started_at
    None => now - self.started_at
  }
}

///|
/// The jobs of a session.
///
/// A store rather than a single slot: the point of the feature is that one session can have
/// several things running, and a reader who wants to know what to close needs all of them.
pub(all) struct JobStore {
  mut jobs : Array[Job]
  mut next_id : Int
}

///|
pub fn JobStore::new() -> JobStore {
  { jobs: [], next_id: 1, }
}

///|
/// How many jobs one session may have running at once.
///
/// dsh defaults this to ten and refuses to start beyond it, telling the caller to kill
/// something first. The limit is what keeps "start a background job" from becoming a way to
/// accumulate processes nobody counts.
pub fn max_live_jobs_per_session() -> Int {
  10
}

///|
/// Register a job that has started, and return its id.
pub fn JobStore::start(
  self : JobStore,
  kind~ : String,
  label~ : String,
  session~ : String,
  started_at~ : Int64,
  pids~ : Array[Int],
  tail? : String = "",
) -> String {
  let id = "\{kind}-\{self.next_id}"
  self.next_id += 1
  self.jobs.push({
    id,
    kind,
    label,
    session,
    status: Running,
    started_at,
    finished_at: None,
    detail: "",
    pids,
    tail,
    output: None,
    call_open: true,
  })
  id
}

///|
/// Record that the call which started this job has returned.
///
/// Called with the command's outcome in hand, which is what makes the pids in the store complete:
/// until it is called, "every pid I know about is gone" is a statement about an incomplete list.
pub fn JobStore::finish_call(self : JobStore, id : String) -> Unit {
  match self.get(id) {
    None => ()
    Some(job) => job.call_open = false
  }
}

///|
pub fn JobStore::get(self : JobStore, id : String) -> Job? {
  for job in self.jobs {
    if job.id == id {
      return Some(job)
    }
  }
  None
}

///|
/// Every job, live ones first and newest first within each group.
pub fn JobStore::list(self : JobStore) -> Array[Job] {
  let live : Array[Job] = []
  let done : Array[Job] = []
  for job in self.jobs {
    if job.is_live() {
      live.push(job)
    } else {
      done.push(job)
    }
  }
  let out : Array[Job] = []
  for i in 0..<live.length() {
    out.push(live[live.length() - 1 - i])
  }
  for i in 0..<done.length() {
    out.push(done[done.length() - 1 - i])
  }
  out
}

///|
/// Jobs that are still live, optionally for one session.
pub fn JobStore::live(self : JobStore, session? : String) -> Array[Job] {
  let out : Array[Job] = []
  for job in self.jobs {
    if !job.is_live() {
      continue
    }
    match session {
      Some(session) => if job.session == session { out.push(job) }
      None => out.push(job)
    }
  }
  out
}

///|
/// How many jobs a session has running, which is what the admission limit counts.
pub fn JobStore::live_count(self : JobStore, session : String) -> Int {
  self.live(session~).length()
}

///|
/// Record that a job ended.
///
/// Idempotent and first-wins, like dsh's settlement: a process that was killed after it had
/// already exited must not turn a `completed` into a `killed` — the reader would then distrust
/// every exit code in the panel.
pub fn JobStore::finish(
  self : JobStore,
  id : String,
  status : JobStatus,
  detail~ : String,
  finished_at~ : Int64,
) -> Unit {
  match self.get(id) {
    None => ()
    Some(job) => {
      if !job.is_live() {
        return
      }
      job.status = status
      job.detail = detail
      job.finished_at = Some(finished_at)
    }
  }
}

///|
/// Reconcile live jobs against the processes that actually exist, and report how many were lost.
///
/// Called on start, with the store read back from disk. A job that was running when the server went
/// away is one of two things, and only the process table can tell them apart:
///
/// - a process that is still there, which is the case persistence exists for — the record is what
///   lets the reader find and kill something the server no longer owns;
/// - a process that has since exited, whose outcome nobody witnessed, so the honest thing to say is
///   that it was lost rather than to leave it claiming to be running forever.
///
/// `is_alive` is a parameter rather than a process-table call so the decision is pure and testable:
/// this is the part with a rule in it, and the rule is not about pids — it is about what to claim
/// when the only evidence is gone.
pub fn JobStore::reconcile(
  self : JobStore,
  is_alive : (Int) -> Bool,
  now : Int64,
) -> Int {
  let mut lost = 0
  for job in self.jobs {
    if !job.is_live() {
      continue
    }
    // Any surviving pid keeps the job alive: a command's shell can exit while the child it
    // backgrounded is the actual work, which is the whole reason several pids are recorded.
    let mut alive = false
    for pid in job.pids {
      if is_alive(pid) {
        alive = true
      }
    }
    if !alive {
      job.status = Failed
      job.detail = "lost: the server exited while this was running"
      job.finished_at = Some(now)
      lost = lost + 1
    }
  }
  lost
}

///|
/// Record where a job's output is written, so a later call can read what the job printed after the
/// call that started it returned.
///
/// Attached once, and only while the job is live: a job that has already ended has already had its
/// output read by whoever waited for it.
pub fn JobStore::attach_output(
  self : JobStore,
  id : String,
  output : JobOutput,
) -> Unit {
  match self.get(id) {
    None => ()
    // Attached whether or not the job reads as live: the caller has the command's own outcome in
    // hand, so the output exists and handing it back can only help.
    Some(job) => job.output = Some(output)
  }
}

///|
/// Record that everything up to `out_bytes` and `err_bytes` has been handed back.
///
/// Called with what a read actually consumed, which is not always what it asked for: the file may
/// have ended, or the read may have stopped at its ceiling.
pub fn JobStore::mark_read(
  self : JobStore,
  id : String,
  out_bytes~ : Int,
  err_bytes~ : Int,
) -> Unit {
  match self.get(id) {
    None => ()
    Some(job) =>
      match job.output {
        Some(output) =>
          job.output = Some({
            ..output,
            out_read: out_bytes,
            err_read: err_bytes,
          })
        None => ()
      }
  }
}

///|
/// Record more pids and output for a live job.
pub fn JobStore::observe(
  self : JobStore,
  id : String,
  pids : Array[Int],
  tail~ : String,
) -> Unit {
  match self.get(id) {
    None => ()
    Some(job) => {
      for pid in pids {
        let mut known = false
        for existing in job.pids {
          if existing == pid {
            known = true
          }
        }
        if !known {
          job.pids.push(pid)
        }
      }
      if tail != "" {
        job.tail = tail
      }
    }
  }
}

///|
/// Ask for a job to stop: the status becomes `stopping` and the caller gets the pids to signal.
///
/// The status changes here rather than when the processes are gone because those are two
/// moments: a process that ignores `SIGTERM` stays `stopping` until it is killed, and a reader
/// watching the panel can see the difference.
pub fn JobStore::request_stop(self : JobStore, id : String) -> Array[Int] {
  match self.get(id) {
    None => []
    Some(job) =>
      if !job.is_live() {
        []
      } else {
        job.status = Stopping
        job.pids
      }
  }
}

///|
/// Drop one record entirely.
///
/// Used for the common case: a command that finished and left nothing behind is not background
/// work, and a panel that listed every tool call would be a log rather than an answer to "what is
/// still running".
pub fn JobStore::forget(self : JobStore, id : String) -> Unit {
  let kept : Array[Job] = []
  for job in self.jobs {
    if job.id != id {
      kept.push(job)
    }
  }
  self.jobs = kept
}

///|
/// Settle the jobs whose processes are all gone, and say whether anything changed.
///
/// `alive` answers "is this pid still running" — the caller owns that question because it needs a
/// process table, and keeping it out means the decision below can be tested without one.
///
/// The status a job gets depends on why it ended, which is the part worth naming: a job the reader
/// stopped settles as `killed` (they asked for it), and one that left on its own settles as
/// `completed`. Marking both "exited on its own" would tell the reader the opposite of what they
/// did — and the panel is where they check.
pub fn JobStore::settle_gone(
  self : JobStore,
  alive : (Int) -> Bool,
  now~ : Int64,
) -> Bool {
  let mut changed = false
  for job in self.jobs {
    if !job.is_live() {
      continue
    }
    // No pids means the command has not been seen yet, not that its work is over: a job is
    // registered when it starts and learns its pids a moment later, and settling in that window
    // would drop the record of something that is running right then.
    if job.pids.is_empty() {
      continue
    }
    // And the pids are only complete once the call has reported them. The last thing a backgrounded
    // command does is exit, leaving the child that is the actual work behind — and the call that
    // started it is still running at that moment, so what is known here is the shell alone.
    if job.call_open {
      continue
    }
    let mut any_alive = false
    for pid in job.pids {
      if alive(pid) {
        any_alive = true
      }
    }
    if any_alive {
      continue
    }
    let stopping = job.status is Stopping
    job.status = if stopping { Killed } else { Completed }
    job.detail = if stopping { "stopped" } else { "exited on its own" }
    job.finished_at = Some(now)
    changed = true
  }
  changed
}

///|
/// Drop the jobs of a session that are no longer live, so the panel does not accumulate
/// history. Returns how many were dropped.
pub fn JobStore::forget_finished(
  self : JobStore,
  older_than~ : Int64,
  now~ : Int64,
) -> Int {
  let kept : Array[Job] = []
  let mut dropped = 0
  for job in self.jobs {
    let stale = match job.finished_at {
      Some(finished) => now - finished > older_than
      None => false
    }
    if stale {
      dropped += 1
    } else {
      kept.push(job)
    }
  }
  self.jobs = kept
  dropped
}

// ── Persistence ────────────────────────────────────────────────────────────

///|
/// The store as JSON, for writing somewhere that outlives the process.
///
/// Jobs are kept in memory, which is right for the panel and wrong for the processes: a `bash`
/// job that outlives its tool call also outlives the server if the server is killed, and a child
/// process whose only record died with the process that started it is an orphan nobody can find,
/// let alone stop. Writing the records down is what makes "there is still something running from
/// last time" a fact the next start can act on.
///
/// `next_id` is persisted too. Without it a restart would hand out `bash-1` again while `bash-1`
/// from the previous run is still on the loose, and two live jobs sharing an id is worse than
/// losing the records.
pub fn JobStore::to_json(self : JobStore) -> Json {
  let jobs : Array[Json] = []
  for job in self.jobs {
    jobs.push(
      Json::object(
        Map([
          ("id", Json::string(job.id)),
          ("kind", Json::string(job.kind)),
          ("label", Json::string(job.label)),
          ("session", Json::string(job.session)),
          ("status", Json::string(job.status.to_string())),
          ("startedAt", Json::number(job.started_at.to_double())),
          (
            "finishedAt",
            match job.finished_at {
              Some(t) => Json::number(t.to_double())
              None => Json::null()
            },
          ),
          ("detail", Json::string(job.detail)),
          ("pids", Json::array(job.pids.map(p => Json::number(p.to_double())))),
          ("tail", Json::string(job.tail)),
        ]),
      ),
    )
  }
  Json::object(
    Map([
      ("nextId", Json::number(self.next_id.to_double())),
      ("jobs", Json::array(jobs)),
    ]),
  )
}

///|
fn json_string(j : Json, key : String) -> String? {
  match j {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
fn json_int(j : Json, key : String) -> Int? {
  match j {
    Object(fields) =>
      match fields.get(key) {
        Some(Number(value, ..)) => Some(value.to_int())
        _ => None
      }
    _ => None
  }
}

///|
/// A JSON number as an `Int64`.
///
/// Separate from `json_int` because an epoch-millisecond timestamp does not fit in the 32-bit
/// `Int` this platform has: `1789283993636.0.to_int()` saturates to `2147483647`, and a job read
/// back from disk would claim to have started in 1970 — which is how the panel came to print an
/// age of 496426 hours for a job that had been running for a minute. Token counts and id counters
/// are small and can stay `Int`; times cannot.
fn json_int64(j : Json, key : String) -> Int64? {
  match j {
    Object(fields) =>
      match fields.get(key) {
        Some(Number(value, ..)) => Some(value.to_int64())
        _ => None
      }
    _ => None
  }
}

///|
fn status_of(name : String) -> JobStatus {
  if name == "running" {
    Running
  } else if name == "stopping" {
    Stopping
  } else if name == "completed" {
    Completed
  } else if name == "killed" {
    Killed
  } else {
    Failed
  }
}

///|
/// Read a store back, skipping anything malformed.
///
/// Tolerant on purpose: this file is written by a process that may have been killed mid-write, and
/// a single truncated record must not cost the reader every *other* job that was recorded. A file
/// that does not parse at all reads as an empty store, which is the same thing a first run sees.
pub fn parse_job_store(text : String) -> JobStore {
  let parsed = try @json.parse(text) catch {
    _ => return JobStore::new()
  } noraise {
    value => value
  }
  let jobs_json = match json_field(parsed, "jobs") {
    Some(Array(items)) => items
    _ => return JobStore::new()
  }
  let jobs : Array[Job] = []
  for item in jobs_json {
    let id = match json_string(item, "id") {
      Some(value) => value
      None => continue
    }
    let started_at = match json_int64(item, "startedAt") {
      Some(value) => value
      None => continue
    }
    let pids : Array[Int] = []
    match json_field(item, "pids") {
      Some(Array(values)) =>
        for value in values {
          match value {
            Number(n, ..) => pids.push(n.to_int())
            _ => ()
          }
        }
      _ => ()
    }
    jobs.push({
      id,
      kind: json_string(item, "kind").unwrap_or(""),
      label: json_string(item, "label").unwrap_or(""),
      session: json_string(item, "session").unwrap_or(""),
      status: status_of(json_string(item, "status").unwrap_or("")),
      started_at,
      finished_at: json_int64(item, "finishedAt"),
      detail: json_string(item, "detail").unwrap_or(""),
      pids,
      tail: json_string(item, "tail").unwrap_or(""),
      output: None,
      // The process that made the call is gone; there is nothing left to report.
      call_open: false,
    })
  }
  {
    jobs,
    // A store with no recorded counter resumes from one past the highest id it read, so a
    // restart cannot reissue an id that a surviving process is still using.
    next_id: match json_int(parsed, "nextId") {
      Some(value) => value
      None => highest_id_number(jobs) + 1
    },
  }
}

///|
/// The largest `N` in any `<kind>-N` id, or zero.
fn highest_id_number(jobs : Array[Job]) -> Int {
  let mut highest = 0
  for job in jobs {
    let at = job.id.rev_find("-")
    let digits = match at {
      Some(index) => job.id[index + 1:].to_owned()
      None => continue
    }
    let value = try @string.parse_int(digits) catch {
      _ => continue
    } noraise {
      parsed => parsed
    }
    if value > highest {
      highest = value
    }
  }
  highest
}
