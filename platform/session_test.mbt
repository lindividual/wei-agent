///|
/// The session store against a real filesystem.
///
/// The append path is the one worth pinning down: a session log is appended to
/// while other writers may be doing the same, and the failure mode of getting it
/// wrong — silently losing an entry — leaves a file that still parses.
///
/// Scratch directories live under `_build`, which the build already ignores, so a
/// failed test cannot leave anything behind in the repository.

///|
async fn session_scratch(name : String) -> String {
  // Unique rather than merely distinct: the tests run concurrently, and two of
  // them creating a shared parent would race between the existence check and the
  // `mkdir`.
  let dir = "_build/session_test/\{name}-\{@core.new_entry_id()}"
  make_dirs(dir)
  dir
}

///|
fn header(id : String, cwd : String) -> @core.SessionHeader {
  {
    id,
    timestamp: @core.format_iso_utc(1700000000000L),
    cwd,
    parent_session: None,
    version: Some(3),
  }
}

///|
fn user_entry(text : String, parent : String?) -> @core.Entry {
  {
    id: @core.new_entry_id(),
    parent_id: parent,
    timestamp: @core.format_iso_utc(1700000000000L),
    kind: @core.Message(
      message=@core.User({
        content: [@core.Text(text)],
        timestamp: 1700000000000L,
      }),
    ),
  }
}

///|
/// Appending keeps what was already there.
///
/// This is the property the whole log depends on. An implementation that
/// read-modify-writes the file passes every single-writer test and still loses
/// entries the moment two writers overlap, so the assertions are about *both*
/// lines surviving rather than about the last one being right.
async test "append keeps earlier entries" {
  let dir = session_scratch("append")
  let path = "\{dir}/session.jsonl"
  let h = header("abc123", "/tmp")
  create_session(path, h)
  let first = user_entry("first", None)
  append_entry(path, first)
  append_entry(path, user_entry("second", Some(first.id)))

  let text = read_text(path)
  assert_true(text.contains("first"), msg=text)
  assert_true(text.contains("second"), msg=text)
  let session = @core.parse_session_file(text)
  assert_eq(session.entries.length(), 2)
  // The second entry's parent is the first, so the log is a chain rather than
  // two entries that happen to share a file.
  assert_eq(session.leaf_id, Some(session.entries[1].id))
  assert_eq(session.path().length(), 2)
}

///|
/// Several entries in one call land in one append.
async test "append_entries writes a batch" {
  let dir = session_scratch("batch")
  let path = "\{dir}/session.jsonl"
  create_session(path, header("batch1", "/tmp"))
  let entries = [
    user_entry("one", None),
    user_entry("two", None),
    user_entry("three", None),
  ]
  append_entries(path, entries)
  assert_eq(@core.parse_session_file(read_text(path)).entries.length(), 3)
  // An empty batch must not touch the file at all.
  append_entries(path, [])
  assert_eq(@core.parse_session_file(read_text(path)).entries.length(), 3)
}

///|
/// The listing finds session files, newest first, and ignores what is not one.
async test "list_sessions describes a directory" {
  let dir = session_scratch("list")
  let older = "\{dir}/2020-01-01T00-00-00.000Z_old.jsonl"
  let newer = "\{dir}/2030-01-01T00-00-00.000Z_new.jsonl"
  create_session(older, header("old", "/a"))
  create_session(newer, header("new", "/b"))
  // Neither of these is a session: one is not a session file at all, the other is
  // a directory that happens to be named like one.
  write_text("\{dir}/notes.txt", "ignore me")
  make_dirs("\{dir}/nested.jsonl")

  let found = list_sessions(dir)
  assert_eq(found.length(), 2)
  assert_true(found[0].path == newer, msg=found[0].path)
  assert_true(found[1].path == older, msg=found[1].path)
  assert_true(found[0].modified > 0L)
  // A missing directory is an empty list, not a failure: a fresh install has none.
  assert_true(list_sessions("\{dir}/nope").is_empty())
}

