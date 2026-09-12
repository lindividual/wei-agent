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
          el("button", attrs=[
            cls("stop"),
            attr("type", "button"),
            attr("data-stop", item.path),
            attr("title", "stop this session"),
          ], children=[txt("Stop")]),
        ]),
        el("div", attrs=[cls("tool")], children=meta),
      ]),
    )
  }
  // Nothing running: an empty container, not an empty heading. A section that is usually
  // empty should not take up space or attention.
  el("div", attrs=[attr("id", "tasks")], children=if rows.is_empty() {
    []
  } else {
    [panel("Running", rows)]
  })
}
