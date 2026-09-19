///|
/// The fork, and the file it produces
///
/// `fork` is the first operation in this program that *produces* a session file rather than extending
/// one, which makes it the first that can leave a file looking complete and holding half a
/// conversation. Eleven acceptance criteria were written for it; these are the ones that are about
/// the shell — the rest are `core`'s, and live in `core/session_fork_test.mbt`.

///|
/// A store directory of this test's own, so a fork can be looked for on disk afterwards.
async fn fork_root() -> String {
  let root = "_build/app_test/fork-\{@core.new_entry_id()}"
  @platform.make_dirs(root)
  root
}

///|
/// One session file with one question in it, and the session read back from it.
///
/// Written and re-read rather than built in memory, because what a fork copies is the parent's *label*
/// as well as its entries — and the label comes from the file (`label_of` → `Labels::facts`). A parent
/// built in memory would label as `New Session`, which is the one case that tells nothing about whether
/// the name was computed at all.
async fn parent_on_disk(root : String, question : String) -> @core.Session {
  let path = "\{root}/parent.jsonl"
  let header =
    #|{"type":"session","version":3,"id":"p1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
  inspect(
    @platform.write_session(path, header + "\n" + user_line("m1", question)),
    content="true",
  )
  @platform.load_session(path)
}

///|
/// A fork that cannot happen writes **nothing**, and says so.
///
/// A session nobody has asked anything in has nothing to fork: the copy would be an empty session with a
/// parent recorded, which is a row the reader has to delete. Refused rather than allowed quietly,
/// because a fork that produced an indistinguishable new session is a click that did not work.
async test "forking a session with nothing in it is refused, and writes nothing" {
  let root = fork_root()
  let empty = @core.Session::new(
    {
      id: "e",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [],
  )
  let seen : Array[Json] = []
  let shell = shell_in(root, "\{root}/parent.jsonl", empty, json => {
    seen.push(json)
  })
  shell.fork()
  assert_eq(kinds_of(seen), ["error"])
  inspect(
    text_field(seen[0], "text"),
    content="nothing to fork: this session has no messages yet",
  )
  // **And nothing was produced.** Not a file, not a row: the refusal is the whole of what happened.
  inspect(@platform.list_sessions(root).length(), content="0")
}

///|
/// A fork copies the parent's history into a file of its own, and tells the host **afterwards**.
///
/// The order is the whole of what "先写完再报" asks for — write first, then report — and it is proved
/// by the test below rather than here: a write that fails leaves nothing told, which is only possible if
/// the write came first. What this asserts is that the file exists, that it says where it came from, and
/// that the host was told about the session that was actually written.
async test "a fork's file says where it came from, and names itself after the parent" {
  let root = fork_root()
  let parent_path = "\{root}/parent.jsonl"
  let parent = parent_on_disk(root, "refactor the parser")
  let seen : Array[Json] = []
  let shell = shell_in(root, parent_path, parent, json => seen.push(json))
  shell.fork()
  let lines = seen
  // What the host is told, in order: the new session's rows, then the snapshots that belong to it, then
  // the sentence about the fork, then the list. `history` first is the load-bearing one (the host swaps
  // transcript on the `session` event, and swapping before the rows arrive is a blank column).
  assert_eq(kinds_of(lines), [
    "history", "session", "usage", "models", "think", "images", "status", "sessions",
  ])
  // The session the host was told about is the one on disk, and `history` carries the routing it needs
  // to file those rows under it.
  let child = text_field(lines[0], "session")
  assert_true(child != parent_path, msg="the fork is the parent's path")
  assert_true(@platform.path_exists(child))
  let loaded = @platform.load_session(child)
  assert_eq(loaded.header.parent_session, Some(parent_path))
  // The parent's entries come first, **ids included**, because an entry is referred to by its id (a
  // child's `parent_id`, a tool result's `call_id`) and renumbering would break the chain and the tool
  // results at once. Then the two a fork adds, at the end: the marker that records where this came from
  // and where its own spending starts, and the name.
  assert_eq(loaded.entries.length(), parent.entries.length() + 2)
  for index in 0..<parent.entries.length() {
    assert_eq(loaded.entries[index].id, parent.entries[index].id)
  }
  // Naming, end to end: the parent's *displayed* name is its first question, and the
  // child's is that with the literal prefix — the two rows have to be told apart in the list.
  assert_true(@platform.read_text(child).contains("(fork) refactor the parser"))
  // And the sentence says the one thing the label cannot: the two are now independent.
  inspect(
    text_field_contains(
      lines[6],
      "text",
      "forked from “refactor the parser” · independent from here",
    ),
    content="true",
  )
}

///|
/// **A fork whose file cannot be written says so, and switches nothing.**
///
/// This is the test that pins the write-failure requirement — "*写不进去*: `say_error` + 不切走 + 不留半截行" —
/// and it was not possible before this change. `@platform.write_session` returned `Unit`, so a failed
/// write raised out of `fork`: no sentence for the reader, and a raise that would have taken the command
/// loop's task with it.
///
/// It also proves the *order*: exactly one event came out, and it is the error. Had anything been told to
/// the host before the write, there would be an `open` or a `sessions` in this list — and a list showing
/// a fork that is not on disk is the half-row this criterion exists to forbid.
async test "a fork that cannot be written says so, and leaves nothing half-done" {
  // A store that cannot be written: its parent path is a *file*, so no directory can be created under it.
  @platform.make_dirs("_build/app_test")
  let blocker = "_build/app_test/fork-blocked-\{@core.new_entry_id()}"
  @platform.write_text(blocker, "not a directory")
  let root = "\{blocker}/sessions"
  let parent = @core.Session::new(
    {
      id: "p",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [
      @core.Entry::{
        id: "u1",
        parent_id: None,
        timestamp: @core.format_iso_utc(0L),
        kind: @core.Message(
          message=@core.Message::User({
            content: [@core.Text("hello")],
            timestamp: 0L,
          }),
        ),
      },
    ],
  )
  let seen : Array[Json] = []
  let shell = shell_in(root, "\{root}/parent.jsonl", parent, json => {
    seen.push(json)
  })
  shell.fork()
  let lines = seen
  // One event, and it is the sentence. No `open`, no `sessions`, nothing about a session that does not
  // exist.
  assert_eq(kinds_of(lines), ["error"])
  assert_true(
    text_field(lines[0], "text").contains("could not write the fork"),
    msg="the failure did not say what could not be written",
  )
  // **And the window did not move.** A fork that failed must leave the reader where they were.
  inspect(shell.current, content="\{root}/parent.jsonl")
}
