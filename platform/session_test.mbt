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
