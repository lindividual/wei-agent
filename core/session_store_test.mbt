///|
/// Session file reading, writing, and path naming.

///|
/// The encoding is lossy, so the fixtures are the ground truth: these pairs are
/// what pi actually wrote next to what actually produced them.
test "session directory names match pi" {
  for pair in session_dir_fixtures {
    let (cwd, expected) = pair
    assert_eq(session_dir_name(cwd), expected, msg="for \{cwd}")
  }
}

///|
/// A path with no separators still gets wrapped, so a directory name can never
/// collide with a plain directory in the sessions root.
test "session directory name edge cases" {
  assert_eq(session_dir_name("/"), "----")
  assert_eq(session_dir_name("/a"), "--a--")
  assert_eq(session_dir_name("/a/b"), "--a-b--")
}

///|
test "a complete session file parses" {
  let session = parse_session_file(small_session_file)
  assert_eq(session.header.version, Some(3))
  assert_true(session.header.cwd != "")
  assert_true(session.entries.length() > 0)
  // The leaf is the last entry, so the path is the whole file.
  assert_eq(session.path().length(), session.entries.length())
}

///|
/// Writing what was read must produce the same records: this is what makes a
/// session written by this implementation readable by pi and vice versa.
test "entries survive a file round trip" {
  let session = parse_session_file(small_session_file)
  let rewritten = session.header.to_line()
  let mut text = rewritten
  for entry in session.entries {
    // Round trip through JSON text, not just in memory.
    let line = entry.to_line()
    let line_view = line.trim()
    let reparsed = Entry::from_json(@json.parse(line_view))
    if reparsed.to_json() != entry.to_json() {
      fail("entry \{entry.id} changed across a text round trip")
    }
    text = text + line
  }
  let reloaded = parse_session_file(text)
  assert_eq(reloaded.entries.length(), session.entries.length())
  assert_eq(reloaded.header.id, session.header.id)
}

///|
/// A blank line is tolerated; a missing header is not, because it means the file
/// cannot be attributed to a session at all.
test "malformed session files are rejected" {
  let cases : Array[String] = [
    "", "\n\n", "{\"type\":\"model_change\",\"id\":\"a\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"provider\":\"p\",\"modelId\":\"m\"}\n",
    "not json\n",
  ]
  for text in cases {
    try parse_session_file(text) catch {
      _ => ()
    } noraise {
      _ => fail("expected a failure for: \{text}")
    }
  }
}

///|
/// Blank lines between records must not shift anything.
test "blank lines are skipped" {
  let text = session_header_fixture + "\n\n" + entry_fixtures[0].1 + "\n\n"
  let session = parse_session_file(text)
  assert_eq(session.entries.length(), 1)
}

///|
test "entry ids look like pi's" {
  for _ in 0..<20 {
    let id = new_entry_id()
    assert_eq(id.length(), 8)
    for i in 0..<8 {
      let c = id[i].unsafe_to_char()
      let is_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
      assert_true(is_hex, msg="not hex: \{id}")
    }
  }
}

///|
/// A header round trip is what lets a session be resumed without rewriting it.
test "header survives a text round trip" {
  let original = SessionHeader::from_json(@json.parse(session_header_fixture))
  let reloaded = SessionHeader::from_json(
    @json.parse(original.to_line().trim()),
  )
  assert_eq(reloaded, original)
}
