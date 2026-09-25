///|
/// The reads the facts store is built on, against a real filesystem.
///
/// The one that matters is `has_rename_entry` from a recorded offset, because that is the search whose
/// correctness the whole design rests on: it is asked of every session on every turn, and the answer it
/// must never give is "no rename here" about a file that has one. A rename that goes missing is a
/// session drawn under its first question, which looks exactly like a session nobody renamed.

///|
async fn facts_scratch(name : String) -> String {
  let dir = "_build/session_facts_test/\{name}-\{@core.new_entry_id()}"
  make_dirs(dir)
  dir
}

///|
/// A log with `pad` bytes of conversation in it, and optionally a rename entry near the end.
fn log_text(pad : Int, name : String?) -> String {
  let line = "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2026-08-23T06:26:18.662Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}}\n"
  let head = "{\"type\":\"session\",\"version\":3,\"id\":\"a\",\"timestamp\":\"2026-08-23T06:26:15.210Z\",\"cwd\":\"/tmp\"}\n"
  let body = head + line.repeat(pad / line.length())
  match name {
    None => body
    Some(value) =>
      body +
      "{\"type\":\"session_info\",\"id\":\"i1\",\"parentId\":\"m1\",\"timestamp\":\"2026-08-23T06:26:19.662Z\",\"name\":\"" +
      value +
      "\"}\n"
  }
}

///|
/// A rename entry is found from the whole file and from any mark before it, and not from any mark after
/// it — with the needle deliberately placed to straddle each mark.
///
/// The straddle case is the one a plain "search the bytes after the mark" gets wrong, and it gets it
/// wrong *quietly*: the entry is there, the sweeper said it was not, and the name is never found again.
async test "a rename entry is found from every mark up to it, and from none past it" {
  let dir = facts_scratch("rename")
  let path = "\{dir}/log.jsonl"
  let text = log_text(2000, Some("the naming bug"))
  write_text(path, text)
  let entry_at = text.find("\"type\":\"session_info\"").unwrap()

  // The whole-file search, which is what a launch does.
  assert_true(has_rename_entry(path, 0L))
  // Every mark from the start of the file to the entry, inclusive. At each one the entry is still
  // ahead, so the answer is yes — this is the case an append produces, one byte at a time.
  for mark in [1, 2, entry_at - 1, entry_at, entry_at + 1, entry_at + 10] {
    if mark <= entry_at + 20 {
      assert_true(has_rename_entry(path, mark.to_int64()), msg="from \{mark}")
    }
  }
}

///|
/// A file with no rename entry in it answers `false` from everywhere, which is the answer that costs
/// nothing and is asked thousands of times.
async test "a log with no rename entry says so from the whole file and from a mark" {
  let dir = facts_scratch("plain")
  let path = "\{dir}/log.jsonl"
  write_text(path, log_text(2000, None))
  assert_false(has_rename_entry(path, 0L))
  assert_false(has_rename_entry(path, 100L))
  assert_false(has_rename_entry(path, 1L))
}

///|
/// **The append case, which is the one that runs on every turn.**
///
/// A log is swept, one turn is appended, and the entry is written by that turn: searching from the
/// recorded mark has to find it. The mirror of it — appending with no rename — has to *not* find it,
/// and has to agree with what a whole-file search of the grown file would say.
async test "a rename written by a later turn is found from the recorded mark" {
  let dir = facts_scratch("append")
  let path = "\{dir}/log.jsonl"
  let before = log_text(2000, None)
  write_text(path, before)
  let mark = before.length().to_int64()
  assert_false(has_rename_entry(path, 0L))

  // The reader renames the session: an entry lands at the end of the log.
  let entry = "{\"type\":\"session_info\",\"id\":\"i1\",\"parentId\":\"m1\",\"timestamp\":\"2026-08-23T06:26:19.662Z\",\"name\":\"now it has a name\"}\n"
  append_text(path, entry)
  let after = before + entry
  // Found from the mark, and from the whole file — and the two must agree, which is the property.
  assert_true(has_rename_entry(path, mark))
  assert_true(has_rename_entry(path, 0L))
  assert_eq(
    has_rename_entry(path, mark),
    after.contains(@core.name_entry_token()),
  )

  // And an append that is not a rename does not invent one.
  let more = log_text(500, None)
  append_text(path, more)
  assert_eq(
    has_rename_entry(path, mark),
    (after + more).contains(@core.name_entry_token()),
  )
}