///|
/// `--continue` means the newest session for this directory, and only this one.
async test "newest_session is per directory" {
  let dir = session_scratch("newest")
  let mine = "\{dir}/\{@core.session_dir_name("/work/one")}/mine.jsonl"
  make_dirs(@core.parent_of(mine))
  create_session(mine, header("mine", "/work/one"))
  let other = "\{dir}/\{@core.session_dir_name("/work/two")}/other.jsonl"
  make_dirs(@core.parent_of(other))
  create_session(other, header("other", "/work/two"))

  assert_eq(newest_session(dir, "/work/one"), Some(mine))
  assert_eq(newest_session(dir, "/work/three"), None)
}

///|
/// A prefix read stops at the byte limit and still yields usable lines.
async test "read_prefix stops early" {
  let dir = session_scratch("prefix")
  let path = "\{dir}/big.txt"
  let line = "0123456789abcdef\n"
  write_text(path, line + line + line + line)
  let prefix = read_prefix(path, 20)
  assert_eq(prefix, line + "012")
  // Longer than the file is the whole file.
  assert_eq(read_prefix(path, 1000).length(), 4 * line.length())
}

///|
/// The workspace list groups sessions by the directory recorded in their headers,
/// newest workspace first, and leaves the cap to the caller that draws the list.
async test "list_workspaces reads the cwd from the sessions" {
  let root = session_scratch("workspaces")
  // The directory name deliberately does not encode this cwd: the encoding is
  // lossy, so the header is the only trustworthy answer.
  let older = "\{root}/--not-the-real-path--/2020-01-01T00-00-00.000Z_old.jsonl"
  let newer = "\{root}/--also-wrong--/2030-01-01T00-00-00.000Z_new.jsonl"
  make_dirs(@core.parent_of(older))
  make_dirs(@core.parent_of(newer))
  create_session(older, header("old", "/work/one"))
  create_session(newer, header("new", "/work/two"))
  // A directory with no sessions is not a workspace.
  make_dirs("\{root}/--empty--")

  let workspaces = list_workspaces(root)
  assert_eq(workspaces.length(), 2)
  assert_eq(workspaces[0].cwd, "/work/two")
  assert_eq(workspaces[1].cwd, "/work/one")
  assert_eq(workspaces[0].sessions.length(), 1)

  // A directory whose newest session cannot be attributed is skipped rather than
  // listed under a guessed path.
  let broken = "\{root}/--broken--/2031-01-01T00-00-00.000Z_broken.jsonl"
  make_dirs(@core.parent_of(broken))
  write_text(broken, "not json at all\n")
  let after = list_workspaces(root)
  assert_eq(after.length(), 2)
}

///|
async test "list_workspaces lists every session, newest first" {
  let root = session_scratch("all")
  let dir = "\{root}/--work-one--"
  make_dirs(dir)
  for i in 0..<5 {
    create_session(
      "\{dir}/2020-01-0\{i + 1}T00-00-00.000Z_s\{i}.jsonl",
      header("s\{i}", "/work/one"),
    )
  }
  let workspaces = list_workspaces(root)
  assert_eq(workspaces.length(), 1)
  // All five, and the newest first: how many of them a page shows is the page's business, and the
  // test that used to live here was asserting the cap in the wrong layer.
  assert_eq(workspaces[0].sessions.length(), 5)
  assert_true(
    workspaces[0].sessions[0].path.contains("s4.jsonl"),
    msg=workspaces[0].sessions[0].path,
  )
}

