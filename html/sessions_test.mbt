///|
/// The sidebar.
///
/// The assertions are about structure rather than looks: which workspace is open,
/// what a click carries, and that a workspace with more sessions than the sidebar
/// shows says so instead of quietly dropping them. Rendering is the one place where
/// a wrong attribute adds a feature that does not work, and no type catches it.

///|
fn session(path : String, label : String, current : Bool) -> SessionItem {
  { path, label, modified: 1_700_000_000_000L, current, running: false, }
}

///|
fn workspace(
  cwd : String,
  active : Bool,
  sessions : Array[SessionItem],
  hidden : Int,
) -> WorkspaceItem {
  let name = match cwd.rev_find("/") {
    Some(index) => cwd[index + 1:].to_owned()
    None => cwd
  }
  { cwd, name, title: None, active, sessions, hidden, }
}

///|
fn count_of(text : String, needle : String) -> Int {
  let mut count = 0
  let mut rest = text
  while true {
    match rest.find(needle) {
      Some(index) => {
        count += 1
        rest = rest[index + needle.length():].to_owned()
      }
      None => break
    }
  }
  count
}

///|
test "each workspace is a details element, open only when active" {
  let html = render_sessions(
    [
      workspace("/work/one", true, [session("/a.jsonl", "first", true)], 0),
      workspace("/work/two", false, [session("/b.jsonl", "second", false)], 0),
    ],
    1_700_000_000_000L,
    false,
  ).render()
  assert_eq(count_of(html, "<details"), 2)
  // Exactly one workspace is open, and it is the active one.
  assert_eq(count_of(html, " open"), 1)
  assert_true(html.contains("class=\"workspace active\" open"), msg=html)
  assert_true(html.contains("class=\"workspace\">"), msg=html)
  assert_true(html.contains(">one<"), msg=html)
  assert_true(html.contains(">two<"), msg=html)
  // The full path is available as a tooltip, since only the last component is shown.
  assert_true(html.contains("title=\"/work/one\""), msg=html)
}

///|
test "a click carries what the server needs to act on" {
  let html = render_sessions(
    [
      workspace(
        "/work/one",
        true,
        [
          session("/store/x.jsonl", "a question", true),
          session("/store/y.jsonl", "another", false),
        ],
        0,
      ),
    ],
    1_700_000_000_000L,
    false,
  ).render()
  assert_true(html.contains("data-session=\"/store/x.jsonl\""), msg=html)
  assert_true(html.contains("data-session=\"/store/y.jsonl\""), msg=html)
  // "New session here" names the workspace it belongs to.
  assert_true(html.contains("data-new=\"/work/one\""), msg=html)
  // The current session is the marked one.
  assert_eq(count_of(html, "class=\"session current\""), 1)
  assert_true(html.contains("a question"), msg=html)
}

///|
/// A session is one line, and the parts of it are in that line: the label and the age inside the
/// control that opens it, the two actions beside it. This is the shape the stylesheet hangs off —
/// the age gives up its place to the actions under the pointer — so it is asserted here rather
/// than left to a browser run to notice.
test "a session is one line: label, age, then the actions" {
  let html = render_sessions(
    [
      workspace(
        "/work/one",
        true,
        [session("/store/a.jsonl", "a question", true)],
        0,
      ),
    ],
    1_700_000_000_000L,
    false,
  ).render()
  // One row per session, not a row plus something under it.
  assert_eq(count_of(html, "<li"), 1)
  let open_at = match html.find("data-session=\"/store/a.jsonl\"") {
    Some(at) => at
    None => -1
  }
  let open_end = match html[open_at:].find("</button>") {
    Some(at) => open_at + at
    None => -1
  }
  assert_true(open_at >= 0 && open_end > open_at, msg=html)
  let inside = html[open_at:open_end].to_owned()
  assert_true(inside.contains("class=\"label\""), msg=inside)
  assert_true(inside.contains("class=\"age\""), msg=inside)
  assert_true(inside.contains("just now"), msg=inside)
  // The actions are outside it, or clicking delete would also open the session.
  let after = html[open_end:].to_owned()
  assert_true(after.contains("class=\"acts\""), msg=html)
  assert_true(after.contains("data-delete=\"/store/a.jsonl\""), msg=html)
  assert_true(after.contains("data-rename"), msg=html)
  // The label is what the age would otherwise be confused for: a name, not a time.
  assert_true(inside.contains("a question"), msg=inside)
}

///|
/// A session with nothing in it yet reads as a name rather than as a gap. The row is clickable,
/// nameable and deletable like any other, and a blank in the list reads as one that failed to load.
test "a session with no first message still has a name" {
  let html = render_sessions(
    [workspace("/work/one", true, [session("/a.jsonl", "", true)], 0)],
    1_700_000_000_000L,
    false,
  ).render()
  assert_true(
    html.contains("<span class=\"label\">New session</span>"),
    msg=html,
  )
  assert_false(html.contains("(empty session)"), msg=html)
}

