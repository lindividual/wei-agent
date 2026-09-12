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
/// newest workspace first, and caps how many sessions each one shows.
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

  let workspaces = list_workspaces(root, 10)
  assert_eq(workspaces.length(), 2)
  assert_eq(workspaces[0].cwd, "/work/two")
  assert_eq(workspaces[1].cwd, "/work/one")
  assert_eq(workspaces[0].total, 1)
  assert_eq(workspaces[0].sessions.length(), 1)

  // A directory whose newest session cannot be attributed is skipped rather than
  // listed under a guessed path.
  let broken = "\{root}/--broken--/2031-01-01T00-00-00.000Z_broken.jsonl"
  make_dirs(@core.parent_of(broken))
  write_text(broken, "not json at all\n")
  let after = list_workspaces(root, 10)
  assert_eq(after.length(), 2)
}

///|
async test "list_workspaces caps the sessions it lists but counts them all" {
  let root = session_scratch("cap")
  let dir = "\{root}/--work-one--"
  make_dirs(dir)
  for i in 0..<5 {
    create_session(
      "\{dir}/2020-01-0\{i + 1}T00-00-00.000Z_s\{i}.jsonl",
      header("s\{i}", "/work/one"),
    )
  }
  let workspaces = list_workspaces(root, 2)
  assert_eq(workspaces.length(), 1)
  assert_eq(workspaces[0].sessions.length(), 2)
  assert_eq(workspaces[0].total, 5)
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
  let found = list_workspaces(root, 10)
  assert_eq(found.length(), 1)
  // The path comes from the marker: with no sessions there are no headers to read it from.
  assert_eq(found[0].cwd, "/work/added")
  assert_eq(found[0].title, Some("my project"))
  assert_eq(found[0].total, 0)
  assert_true(found[0].sessions.is_empty())

  // Sessions win on ordering, but the marker still supplies the path and the title.
  let session_path = "\{dir}/2020-01-01T00-00-00.000Z_one.jsonl"
  create_session(session_path, header("one", "/work/added"))
  let found = list_workspaces(root, 10)
  assert_eq(found.length(), 1)
  assert_eq(found[0].total, 1)
  assert_eq(found[0].title, Some("my project"))

  // A marker nobody can read is ignored rather than turning the listing into a failure.
  let broken = "\{root}/--broken--"
  make_dirs(broken)
  write_text(workspace_marker(broken), "not json")
  assert_eq(list_workspaces(root, 10).length(), 1)
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
