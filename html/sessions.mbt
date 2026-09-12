///|
/// The session sidebar.
///
/// A picker, not a manager: no renaming, no deleting, no folding. What it has to
/// do is answer "which of these is the conversation I was in" at a glance, which
/// means a label from the first thing the user asked, how long ago that was, and
/// which one is currently open.

///|
/// One saved session as the sidebar shows it.
pub(all) struct SessionItem {
  /// Absolute path, and what a click sends back — the identity used for opening
  /// is the file, not the id, because a store can hold copies.
  path : String
  /// First user message, already collapsed to one line. Empty for a session that
  /// holds nothing but settings.
  label : String
  /// Last write, in milliseconds since the epoch. Used for age and for order.
  modified : Int64
  current : Bool
} derive(Eq, Debug)

///|
/// The sidebar.
///
/// `now` is passed in rather than read here, so the rendered output is a function
/// of its arguments and the relative ages can be tested without a clock.
pub fn render_sessions(items : Array[SessionItem], now : Int64) -> Node {
  let rows : Array[Node] = []
  for item in items {
    let classes = if item.current { "session current" } else { "session" }
    rows.push(
      el("li", attrs=[cls(classes)], children=[
        el(
          "button",
          attrs=[
            attr("type", "button"),
            attr("data-session", item.path),
            attr("title", item.path),
          ],
          children=[
            txt(if item.label == "" { "(empty session)" } else { item.label }),
          ],
        ),
        el("div", attrs=[cls("meta")], children=[txt(meta_of(item, now))]),
      ]),
    )
  }
  let body : Array[Node] = [
    el("div", attrs=[cls("sidebar-head")], children=[
      el(
        "button",
        attrs=[cls("new"), attr("type", "button"), attr("data-session", "")],
        children=[txt("+ new session")],
      ),
    ]),
  ]
  if rows.is_empty() {
    body.push(
      el("div", attrs=[cls("empty")], children=[txt("no saved sessions yet")]),
    )
  } else {
    body.push(el("ul", children=rows))
  }
  el("aside", attrs=[cls("sidebar"), attr("id", "sessions")], children=body)
}

///|
fn meta_of(item : SessionItem, now : Int64) -> String {
  age_label(item.modified, now)
}

///|
/// How long ago something was written, in the roughest unit that is still true.
///
/// Relative rather than absolute on purpose: the file name records UTC, the
/// reader is somewhere else, and "ago" needs no timezone to be right.
pub fn age_label(modified : Int64, now : Int64) -> String {
  let elapsed = if now > modified { now - modified } else { 0L }
  let seconds = elapsed / 1000L
  if seconds < 60L {
    "just now"
  } else if seconds < 3600L {
    "\{seconds / 60L}m ago"
  } else if seconds < 86400L {
    "\{seconds / 3600L}h ago"
  } else {
    "\{seconds / 86400L}d ago"
  }
}