///|
/// Every workspace offers a new session, and says which one it is. A folded workspace hides its
/// own, which is the point of folding; the open one has to have it, or a reader with one project
/// has no visible way to start a conversation.
test "each workspace offers a new session in its own name" {
  let html = render_sessions(
    [
      workspace("/work/one", true, [session("/a.jsonl", "first", true)], 0),
      workspace("/work/two", false, [session("/b.jsonl", "second", false)], 0),
    ],
    1_700_000_000_000L,
    false,
  ).render()
  assert_eq(count_of(html, "data-new="), 2)
  assert_true(html.contains("data-new=\"/work/one\""), msg=html)
  assert_true(html.contains("data-new=\"/work/two\""), msg=html)
  // Identical visible copy is fine when the position says which project it belongs to; the
  // accessible name is what has to be unambiguous.
  assert_true(html.contains("aria-label=\"new session in one\""), msg=html)
  assert_true(html.contains("aria-label=\"new session in two\""), msg=html)
}

///|
test "sessions beyond the cap are offered, not dropped silently" {
  let html = render_sessions(
    [workspace("/work/one", true, [session("/a.jsonl", "first", true)], 4)],
    1_700_000_000_000L,
    false,
  ).render()
  // A count alone is a dead end: what the reader needs is the way to the other four.
  assert_true(html.contains("data-more=\"/work/one\""), msg=html)
  assert_true(html.contains(">Show 4 more<"), msg=html)
  assert_true(
    html.contains("aria-label=\"show 4 more sessions in one\""),
    msg=html,
  )
  // Nothing to offer when everything is listed.
  let complete = render_sessions(
    [workspace("/work/one", true, [session("/a.jsonl", "first", true)], 0)],
    1_700_000_000_000L,
    false,
  ).render()
  assert_false(complete.contains("data-more"), msg=complete)
}

///|
test "an empty store says so" {
  let html = render_sessions([], 1_700_000_000_000L, false).render()
  assert_true(html.contains("no saved sessions yet"), msg=html)
  assert_true(html.contains("id=\"sessions\""), msg=html)
}

///|
test "ages are relative to the time they are rendered at" {
  let now : Int64 = 1_700_000_000_000L
  assert_eq(age_label(now, now), "just now")
  assert_eq(age_label(now - 5L * 60_000L, now), "5m ago")
  assert_eq(age_label(now - 3L * 3_600_000L, now), "3h ago")
  assert_eq(age_label(now - 2L * 86_400_000L, now), "2d ago")
  // A clock that went backwards must not render a negative age.
  assert_eq(age_label(now + 60_000L, now), "just now")
}

///|
/// Labels are escaped wherever they come from user input: a session whose first
/// message contains markup must not be able to change the page.
test "a session label is escaped" {
  let html = render_sessions(
    [
      workspace(
        "/work/one",
        true,
        [session("/a.jsonl", "<script>alert(1)</script>", true)],
        0,
      ),
    ],
    1_700_000_000_000L,
    false,
  ).render()
  assert_false(html.contains("<script>"), msg=html)
  assert_true(html.contains("&lt;script&gt;"), msg=html)
}

///|
/// A session with a turn running is marked, wherever it is: with sessions running in
/// parallel, the one being looked at is not necessarily the one doing work.
test "a running session is marked in the list" {
  let running : SessionItem = {
    path: "/a.jsonl",
    label: "working on something",
    modified: 1_700_000_000_000L,
    current: false,
    running: true,
  }
  let html = render_sessions(
    [
      workspace(
        "/work/one",
        true,
        [running, session("/b.jsonl", "idle", false)],
        0,
      ),
    ],
    1_700_000_000_000L,
    false,
  ).render()
  assert_true(html.contains("class=\"session running\""), msg=html)
  assert_eq(count_of(html, "class=\"dot\""), 1)
  // Marked without pretending it is the current one.
  assert_false(html.contains("session current"), msg=html)
}

///|
/// The transcript says which session it is, which is what lets the browser ignore patches
/// belonging to another one — under an attribute that does *not* also mean "clicking this switches
/// to that session", which is what `data-session` means to the sidebar.
test "a transcript carries its session" {
  let messages : Array[@core.ContextMessage] = []
  let html = render_transcript(messages, session="/store/one.jsonl").render()
  assert_true(
    html.contains("data-shown-session=\"/store/one.jsonl\""),
    msg=html,
  )
  assert_false(html.contains("data-session="), msg=html)
}

