///|
/// The tasks panel: what is running right now, and how to stop it.
///
/// Parallel sessions made this necessary. Before, work either happened in the session on
/// screen or not at all; now a turn can be running in a session nobody is looking at, and
/// "1 other session(s) running" on the status line says that something is happening but not
/// what, how long it has been happening, or how to end it.
///
/// The panel is its own region, refreshed on its own, because it changes for reasons the
/// conversation does not — a tool starting, a queue growing, a turn ending — and re-rendering
/// the sidebar for each of those would mean re-reading the session store several times a
/// minute.

///|
/// One session with work in flight.
pub(all) struct TaskItem {
  /// What a click on Stop sends back.
  path : String
  /// The question being answered, if a turn is running.
  label : String
  /// Short session id, for when there is no question to show yet.
  session : String
  /// What it is doing: "waiting for the model", "running bash: sleep 30".
  phase : String
  /// When the current turn started, in milliseconds since the epoch. The browser turns this
  /// into "12s" and keeps it counting, so the server does not have to send a frame a second
  /// to make the page look alive.
  since : Int64
  /// Prompts waiting for this session's turn slot.
  queued : Int
} derive(Eq, Debug)

///|
/// A duration, in the roughest unit that is still true.
///
/// Server-rendered so the panel means something without JavaScript; the browser then takes
/// over and keeps it counting.
pub fn age_from(since : Int64) -> String {
  let now = @env.now().reinterpret_as_int64()
  let seconds = if now > since { (now - since) / 1000L } else { 0L }
  if seconds < 60L {
    "\{seconds}s"
  } else if seconds < 3600L {
    "\{seconds / 60L}m \{seconds % 60L}s"
  } else {
    "\{seconds / 3600L}h \{(seconds % 3600L) / 60L}m"
  }
}

///|
/// The panel. Renders an empty container — no heading, no border — when nothing is running:
/// a section that is usually empty should not take up space or attention.
pub fn render_tasks(items : Array[TaskItem]) -> Node {
  let rows : Array[Node] = []
  for item in items {
    let label = if item.label != "" { item.label } else { item.session }
    let meta : Array[Node] = [
      txt(item.phase),
      txt(" · "),
      el(Time, attrs=[attr("data-since", "\{item.since}")], children=[
        txt(age_from(item.since)),
      ]),
    ]
    if item.queued > 0 {
      meta.push(txt(" · \{item.queued} queued"))
    }
    rows.push(
      el(Div, attrs=[cls("task")], children=[
        el(Div, attrs=[cls("row")], children=[
          el(Span, attrs=[cls("label"), attr("title", item.path)], children=[
            txt(label),
          ]),
          el(
            Button,
            attrs=[
              cls("stop"),
              attr("type", "button"),
              attr("data-stop", item.path),
              attr("title", "stop this session"),
            ],
            children=[txt("Stop")],
          ),
        ]),
        el(Div, attrs=[cls("tool")], children=meta),
      ]),
    )
  }
  // Nothing running: an empty container, not an empty heading. A section that is usually
  // empty should not take up space or attention.
  el(
    Div,
    attrs=[attr("id", "tasks")],
    children=if rows.is_empty() { [] } else { [panel("Running", rows)] },
  )
}

///|
/// One background job: work that outlived the tool call that started it.
pub(all) struct JobItem {
  id : String
  /// The command, as it was asked.
  label : String
  kind : String
  status : String
  /// How long it has been running.
  age_ms : Int64
  /// The processes still alive for it, so a reader can recognise them in `ps`.
  pids : Array[Int]
} derive(Eq, Debug)

///|
/// The background panel: every job still running, and nothing at all when none are.
///
/// Separate from the turn panel above it because the two answer different questions: a turn is
/// work the reader is waiting on, a job is work that is still there after they stopped waiting.
/// That second thing is the one that gets forgotten.
///
/// Only jobs that are still running. A finished one has nothing left to stop, so a card for it
/// would be a row with no action on it, and the panel sits above the session list — a session that
/// runs a dozen commands would leave a dozen cards pushing down the thing the reader came to click.
/// How a job ended is in the log and in the job's own line; this panel answers "what is still
/// running", not "what has ever run".
pub fn render_jobs(items : Array[JobItem], now : Int64) -> Node {
  let rows : Array[Node] = []
  for item in items {
    rows.push(job_row(item, now))
  }
  // Nothing running: an empty container, not an empty heading.
  el(
    Div,
    attrs=[attr("id", "jobs")],
    children=if rows.is_empty() { [] } else { [panel("Background", rows)] },
  )
}

///|
/// One job, as the panel draws it.
fn job_row(item : JobItem, now : Int64) -> Node {
  let meta : Array[Node] = [
    txt(item.status),
    txt(" · "),
    el(Time, attrs=[attr("data-since", "\{now - item.age_ms}")], children=[
      txt(duration_label(item.age_ms)),
    ]),
  ]
  if !item.pids.is_empty() {
    meta.push(txt(" · pid \{pid_text(item.pids)}"))
  }
  let head : Array[Node] = [
    el(Span, attrs=[cls("label"), attr("title", item.label)], children=[
      txt(item.label),
    ]),
    el(
      Button,
      attrs=[
        cls("stop"),
        attr("type", "button"),
        attr("data-kill", item.id),
        attr("title", "stop this job and everything it started"),
      ],
      children=[txt("Kill")],
    ),
  ]
  let children : Array[Node] = [
    el(Div, attrs=[cls("row")], children=head),
    el(Div, attrs=[cls("tool")], children=meta),
  ]
  el(Div, attrs=[cls("task")], children~)
}

///|
/// A duration the way a reader says it.
pub fn duration_label(ms : Int64) -> String {
  let seconds = ms / 1000L
  if seconds < 60L {
    "\{seconds}s"
  } else if seconds < 3600L {
    "\{seconds / 60L}m \{seconds % 60L}s"
  } else {
    "\{seconds / 3600L}h \{(seconds % 3600L) / 60L}m"
  }
}

///|
fn pid_text(pids : Array[Int]) -> String {
  let out = StringBuilder()
  for pid in pids {
    if out.to_string() != "" {
      out.write_string(", ")
    }
    out.write_string("\{pid}")
  }
  out.to_string()
}
