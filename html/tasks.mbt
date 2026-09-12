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
      el("time", attrs=[attr("data-since", "\{item.since}")], children=[
        txt(age_from(item.since)),
      ]),
    ]
    if item.queued > 0 {
      meta.push(txt(" · \{item.queued} queued"))
    }
    rows.push(
      el("div", attrs=[cls("task")], children=[
        el("div", attrs=[cls("row")], children=[
          el("span", attrs=[cls("label"), attr("title", item.path)], children=[
            txt(label),
          ]),
          el(
            "button",
            attrs=[
              cls("stop"),
              attr("type", "button"),
              attr("data-stop", item.path),
              attr("title", "stop this session"),
            ],
            children=[txt("Stop")],
          ),
        ]),
        el("div", attrs=[cls("tool")], children=meta),
      ]),
    )
  }
  // Nothing running: an empty container, not an empty heading. A section that is usually
  // empty should not take up space or attention.
  el(
    "div",
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
  /// How long it has been running, or how long it ran.
  age_ms : Int64
  /// The processes still alive for it, so a reader can recognise them in `ps`.
  pids : Array[Int]
  live : Bool
  /// How it ended, once it has.
  detail : String
} derive(Eq, Debug)

///|
/// The background panel: nothing at all when nothing is running.
///
/// Separate from the turn panel above it because the two answer different questions: a turn is
/// work the reader is waiting on, a job is work that is still there after they stopped waiting.
/// That second thing is the one that gets forgotten.
pub fn render_jobs(items : Array[JobItem], now : Int64) -> Node {
  let rows : Array[Node] = []
  for item in items {
    let meta : Array[Node] = [
      txt(
        if item.detail == "" {
          item.status
        } else {
          "\{item.status} · \{item.detail}"
        },
      ),
      txt(" · "),
      el("time", attrs=[attr("data-since", "\{now - item.age_ms}")], children=[
        txt(duration_label(item.age_ms)),
      ]),
    ]
    if !item.pids.is_empty() {
      meta.push(txt(" · pid \{pid_text(item.pids)}"))
    }
    let head : Array[Node] = [
      el("span", attrs=[cls("label"), attr("title", item.label)], children=[
        txt(item.label),
      ]),
    ]
    if item.live {
      head.push(
        el(
          "button",
          attrs=[
            cls("stop"),
            attr("type", "button"),
            attr("data-kill", item.id),
            attr("title", "stop this job and everything it started"),
          ],
          children=[txt("Kill")],
        ),
      )
    }
    let children : Array[Node] = [
      el("div", attrs=[cls("row")], children=head),
      el("div", attrs=[cls("tool")], children=meta),
    ]
    rows.push(
      el(
        "div",
        attrs=[cls(if item.live { "task" } else { "task done" })],
        children~,
      ),
    )
  }
  el(
    "div",
    attrs=[attr("id", "jobs")],
    children=if rows.is_empty() { [] } else { [panel("Background", rows)] },
  )
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