///|
/// An id identifies a session without knowing which workspace it lives in, which is
/// what makes `--resume <id>` agree with the sidebar.
async test "find_session searches every workspace" {
  let root = session_scratch("find")
  let one = "\{root}/--work-one--/2020-01-01T00-00-00.000Z_aaaa1111.jsonl"
  let two = "\{root}/--work-two--/2021-01-01T00-00-00.000Z_bbbb2222.jsonl"
  make_dirs(@core.parent_of(one))
  make_dirs(@core.parent_of(two))
  create_session(one, header("aaaa1111", "/work/one"))
  create_session(two, header("bbbb2222", "/work/two"))

  assert_eq(find_session(root, "bbbb2222"), Some(two))
  assert_eq(find_session(root, "aaaa1111"), Some(one))
  // An id that is a suffix of another must not match the wrong file.
  assert_eq(find_session(root, "1111"), None)
  assert_eq(find_session(root, ""), None)
  assert_eq(find_session("\{root}/nope", "aaaa1111"), None)
}

///|
/// The header is written once, with the first entry.
async test "ensure_session writes the header only when it is missing" {
  let dir = session_scratch("ensure")
  let path = "\{dir}/session.jsonl"
  assert_false(path_exists(path))
  ensure_session(path, header("abc", "/tmp"))
  assert_true(path_exists(path))
  let first = read_text(path)
  let entry = user_entry("hello", None)
  append_entry(path, entry)
  // A second call must not rewrite the header over what is already there.
  ensure_session(path, header("another", "/elsewhere"))
  let text = read_text(path)
  assert_true(text.has_prefix(first), msg=text)
  assert_eq(@core.parse_session_file(text).entries.length(), 1)
}

///|
/// Empty sessions are removed, and nothing else is.
async test "prune_empty_sessions removes only stale header-only files" {
  let dir = session_scratch("prune")
  let empty = "\{dir}/2020-01-01T00-00-00.000Z_empty.jsonl"
  let used = "\{dir}/2020-01-02T00-00-00.000Z_used.jsonl"
  let recent = "\{dir}/2020-01-03T00-00-00.000Z_recent.jsonl"
  create_session(empty, header("empty", "/tmp"))
  create_session(used, header("used", "/tmp"))
  append_entry(used, user_entry("a real conversation", None))
  create_session(recent, header("recent", "/tmp"))
  // Backdate the two that are meant to look abandoned. The empty file is only
  // removable because it is old, so the test has to be able to age it.
  for path in [empty, used] {
    ignore(@process.run("touch", ["-t", "202001010000", path]))
  }

  let removed = prune_empty_sessions(dir, 10L * 60L * 1000L)
  // The freshly created one survives even though it is empty: an instance that is
  // mid-session must not have its file deleted from under it.
  assert_eq(removed, 1)
  assert_false(path_exists(empty))
  assert_true(path_exists(recent))
  assert_true(path_exists(used))
  // A missing directory is not an error.
  assert_eq(prune_empty_sessions("\{dir}/nope", 0L), 0)
}

///|
/// A workspace that has been added but not used is still a workspace.
async test "an added workspace is listed before it has sessions" {
  let root = session_scratch("added")
  let dir = "\{root}/--somewhere--"
  write_workspace(dir, { cwd: "/work/added", title: Some("my project"), })
  let found = list_workspaces(root)
  assert_eq(found.length(), 1)
  // The path comes from the marker: with no sessions there are no headers to read it from.
  assert_eq(found[0].cwd, "/work/added")
  assert_eq(found[0].title, Some("my project"))
  assert_true(found[0].sessions.is_empty())

  // Sessions win on ordering, but the marker still supplies the path and the title.
  let session_path = "\{dir}/2020-01-01T00-00-00.000Z_one.jsonl"
  create_session(session_path, header("one", "/work/added"))
  let found = list_workspaces(root)
  assert_eq(found.length(), 1)
  assert_eq(found[0].sessions.length(), 1)
  assert_eq(found[0].title, Some("my project"))

  // A marker nobody can read is ignored rather than turning the listing into a failure.
  let broken = "\{root}/--broken--"
  make_dirs(broken)
  write_text(workspace_marker(broken), "not json")
  assert_eq(list_workspaces(root).length(), 1)
}

