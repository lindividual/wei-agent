///|
/// Session storage and context derivation.
///
/// The fixtures are real lines from `~/.pi/agent/sessions/`, so these tests fail
/// if the model drifts from the format pi actually wrote.

// ── Timestamps ─────────────────────────────────────────────────────────────

///|
test "iso timestamps format and parse" {
  // The epoch, a known round number, and a leap day.
  assert_eq(format_iso_utc(0L), "1970-01-01T00:00:00.000Z")
  assert_eq(format_iso_utc(1000000000000L), "2001-09-09T01:46:40.000Z")
  assert_eq(format_iso_utc(951782400000L), "2000-02-29T00:00:00.000Z")
  // Four-digit years only go so far, but the formatter must not lose the year.
  assert_eq(format_iso_utc(4102444800000L), "2100-01-01T00:00:00.000Z")
}

///|
test "iso parse inverts format" {
  let samples : Array[Int64] = [
    0L, 1000000000000L, 951782400000L, 1780744679375L, 4102444800000L,
  ]
  for ms in samples {
    let text = format_iso_utc(ms)
    match parse_iso_utc(text) {
      Some(back) => assert_eq(back, ms, msg="round trip of \{text}")
      None => fail("could not parse back \{text}")
    }
  }
}

///|
/// A malformed timestamp yields `None` instead of taking the session down with
/// it: the field lives on optional entries that a reader can do without.
test "malformed timestamps are rejected" {
  for
    bad in [
      "", "nope", "2026-06-06", "2026-06-06T11:17", "XXXX-06-06T11:17:21.709Z",
    ] {
    assert_true(
      parse_iso_utc(bad) is None,
      msg="expected \{bad} to be rejected",
    )
  }
}

// ── Entry encoding ─────────────────────────────────────────────────────────

///|
test "real entries round trip" {
  for entry in entry_fixtures {
    let (name, line) = entry
    let original = @json.parse(line)
    let decoded = Entry::from_json(original)
    let reencoded = decoded.to_json()
    if reencoded != original {
      fail(
        "round trip changed \{name}\n  original:  \{original.stringify()}\n  reencoded: \{reencoded.stringify()}",
      )
    }
  }
}

///|
test "real session header round trips" {
  let original = @json.parse(session_header_fixture)
  let header = SessionHeader::from_json(original)
  assert_eq(header.version, Some(3))
  assert_eq(header.to_json(), original)
}

///|
/// A session written by a newer pi must stay readable: an unrecognised kind is
/// kept whole rather than dropped or rejected.
test "unknown entry kinds are preserved verbatim" {
  let line = "{\"type\":\"future_thing\",\"id\":\"abcd1234\",\"parentId\":null,\"timestamp\":\"2026-06-06T11:17:21.709Z\",\"payload\":{\"nested\":[1,2]},\"flag\":true}"
  let original = @json.parse(line)
  let entry = Entry::from_json(original)
  assert_true(entry.kind is Unknown(type_name="future_thing", ..))
  assert_eq(entry.to_json(), original)
}

///|
/// The kind is also carried in the JSON, so an entry decoded then encoded must
/// not silently change its type.
test "entry kinds are stable" {
  let cases : Array[(String, String)] = [
    (
      "message", "{\"type\":\"model_change\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"provider\":\"deepseek\",\"modelId\":\"deepseek-v4-flash\"}",
    ),
    (
      "thinking_level_change", "{\"type\":\"thinking_level_change\",\"id\":\"a2\",\"parentId\":\"a1\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"thinkingLevel\":\"high\"}",
    ),
    (
      "label", "{\"type\":\"label\",\"id\":\"a3\",\"parentId\":\"a2\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"targetId\":\"a1\",\"label\":\"checkpoint\"}",
    ),
  ]
  for case in cases {
    let (label, line) = case
    assert_eq(
      Entry::from_json(@json.parse(line)).to_json(),
      @json.parse(line),
      msg=label,
    )
  }
}

// ── Paths ──────────────────────────────────────────────────────────────────