///|
/// The workspace rows carry whatever the reader called them, and the add row is present so a new
/// project can be opened without leaving the page.
test "a titled workspace and the add row" {
  let titled = WorkspaceItem::{
    cwd: "/Users/x/src/app",
    name: "app",
    title: Some("the app"),
    active: false,
    sessions: [],
    hidden: 0,
  }
  let html = render_sidebar([
    el(Div, attrs=[attr("id", "tasks")], children=[]),
    frag([
      render_sessions([titled], 1_700_000_000_000L, false),
      render_add_workspace(false),
    ]),
  ]).render()
  assert_true(html.contains(">the app<"), msg=html)
  // The path stays reachable even when a title is shown instead.
  assert_true(html.contains("title=\"/Users/x/src/app\""), msg=html)
  assert_true(html.contains("id=\"add-workspace\""), msg=html)
  assert_true(html.contains("placeholder=\"/path/to/project\""), msg=html)
}

///|
/// One way in, not two: the chooser where there is one, the path field where there is not.
///
/// The reader who does not know the path by heart is the one this row is for, and a dialog answers
/// them outright — a field beside it is a second way to answer a question that is already answered.
/// The field is not a fallback that can rot: over SSH it is the only way in.
test "one way in: the chooser, or the field where there is no chooser" {
  let offered = render_add_workspace(true).render()
  assert_true(offered.contains("id=\"workspace-pick\""), msg=offered)
  assert_true(offered.contains("Add workspace"), msg=offered)
  // One control, so no field beside it and no form at all: there is nothing here that could be
  // submitted with a half-typed path.
  assert_false(offered.contains("id=\"workspace-path\""), msg=offered)
  assert_false(offered.contains("<form"), msg=offered)
  assert_true(offered.contains("type=\"button\""), msg=offered)
  // Without a chooser: no button, and the path field is the whole row.
  let typed = render_add_workspace(false).render()
  assert_false(typed.contains("id=\"workspace-pick\""), msg=typed)
  assert_true(typed.contains("id=\"workspace-path\""), msg=typed)
  assert_true(typed.contains("id=\"add-workspace\""), msg=typed)
}

///|
/// The add row is the first thing in the list, above the workspaces it could add to.
///
/// A reader with no saved workspace sees the way in before the emptiness, and a reader with twenty
/// does not have to scroll past them to find it.
test "the add row comes before the workspaces" {
  let html = render_sessions(
    [workspace("/work/one", true, [session("/a.jsonl", "first", true)], 0)],
    1_700_000_000_000L,
    true,
  ).render()
  let add = match html.find("id=\"workspace-pick\"") {
    Some(at) => at
    None => -1
  }
  let list = match html.find("class=\"workspace active\"") {
    Some(at) => at
    None => -1
  }
  assert_true(add >= 0 && list >= 0 && add < list, msg=html)
}

///|
/// The offer to undo a delete stands for five seconds and then is not rendered at all.
///
/// Freshness is decided here rather than by a timer elsewhere, because the panel is redrawn for
/// reasons that have nothing to do with the delete — a turn starting in another session — and a
/// notice whose lifetime lived outside the state would come back on the next redraw.
test "the undo offer expires" {
  let now = 1_700_000_000_000L
  let notice : DeletedNotice = {
    path: "/store/x.jsonl",
    label: "gone",
    at: now,
  }
  let fresh = render_sessions([], now + 4999L, true, notice=Some(notice)).render()
  assert_true(fresh.contains("data-undo=\"/store/x.jsonl\""), msg=fresh)
  assert_true(fresh.contains("Deleted gone"), msg=fresh)
  let stale = render_sessions(
    [],
    now + undo_window_ms(),
    true,
    notice=Some(notice),
  ).render()
  assert_false(stale.contains("data-undo="), msg=stale)
  // Not an empty box left behind: the whole line goes, which is the point of expiring it.
  assert_false(stale.contains("Deleted gone"), msg=stale)
  // And with nothing deleted there is nothing to show.
  assert_false(
    render_sessions([], now, true).render().contains("data-undo="),
    msg="a notice should not appear from nowhere",
  )
}

///|
/// The fold-away control has to be inside the sidebar, because that is the one region a refresh
/// does not replace — put it in the bar and it would be rebuilt, and its open state thrown away,
/// on every turn. This pins the placement rather than the styling.
test "the sidebar carries the navigation toggle, ahead of the regions" {
  let html = render_sidebar([
    el(Div, attrs=[attr("id", "sessions")], children=[]),
  ]).render()
  assert_true(
    html.contains("id=\"nav-toggle\""),
    msg="the narrow-screen fold has no control: \{html}",
  )
  assert_true(html.contains("aria-expanded=\"false\""), msg=html)
  // Ahead of the regions, so it is the first thing reachable when everything else is folded.
  let toggle_at = match html.find("nav-toggle") {
    Some(at) => at
    None => -1
  }
  let sessions_at = match html.find("id=\"sessions\"") {
    Some(at) => at
    None => -1
  }
  assert_true(
    toggle_at >= 0 && sessions_at >= 0 && toggle_at < sessions_at,
    msg=html,
  )
}