///|
/// Adding a workspace canonicalises the path, so the same project reached two ways is one
/// workspace.
async test "canonical_dir resolves and rejects" {
  let dir = session_scratch("canonical")
  let resolved = canonical_dir(dir)
  assert_true(resolved is Some(_), msg="a real directory must resolve")
  match resolved {
    // Resolved means absolute and symlink-free; the directory was created under `_build`, so the
    // resolved path names the same place and ends where it started.
    Some(path) => {
      assert_true(path.has_prefix("/"), msg=path)
      assert_true(path.contains("session_test"), msg=path)
    }
    None => fail("expected a path")
  }
  // A file is not a directory, and neither is a path that does not exist.
  let file = "\{dir}/a.txt"
  write_text(file, "x")
  assert_true(canonical_dir(file) is None)
  assert_true(canonical_dir("\{dir}/nope") is None)
  assert_true(canonical_dir("") is None)
}

///|
/// Deleting renames a session aside rather than removing it, so a mis-click is recoverable by hand.
///
/// This is the whole of the safety argument, and it is worth asserting rather than describing: the
/// file must still be on disk under a predictable name, must be out of `list_sessions` — which is
/// the part that makes it *look* deleted — and must come back unchanged when it is restored.
async test "deleting a session keeps its bytes and takes it out of the listing" {
  let dir = session_scratch("delete")
  make_dirs(dir)
  let path = "\{dir}/2020-01-01T00-00-00.000Z_abc12345.jsonl"
  create_session(path, header("abc12345", "/tmp/x"))
  append_entry(path, user_entry("a question", None))
  // A second file, so "gone from the listing" is distinguishable from "the listing broke".
  let other = "\{dir}/2020-01-02T00-00-00.000Z_def67890.jsonl"
  create_session(other, header("def67890", "/tmp/x"))
  append_entry(other, user_entry("another question", None))

  assert_eq(list_sessions(dir).length(), 2)
  delete_session(path)
  assert_false(path_exists(path), msg="the .jsonl name should be gone")
  assert_true(
    path_exists(path + deleted_suffix()),
    msg="the bytes should still be there, one rename away",
  )
  assert_eq(
    list_sessions(dir).length(),
    1,
    msg="a deleted session must be out of the listing",
  )
  restore_session(path)
  assert_true(path_exists(path), msg="undo should put it back")
  assert_eq(list_sessions(dir).length(), 2)
}

///|
/// Undo is safe to press twice, and safe to press in a tab that is looking at a stale list.
async test "restoring a session that is already back is a no-op" {
  let dir = session_scratch("restore-twice")
  make_dirs(dir)
  let path = "\{dir}/session.jsonl"
  create_session(path, header("abc", "/tmp"))
  append_entry(path, user_entry("kept", None))
  restore_session(path)
  assert_true(
    path_exists(path),
    msg="restoring a live session must not move it",
  )
  let listing = list_sessions(dir)
  assert_eq(listing.length(), 1)
}

///|
/// Removing a project takes its row away and leaves every conversation on disk.
///
/// The two halves of the design are what this pins: the store directory is *renamed* (so all the
/// sessions are still there, one rename away from being back), and the listing is what stops showing
/// it — `list_workspaces` is the only reader that has to know the suffix exists.
async test "removing a project keeps its sessions, and hides them from the listing" {
  let root = session_scratch("workspace-remove")
  let dir = "\{root}/--work--"
  write_workspace(dir, { cwd: "/work", title: None, })
  let one = "\{dir}/2020-01-01T00-00-00.000Z_abc12345.jsonl"
  create_session(one, header("abc12345", "/work"))
  append_entry(one, user_entry("a question", None))
  // A second project, so "out of the listing" is distinguishable from "the listing broke".
  let other = "\{root}/--elsewhere--"
  write_workspace(other, { cwd: "/elsewhere", title: None, })
  assert_eq(list_workspaces(root).length(), 2)

  // What the caller gets back is where the project went, and that is the only way back to it: the
  // listing no longer knows it, so nothing else can find the directory again.
  let aside = match remove_workspace(root, "/work") {
    Some(aside) => aside
    None => fail("a listed project must be removable")
  }
  assert_eq(aside, "\{dir}.removed")
  let left = list_workspaces(root)
  assert_eq(left.length(), 1)
  assert_eq(left[0].cwd, "/elsewhere")
  // The conversation is where it was, under the name the rename produced.
  assert_true(path_exists("\{aside}/\{one.split("/").last().unwrap()}"))
  // And `--resume <id>` agrees with the sidebar: a session in a project the reader has removed is not
  // one the store will find by id.
  assert_true(find_session(root, "abc12345") is None)
  // Removing it again moves nothing, and that is an answer rather than an error — including for a path
  // the store never had.
  assert_true(remove_workspace(root, "/work") is None)
  assert_true(remove_workspace(root, "/never-added") is None)
  // And the other project still comes back, so "not found" is about the ask and not about the store
  // having given up.
  assert_true(remove_workspace(root, "/elsewhere") is Some(_))
}

