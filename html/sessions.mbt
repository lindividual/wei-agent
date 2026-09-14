///|
/// The session sidebar.
///
/// A picker, not a manager: no renaming, no deleting, no reordering. What it has to
/// answer is "which of these is the conversation I was in" for every directory this
/// store knows about, which means a label from the first thing the user asked, how
/// long ago that was, and which session and workspace are open.
///
/// One session is one line — label on the left, age on the right, actions revealed
/// under the pointer — so the list stays scannable at twenty rows the way it is at
/// three. The row is the unit the reader compares, so the row is what carries the
/// selection: the open session is filled, nothing else is.
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
  /// What the reader calls it, when they have said. Replaces `name` in the label.
  title : String?
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
///
/// `can_pick` says whether this host can open a folder chooser. It is an argument rather than a
/// second `WorkspaceItem`-like fact because it belongs to the *row*, not to any workspace: one
/// process, one answer.
pub fn render_sessions(
  workspaces : Array[WorkspaceItem],
  now : Int64,
  can_pick : Bool,
  /// The session deleted most recently, if any, so the list can offer it back.
  notice? : DeletedNotice? = None,
) -> Node {
  let body : Array[Node] = []
  // First, above every workspace it could add to: the list below it is the answer to the same
  // question, and a reader who has no workspace at all sees the way in before the emptiness.
  body.push(render_add_workspace(can_pick))
  for workspace in workspaces {
    body.push(render_workspace(workspace, now))
  }
  if workspaces.is_empty() {
    body.push(
      el(Div, attrs=[cls("empty")], children=[txt("no saved sessions yet")]),
    )
  }
  // Last, and only while it is fresh. It is about a row that was *just* here, and the eye is at the
  // row it was on — the end of the list is where a reader who deleted something and changed their
  // mind will be looking. It goes away on its own; see `render_deleted`.
  match notice {
    Some(deleted) if still_undoable(deleted, now) =>
      body.push(render_deleted(Some(deleted)))
    _ => ()
  }
  el(Div, attrs=[attr("id", "sessions")], children=body)
}

///|
/// The row that adds a workspace.
///
/// One control, not two. Where the host can open a folder chooser, that is the whole row: it is
/// what a reader who does not know the path by heart needs, and a path field beside it is a second
/// way to answer a question the dialog already answers. The field is kept for the hosts that have
/// no chooser — over SSH the browser is on another computer, and a dialog on the server's screen is
/// one nobody in the room can close — and for those it is the only way in, so it is not a fallback
/// that can rot.
pub fn render_add_workspace(can_pick : Bool) -> Node {
  if can_pick {
    return el(Div, attrs=[cls("add-workspace")], children=[
      el(
        Button,
        attrs=[
          attr("type", "button"),
          attr("id", "workspace-pick"),
          cls("add"),
          attr("title", "Choose a folder on this computer"),
        ],
        children=[txt("Add workspace")],
      ),
    ])
  }
  // The form is the path, and Enter in the field submits it the same way the button does.
  el(Div, attrs=[cls("add-workspace")], children=[
    el(Form, attrs=[attr("id", "add-workspace")], children=[
      el(Input, attrs=[
        attr("id", "workspace-path"),
        attr("type", "text"),
        attr("placeholder", "/path/to/project"),
        attr("autocomplete", "off"),
        attr("spellcheck", "false"),
      ]),
      el(Button, attrs=[attr("type", "submit")], children=[txt("Add")]),
    ]),
  ])
}

///|
/// The sidebar holds two independent regions: what is running, and what exists. They change
/// for different reasons — a tool starting versus a session being written — so they are
/// replaced separately rather than as one block.
pub fn render_sidebar(nodes : Array[Node]) -> Node {
  // The fold-away control is part of the sidebar rather than the title line on purpose:
  // the sidebar is the one region a refresh never replaces, so the open/closed state survives a
  // redraw. The bar is rebuilt on every turn and every settings change, and a toggle there would
  // spring shut under the reader's hand.
  let children : Array[Node] = [navigation_toggle()]
  for node in nodes {
    children.push(node)
  }
  el(Aside, attrs=[cls("sidebar")], children~)
}

///|
/// A session that was deleted, so the sidebar can offer to put it back.
pub(all) struct DeletedNotice {
  /// The path it had, which is where `restore` puts it back and what the Undo button carries.
  path : String
  /// What the row called it, so the notice confirms *which* conversation disappeared.
  label : String
  /// When the delete happened, so the offer can stop being shown.
  ///
  /// Carried here rather than left to a timer with a callback: the notice is rendered from state,
  /// and a rule that says "show it for five seconds" has to be part of that state or the next
  /// redraw — which happens on a turn starting somewhere else — brings it back.
  at : Int64
} derive(Eq, Debug)

