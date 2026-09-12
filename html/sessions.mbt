///|
/// The session sidebar.
///
/// A picker, not a manager: no renaming, no deleting, no reordering. What it has to
/// answer is "which of these is the conversation I was in" for every directory this
/// store knows about, which means a label from the first thing the user asked, how
/// long ago that was, and which session and workspace are open.
///
/// Folding is the browser's job: each workspace is a native `<details>`, so the
/// sidebar holds no state of its own and a collapsed workspace costs nothing until
/// it is opened.

///|
/// One saved session as the sidebar shows it.
pub(all) struct SessionItem {
  /// Absolute path, and what a click sends back — the identity used for opening is
  /// the file, not the id, because a store can hold copies.
  path : String
  /// First user message, already collapsed to one line. Empty for a session that
  /// holds nothing but settings.
  label : String
  /// Last write, in milliseconds since the epoch. Used for age and for order.
  modified : Int64
  current : Bool
  /// True while a turn is running in this session, whether or not it is the one being
  /// looked at. With sessions running in parallel this is the only way to know that
  /// something is still happening somewhere else.
  running : Bool
} derive(Eq, Debug)

///|
/// One working directory as the sidebar shows it.
pub(all) struct WorkspaceItem {
  /// The directory the agent works in, and what "new session here" sends back.
  cwd : String
  /// Last path component, for the label.
  name : String
  /// True for the workspace the agent is in right now.
  active : Bool
  /// Newest first.
  sessions : Array[SessionItem]
  /// Sessions the workspace holds beyond the ones listed, so the sidebar can say
  /// so instead of silently showing a fraction of them.
  hidden : Int
} derive(Eq, Debug)

///|
/// The sidebar.
///
/// `now` is passed in rather than read here, so the rendered output is a function
/// of its arguments and the relative ages can be tested without a clock.
pub fn render_sessions(workspaces : Array[WorkspaceItem], now : Int64) -> Node {
  let body : Array[Node] = []
  for workspace in workspaces {
    body.push(render_workspace(workspace, now))
  }
  if body.is_empty() {
    body.push(
      el("div", attrs=[cls("empty")], children=[txt("no saved sessions yet")]),
    )
  }
  el("div", attrs=[attr("id", "sessions")], children=body)
}

///|
/// The sidebar holds two independent regions: what is running, and what exists. They change
/// for different reasons — a tool starting versus a session being written — so they are
/// replaced separately rather than as one block.
pub fn render_sidebar(tasks : Node, sessions : Node) -> Node {
  el("aside", attrs=[cls("sidebar")], children=[tasks, sessions])
}

///|
fn render_workspace(workspace : WorkspaceItem, now : Int64) -> Node {
  let rows : Array[Node] = []
  for item in workspace.sessions {
    let mut classes = if item.current { "session current" } else { "session" }
    if item.running {
      classes = "\{classes} running"
    }
    let children : Array[Node] = [
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
    ]
    if item.running {
      // A dot rather than text: it has to be legible at a glance from any workspace.
      children.push(
        el("span", attrs=[cls("dot"), attr("title", "running")], children=[]),
      )
    }
    children.push(
      el("div", attrs=[cls("meta")], children=[
        txt(age_label(item.modified, now)),
      ]),
    )
    rows.push(el("li", attrs=[cls(classes)], children~))
  }
  let children : Array[Node] = [
    el("summary", attrs=[attr("title", workspace.cwd)], children=[
      // The name is a span so it can be ellipsised: a `summary` is a list item, and
      // text overflow only applies to the box the text is actually in.
      el("span", attrs=[cls("name")], children=[txt(workspace.name)]),
    ]),
    el(
      "button",
      attrs=[
        cls("new"),
        attr("type", "button"),
        attr("data-new", workspace.cwd),
        attr("title", "new session in \{workspace.cwd}"),
      ],
      children=[txt("+ new session")],
    ),
    el("ul", children=rows),
  ]
  if workspace.hidden > 0 {
    children.push(
      el("div", attrs=[cls("meta")], children=[
        txt("… \{workspace.hidden} older"),
      ]),
    )
  }
  // The active workspace is open because it is the one being looked at; the others
  // are folded away, and the browser remembers whichever the reader opens.
  let attrs : Array[Attr] = [
    cls(if workspace.active { "workspace active" } else { "workspace" }),
  ]
  if workspace.active {
    attrs.push(attr("open", ""))
  }
  el("details", attrs~, children~)
}

///|
/// How long ago something was written, in the roughest unit that is still true.
///
/// Relative rather than absolute on purpose: the file name records UTC, the reader
/// is somewhere else, and "ago" needs no timezone to be right.
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