///|
/// Build a chain of entries with explicit ids, each parented to the previous.
fn chain(ids : Array[String]) -> Session {
  let entries : Array[Entry] = []
  for i in 0..<ids.length() {
    entries.push({
      id: ids[i],
      parent_id: if i == 0 {
        None
      } else {
        Some(ids[i - 1])
      },
      timestamp: format_iso_utc(i.to_int64() * 1000),
      kind: ThinkingLevelChange(level="high"),
    })
  }
  Session::new(
    {
      id: "s",
      timestamp: format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    entries,
  )
}

///|
test "path follows the leaf to the root" {
  let session = chain(["a", "b", "c"])
  let path = session.path()
  assert_eq(path.length(), 3)
  assert_eq(path[0].id, "a")
  assert_eq(path[2].id, "c")
}

///|
/// Pointing the leaf at an earlier entry truncates the conversation without
/// touching the log — this is what branching is.
test "path_to an earlier entry truncates" {
  let session = chain(["a", "b", "c"])
  let path = session.path_to(Some("b"))
  assert_eq(path.length(), 2)
  assert_eq(path[1].id, "b")
  // An explicit `None` leaf is empty, which is how a fresh session starts.
  assert_eq(session.path_to(None).length(), 0)
}

// ── Context derivation ─────────────────────────────────────────────────────

///|
fn user_entry(id : String, parent : String?, text : String) -> Entry {
  {
    id,
    parent_id: parent,
    timestamp: format_iso_utc(0L),
    kind: Message(message=User({ content: [Text(text)], timestamp: 0L, })),
  }
}

///|
fn session_with(entries : Array[Entry]) -> Session {
  Session::new(
    {
      id: "s",
      timestamp: format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    entries,
  )
}

///|
test "settings come from the latest change on the path" {
  let session = session_with([
    {
      id: "a",
      parent_id: None,
      timestamp: format_iso_utc(0L),
      kind: ThinkingLevelChange(level="low"),
    },
    {
      id: "b",
      parent_id: Some("a"),
      timestamp: format_iso_utc(0L),
      kind: ModelChange(provider="deepseek", model_id="deepseek-v4-flash"),
    },
    {
      id: "c",
      parent_id: Some("b"),
      timestamp: format_iso_utc(0L),
      kind: ThinkingLevelChange(level="high"),
    },
  ])
  let context = session.context()
  assert_eq(context.thinking_level, "high")
  assert_eq(
    context.model,
    Some({ provider: "deepseek", model_id: "deepseek-v4-flash", }),
  )
  // Settings entries are not conversation.
  assert_eq(context.messages.length(), 0)
}

///|
test "thinking level defaults to off" {
  let session = session_with([user_entry("a", None, "hi")])
  assert_eq(session.context().thinking_level, "off")
}

///|
/// Compaction replaces everything before `firstKeptEntryId` with a single
/// summary, but entries appended after the compaction stay.
test "compaction hides summarized history and keeps the rest" {
  let session = session_with([
    user_entry("a", None, "first"),
    user_entry("b", Some("a"), "second"),
    {
      id: "c",
      parent_id: Some("b"),
      timestamp: format_iso_utc(0L),
      kind: Compaction(
        summary="they said two things",
        first_kept_entry_id="b",
        tokens_before=1234,
        details=None,
        usage=None,
        from_hook=None,
      ),
    },
    user_entry("d", Some("c"), "third"),
  ])
  let messages = session.context().messages
  // summary, then "second" (the first kept), then "third". "first" is gone.
  assert_eq(messages.length(), 3)
  assert_true(
    messages[0] is CompactionSummary(summary="they said two things", ..),
  )
  assert_true(messages[1] is User({ content: [Text("second")], .. }))
  assert_true(messages[2] is User({ content: [Text("third")], .. }))
}

///|
/// A later compaction supersedes an earlier one: history is summarized twice,
/// not concatenated.
test "only the newest compaction applies" {
  let session = session_with([
    user_entry("a", None, "one"),
    {
      id: "b",
      parent_id: Some("a"),
      timestamp: format_iso_utc(0L),
      kind: Compaction(
        summary="first summary",
        first_kept_entry_id="a",
        tokens_before=100,
        details=None,
        usage=None,
        from_hook=None,
      ),
    },
    user_entry("c", Some("b"), "two"),
    {
      id: "d",
      parent_id: Some("c"),
      timestamp: format_iso_utc(0L),
      kind: Compaction(
        summary="second summary",
        first_kept_entry_id="c",
        tokens_before=200,
        details=None,
        usage=None,
        from_hook=None,
      ),
    },
    user_entry("e", Some("d"), "three"),
  ])
  let messages = session.context().messages
  assert_eq(messages.length(), 3)
  assert_true(messages[0] is CompactionSummary(summary="second summary", ..))
  assert_true(messages[1] is User({ content: [Text("two")], .. }))
  assert_true(messages[2] is User({ content: [Text("three")], .. }))
}

///|
/// A branch takes the conversation down a different child; the sibling branch
/// stops being part of the context even though it stays in the file.
test "a branch selects one path" {
  let session = session_with([
    user_entry("a", None, "root"),
    user_entry("b", Some("a"), "left"),
    user_entry("c", Some("a"), "right"),
  ])
  // The last entry is the leaf by default.
  let right = session.context().messages
  assert_eq(right.length(), 2)
  assert_true(right[1] is User({ content: [Text("right")], .. }))
  // Re-pointing the leaf at the sibling switches branches.
  let session = { ..session, leaf_id: Some("b"), }
  let left = session.context().messages
  assert_eq(left.length(), 2)
  assert_true(left[1] is User({ content: [Text("left")], .. }))
}

///|
/// A dangling parent link ends the walk rather than looping: a truncated file
/// should still yield the entries that are present.
test "a broken parent chain stops the walk" {
  let session = session_with([
    user_entry("a", None, "kept"),
    user_entry("b", Some("missing"), "orphan"),
  ])
  let path = session.path()
  assert_eq(path.length(), 1)
  assert_eq(path[0].id, "b")
}

///|
/// A parent link that points *forward* is a cycle, and a cycle used to be a hang.
///
/// The case above is a dangling link — the parent is not in the file at all, so the walk stops by
/// running out of entries. This is the other one: every link resolves, but they resolve into a
/// loop. It is what a log looks like when two writers interleave, when a file is merged or edited
/// by hand, or when an id collides. Before this was guarded the server spun at 100% CPU and grew
/// to gigabytes of memory on a two-turn session, because the walk reallocated its whole result on
/// every pass and never returned. The assertion that matters is simply that this returns at all.
test "a cyclic parent chain terminates instead of looping forever" {
  let session = session_with([
    user_entry("a", Some("b"), "points forward"),
    user_entry("b", Some("a"), "and back again"),
  ])
  let path = session.path()
  // Both entries are reachable, and the walk stops at the repeat rather than going round again.
  assert_eq(path.length(), 2)
  assert_eq(session.needs_repair(), false)
}