///|
/// How long the offer to undo a delete stands.
///
/// Long enough to notice a mis-click and act on it, short enough that the line is gone before the
/// next thing the reader does. A permanent offer is a row that has to be dismissed, and there is
/// no gesture here that means "I meant it".
pub fn undo_window_ms() -> Int64 {
  5000L
}

///|
/// Whether the offer is still worth showing — and so whether it is still worth honouring.
///
/// One rule with two callers: this decides whether the line is rendered at all, and the undo route
/// asks it before putting a file back. A page left open past the deadline and a request replayed
/// from a stale tab are the same question, and they must not answer it differently.
pub fn still_undoable(notice : DeletedNotice, now : Int64) -> Bool {
  now - notice.at < undo_window_ms()
}

///|
/// When the offer stops standing, as an absolute time the page can compare against its own clock.
///
/// Absolute rather than a countdown, because the page and the server do not share a clock offset
/// and the page's own `Date.now()` is the one that knows when the reader's second has passed.
fn undo_deadline(notice : DeletedNotice) -> Int64 {
  notice.at + undo_window_ms()
}

///|
/// The line that says what was deleted, with the way back.
///
/// Delete is the one gesture in this sidebar that can lose something, and the choice here was to
/// make it *reversible* rather than *confirmed*. A confirmation dialog taxes every deletion to
/// catch the rare mis-click, and catches less than it looks like: the mistake that actually
/// happens is clicking the wrong row, and by the time the dialog names the session the reader has
/// already stopped reading. Putting the label here instead means the thing they clicked is named
/// at the moment they can still be surprised by it, with the fix one click away.
///
/// It also goes away by itself (`undo_window_ms`). An offer that stays until it is used is a row
/// the reader has to dismiss to be rid of, which is a second decision charged to a gesture they
/// have already finished making.
///
/// The file is renamed rather than removed, so this button is a convenience and not the only way
/// back: the bytes are still on disk under a predictable name, and `restore` is a rename.
///
/// Rendered empty when there is none. The whole list is one patch target, so there is no container
/// here that has to exist for a later delete to land in.
pub fn render_deleted(notice : DeletedNotice?) -> Node {
  let children : Array[Node] = match notice {
    None => []
    Some(deleted) =>
      [
        el(
          Div,
          attrs=[
            cls("undo"),
            // The page takes the line away when this passes. The server stops rendering it on the
            // same rule (`still_undoable`), so a reload after the deadline shows nothing either —
            // this attribute is what makes it go away while the reader is looking at it, without a
            // frame a second from the server to say "still nothing".
            attr("data-expires", "\{undo_deadline(deleted)}"),
          ],
          children=[
            el(Span, attrs=[cls("label"), attr("title", deleted.path)], children=[
              txt("Deleted \{deleted.label}"),
            ]),
            el(
              Button,
              attrs=[
                cls("undo-button"),
                attr("type", "button"),
                attr("data-undo", deleted.path),
              ],
              children=[txt("Undo")],
            ),
          ],
        ),
      ]
  }
  el(Div, attrs=[attr("id", "deleted")], children~)
}

///|
/// The button that folds the navigation away on a screen too narrow to hold it beside the
/// conversation. Hidden by the stylesheet wherever there is room for both.
pub fn navigation_toggle() -> Node {
  el(
    Button,
    attrs=[
      attr("id", "nav-toggle"),
      attr("type", "button"),
      attr("aria-expanded", "false"),
      attr("aria-controls", "sessions"),
    ],
    children=[txt("Sessions")],
  )
}

