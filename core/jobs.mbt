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
/// The one-line listing dsh's `job_list` prints: `<id> [<kind>] <status> — <label>`.
///
/// Same shape on purpose: it is what a reader (and, if we ever give the model the tool, the
/// model) already knows how to read.
pub fn Job::list_line(self : Job) -> String {
  let detail = if self.detail == "" { "" } else { " (\{self.detail})" }
  "\{self.id} [\{self.kind}] \{self.status.to_string()}\{detail} — \{self.label}"
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
  })
  id
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
