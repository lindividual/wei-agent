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
test "sessions beyond the cap are counted, not dropped silently" {
  let html = render_sessions(
    [workspace("/work/one", true, [session("/a.jsonl", "first", true)], 4)],
    1_700_000_000_000L,
  ).render()
  // Precise substring: "placeholder" also contains "older", which made this assertion lie.
  assert_true(html.contains("… 4 older</div>"), msg=html)
  // Nothing to say when everything is listed.
  let complete = render_sessions(
    [workspace("/work/one", true, [session("/a.jsonl", "first", true)], 0)],
    1_700_000_000_000L,
  ).render()
  assert_false(complete.contains("older</div>"), msg=complete)
}

///|
test "an empty store says so" {
  let html = render_sessions([], 1_700_000_000_000L).render()
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
  assert_true(html.contains("data-shown-session=\"/store/one.jsonl\""), msg=html)
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
    el("div", attrs=[attr("id", "tasks")], children=[]),
    frag([render_sessions([titled], 1_700_000_000_000L), render_add_workspace()]),
  ]).render()
  assert_true(html.contains(">the app<"), msg=html)
  // The path stays reachable even when a title is shown instead.
  assert_true(html.contains("title=\"/Users/x/src/app\""), msg=html)
  assert_true(html.contains("id=\"add-workspace\""), msg=html)
  assert_true(html.contains("placeholder=\"/path/to/project\""), msg=html)
}