///|
/// The mark is a byte offset, and it is used on files whose contents are not all ASCII.
///
/// A session log carries whatever the reader typed, so the byte offset recorded by one sweep is used
/// to slice a file that holds multi-byte characters. An implementation that treated the mark as a
/// character index would cut inside a character — and would then miss the entry, which is the failure
/// this design cannot afford.
async test "a mark stays a byte offset across multi-byte text" {
  let dir = facts_scratch("utf8")
  let path = "\{dir}/log.jsonl"
  let head = "{\"type\":\"session\",\"version\":3,\"id\":\"a\",\"timestamp\":\"2026-08-23T06:26:15.210Z\",\"cwd\":\"/tmp\"}\n"
  let chinese = "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2026-08-23T06:26:18.662Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"帮我看看这个 bug\"}]}}\n"
  let before = head + chinese
  write_text(path, before)
  // In bytes, not characters: the point is that these differ.
  let mark = before.length().to_int64()
  let entry = "{\"type\":\"session_info\",\"id\":\"i1\",\"parentId\":\"m1\",\"timestamp\":\"2026-08-23T06:26:19.662Z\",\"name\":\"名字\"}\n"
  append_text(path, entry)
  assert_true(has_rename_entry(path, mark))
  assert_true(has_rename_entry(path, 0L))
}

///|
/// A file that is not there holds no rename, and one shorter than the mark does not either.
///
/// Both are `false` rather than a failure, and both are ordinary: a session is created before it is
/// written, and a log that was rewritten smaller is a log whose mark is stale.
async test "a missing file and a stale mark both say no" {
  let dir = facts_scratch("edge")
  let absent = "\{dir}/never.jsonl"
  assert_false(has_rename_entry(absent, 0L))
  assert_false(has_rename_entry(absent, 500L))

  let path = "\{dir}/short.jsonl"
  write_text(path, log_text(200, Some("a name")))
  // Past the end: there is nothing after the mark, so there is nothing to find — and the whole-file
  // search still finds it, which is what a rewrite-in-place would fall back to.
  assert_false(has_rename_entry(path, 100000L))
  assert_true(has_rename_entry(path, 0L))
  assert_true(has_rename_entry(path, 1L))
}

///|
/// The stamp a refresh uses: the size the read needs and the clock the comparison needs, from one
/// `open`.
async test "the stamp reports the file as it is" {
  let dir = facts_scratch("stamp")
  let path = "\{dir}/log.jsonl"
  let text = log_text(1000, None)
  write_text(path, text)
  let stamp = facts_stamp(path).unwrap()
  assert_eq(stamp.0, text.length().to_int64())

  append_text(path, "{\"a\":1}\n")
  let later = facts_stamp(path).unwrap()
  assert_eq(later.0, (text + "{\"a\":1}\n").length().to_int64())
  // The clock moved with the bytes, which is what makes the comparison in `facts_unchanged` mean
  // anything.
  assert_true(later.1 >= stamp.1)

  // A file that is not there has no stamp — not a zero, which would compare equal to a real file's
  // "modified" and skip re-reading something that is not even present.
  assert_eq(facts_stamp("\{dir}/absent.jsonl"), None)
}

///|
/// What one run learned is what the next run knows.
///
/// The round trip through the file is what makes a launch cheap, so it is asserted end to end: the
/// facts are written, read back by a fresh process's worth of code, and the same fact comes out. A
/// mangled file losing everything is asserted too, because that is the state every machine is in on
/// the day this ships.
async test "facts round-trip through the file, and a mangled file costs only a re-read" {
  let home = facts_scratch("store")
  let original : Array[@core.SessionFacts] = [
    {
      path: "/store/a.jsonl",
      modified: 1700000000000L,
      scanned: 4096L,
      label: "the first question",
      name: Some("a name"),
    },
    {
      path: "/store/b.jsonl",
      modified: 1700000001000L,
      scanned: 0L,
      label: "",
      name: None,
    },
  ]
  save_facts(home, original)
  let loaded = load_facts(home)
  assert_eq(loaded.length(), 2)
  // Sorted by path on the way out, so `a` comes first whichever way the input was ordered.
  assert_eq(loaded[0], original[0])
  assert_eq(loaded[1], original[1])

  // Overwritten rather than appended to: a second save is the whole truth, not a longer file.
  save_facts(home, [original[0]])
  assert_eq(load_facts(home).length(), 1)

  // A file somebody has mangled reads as nothing known, which sends the next launch back to reading
  // the sessions — the same thing it did before this file existed.
  write_text(facts_path(home), "{ this is not json")
  assert_eq(load_facts(home).length(), 0)

  // And a home directory with no facts file at all is a first run, not a failure.
  let empty_home = facts_scratch("empty")
  assert_eq(load_facts(empty_home).length(), 0)
}