///|
/// The same, with the checkbox: the directory is emptied as well as unlisted.
///
/// The order is the property worth pinning — the rename happens first, so a removal that fails leaves
/// the reader in the recoverable state rather than a half-emptied project that is still listed.
async test "removing a project with its sessions empties the directory" {
  let root = session_scratch("workspace-delete")
  let dir = "\{root}/--work--"
  write_workspace(dir, { cwd: "/work2", title: None, })
  let one = "\{dir}/2020-01-01T00-00-00.000Z_def67890.jsonl"
  create_session(one, header("def67890", "/work2"))
  append_entry(one, user_entry("a question", None))

  // The two steps a caller takes, in the order that matters: the rename first, then emptying what the
  // rename produced. A failure between them leaves the project out of the list with its conversations
  // on disk — the recoverable half — rather than half emptied and still listed.
  let aside = match remove_workspace(root, "/work2") {
    Some(aside) => aside
    None => fail("a listed project must be removable")
  }
  assert_true(purge_workspace(aside))
  assert_true(list_workspaces(root).is_empty())
  assert_false(
    path_exists(dir),
    msg="the store directory itself should be gone",
  )
  assert_false(path_exists(aside), msg="nothing should be left aside")
  // A path that was never in the store is refused rather than renamed, and a second emptying finds
  // nothing — which the caller has to be told, because its sentence says the conversations are still
  // on disk and that is only true if this answer is honest.
  assert_true(remove_workspace(root, "/work2") is None)
  assert_false(purge_workspace(aside))
}

///|
/// **`path_exists` answers for every path, including the ones that cannot be asked about.**
///
/// `@fs.exists` raises an `OSError` rather than answering `false` when a component of the path is not a
/// directory. Sixty-odd callers here use this as a predicate, and one of them decides whether a fork's
/// write-failure path is reachable at all — it was not, because the stat crash came first
/// (`docs/adr/0010-session-forking.md`, criterion 11).
///
/// The two inputs below are the two shapes of "cannot tell": a path *through* a regular file, and a path
/// under a directory that is not there. Both are answered `no`.
async test "path_exists answers false for a path it cannot even ask about" {
  async fn probe() -> (Bool, Bool, Bool) {
    make_dirs("_build/session_test")
    let file = "_build/session_test/not-a-dir-\{@core.new_entry_id()}"
    write_text(file, "this is a file")
    // A component of the path is a regular file: `stat` fails with ENOTDIR.
    let through_a_file = path_exists(file + "/child.jsonl")
    // A path whose parent was never created: likewise, and this is the one a fresh store hits.
    let missing_parent = path_exists(file + "-nowhere/deeper/still.jsonl")
    // And the ordinary answers are unaffected.
    let the_file_itself = path_exists(file)
    (through_a_file, missing_parent, the_file_itself)
  }
  let (through_a_file, missing_parent, the_file_itself) = probe()
  assert_false(through_a_file)
  assert_false(missing_parent)
  assert_true(the_file_itself)
}