///|
fn render_workspace(workspace : WorkspaceItem, now : Int64) -> Node {
  let label = match workspace.title {
    Some(title) => title
    None => workspace.name
  }
  let rows : Array[Node] = []
  for item in workspace.sessions {
    rows.push(render_session_row(item, now))
  }
  let children : Array[Node] = [
    el(Summary, attrs=[attr("title", workspace.cwd)], children=[
      // A drawn chevron rather than the browser's disclosure triangle: it turns when the
      // workspace opens, which is the only thing on the header that says the whole group folds.
      el(Span, attrs=[cls("chev"), attr("aria-hidden", "true")], children=[]),
      // The name is a span so it can be ellipsised: a `summary` is a list item, and
      // text overflow only applies to the box the text is actually in.
      el(Span, attrs=[cls("name")], children=[txt(label)]),
    ]),
    // Above the rows, where it holds the same position in every workspace: a control that means
    // "in this project" has to be found the same way whether it is the project being read or not.
    // It folds with the workspace, like everything else that belongs to it.
    //
    // The accessible name carries the workspace, because a column of identical "+ new session"
    // rows — which is what the expanded sidebar becomes — says nothing about where each one
    // creates.
    el(
      Button,
      attrs=[
        cls("new"),
        attr("type", "button"),
        attr("data-new", workspace.cwd),
        attr("title", "new session in \{label}"),
        attr("aria-label", "new session in \{label}"),
      ],
      children=[txt("+ new session")],
    ),
    el(Ul, children=rows),
  ]
  // What the cap left out, and the way to get it. A button rather than a count, because a count
  // tells the reader that sessions exist and offers them nothing: the store is the only thing that
  // can list the rest, and this is the click that asks it to.
  if workspace.hidden > 0 {
    children.push(
      el(
        Button,
        attrs=[
          cls("more"),
          attr("type", "button"),
          attr("data-more", workspace.cwd),
          attr(
            "aria-label",
            "show \{workspace.hidden} more sessions in \{label}",
          ),
        ],
        children=[txt("Show \{workspace.hidden} more")],
      ),
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
  el(Details, attrs~, children~)
}

///|
/// What to call a session nobody has named and nothing has been asked in yet.
///
/// The two places a session is named — the row in the list and the line above the conversation —
/// take this from one function, because they are one answer: a reader who looks at the top of the
/// page and then at the sidebar is checking that they agree, and a second copy of the wording is
/// how they stop agreeing.
///
/// Plain words rather than the id: an id is true of the file and says nothing a reader can act on,
/// and a blank reads as a row that failed to load.
pub fn display_label(label : String) -> String {
  if label == "" {
    "New session"
  } else {
    label
  }
}

///|
/// One session, as a single line: what it is called, how long ago it was, and the two things that
/// can be done to it.
///
/// The age rides the row rather than sitting under it. A second line per session is what makes the
/// list grow taller than the store it describes, and the age is the *second* thing a row answers —
/// it only has to be there once the eye has found the label.
///
/// Rename and delete are revealed under the pointer, in the space the age gives up, the way dsh's
/// session rows behave: a column of ✎ and ✕ on every row is the loudest thing in a sidebar that is
/// mostly being scanned. They are not hidden with `display: none` for the keyboard's sake — see the
/// stylesheet: focusing the row reveals them before the next Tab looks for them. A touch screen,
/// which has no hover, shows them permanently.
fn render_session_row(item : SessionItem, now : Int64) -> Node {
  let mut classes = if item.current { "session current" } else { "session" }
  if item.running {
    classes = "\{classes} running"
  }
  // What the row is called: the reader's own name for it, the first thing they asked, or — for a
  // session with nothing in it yet — plain words. A blank in the list reads as a row that failed to
  // load, and `(empty session)` reads as a placeholder rather than as a row that can be clicked,
  // named and deleted like every row beside it.
  //
  // The same string is the accessible name of its controls, so what a screen reader announces for
  // "delete" is the name the reader can see on the row.
  let named = display_label(item.label)
  let inside : Array[Node] = []
  if item.running {
    // A dot rather than text: it has to be legible at a glance from any workspace. Before the
    // label, which is where the eye already is when it is scanning the list for something
    // happening.
    inside.push(
      el(Span, attrs=[cls("dot"), attr("title", "running")], children=[]),
    )
  }
  inside.push(el(Span, attrs=[cls("label")], children=[txt(named)]))
  inside.push(
    el(Span, attrs=[cls("age")], children=[txt(age_label(item.modified, now))]),
  )
  let row : Array[Node] = [
    el(
      Button,
      attrs=[
        cls("open"),
        attr("type", "button"),
        attr("data-session", item.path),
        attr("title", item.path),
      ],
      children=inside,
    ),
  ]
  let actions : Array[Node] = []
  // Only the session on screen can be renamed from here. `/name` already names the one the reader
  // is in; the control is that command made visible, and offering it on every row would mean a
  // row that has to be opened first — a control whose meaning depends on which row it is on.
  if item.current {
    actions.push(
      el(
        Button,
        attrs=[
          cls("rename"),
          attr("type", "button"),
          attr("data-rename", ""),
          attr("title", "rename this session"),
          attr("aria-label", "rename this session"),
        ],
        children=[txt("✎")],
      ),
    )
  }
  // Delete is on every row, not only the one on screen: clearing out conversations from a week
  // ago is the main reason to want it, and those are not the ones being looked at. It is the one
  // action here that can lose something, so it is made reversible rather than confirmed — see
  // `render_deleted` for why the forgiveness is on the other side of the click.
  //
  // The accessible name says which row, because a screen reader hearing "delete" twenty times
  // down a list learns nothing about which one it is on.
  actions.push(
    el(
      Button,
      attrs=[
        cls("remove"),
        attr("type", "button"),
        attr("data-delete", item.path),
        attr("title", "delete this session"),
        attr("aria-label", "delete \{named}"),
      ],
      children=[txt("✕")],
    ),
  )
  row.push(el(Span, attrs=[cls("acts")], children=actions))
  el(Li, attrs=[cls(classes)], children=row)
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
