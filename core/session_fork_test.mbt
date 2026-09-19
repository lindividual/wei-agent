///|
/// Forking: the header, the copy, the closed turn, the spending baseline, and the name.
///
/// The decisions this pins are in `core/session_fork.mbt`; what is worth testing here is that each of
/// them survives contact with a real session — a chain of entries, a turn left open, a tool call nobody
/// answered, and money already spent.

///|
/// A parent with three exchanges and a bill: the shape every test below forks.
fn fork_parent() -> Session {
  let header : SessionHeader = {
    id: "parent",
    timestamp: format_iso_utc(1700000000000L),
    cwd: "/tmp/project",
    parent_session: None,
    version: Some(3),
  }
  let first : Entry = {
    id: "u1",
    parent_id: None,
    timestamp: format_iso_utc(1700000000000L),
    kind: Message(
      message=User({
        content: [Text("make the banner smaller")],
        timestamp: 1700000000000L,
      }),
    ),
  }
  let reply = fork_usage_entry("a1", Some("u1"), "of course", 1000, 100)
  let question : Entry = {
    id: "u2",
    parent_id: Some("a1"),
    timestamp: format_iso_utc(1700000000000L),
    kind: Message(
      message=User({
        content: [Text("now the footer")],
        timestamp: 1700000000000L,
      }),
    ),
  }
  let second = fork_usage_entry("a2", Some("u2"), "done", 2000, 200)
  Session::new(header, [first, reply, question, second])
}

///|
fn fork_usage_entry(
  id : String,
  parent : String?,
  text : String,
  input : Int,
  output : Int,
) -> Entry {
  let usage : Usage = {
    input,
    output,
    cache_read: 0,
    cache_write: 0,
    reasoning: None,
    total_tokens: input + output,
    cost: {
      input: input.to_double() / 1000000.0,
      output: output.to_double() / 1000000.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: (input + output).to_double() / 1000000.0,
    },
  }
  {
    id,
    parent_id: parent,
    timestamp: format_iso_utc(1700000000000L),
    kind: Message(
      message=Assistant({
        content: [Text(text)],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage,
        stop_reason: Stop,
        timestamp: 1700000000000L,
        response_id: None,
        response_model: None,
        raw_stop_reason: None,
        error_message: None,
      }),
    ),
  }
}

///|
/// The header is the session's identity, and the fork is what records where it came from.
test "a fork gets a new identity and keeps its parent's directory" {
  let parent = fork_parent()
  let (header, entries) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  assert_eq(header.id, "child")
  assert_eq(header.parent_session, Some("/store/parent.jsonl"))
  // The directory is the parent's: a fork is a fork *within* a project, and the way to start somewhere
  // else is the folder chooser.
  assert_eq(header.cwd, "/tmp/project")
  assert_eq(header.version, Some(3))
  assert_eq(header.timestamp, format_iso_utc(1700000009999L))
  // The copy is a chain, so the caller can hand the entries straight to a `Session`.
  assert_eq(entries.length(), parent.entries.length() + 2)
}

///|
/// **The entries are copied as they are, ids included.** A renumbered entry would break the
/// `parent_id` chain and every tool result's `call_id` at once.
test "the copied entries keep their ids and their order" {
  let parent = fork_parent()
  let (_, entries) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  let ids = entries.map(e => e.id)
  assert_eq(ids[0], "u1")
  assert_eq(ids[1], "a1")
  assert_eq(ids[2], "u2")
  assert_eq(ids[3], "a2")
  // And the copy reads back as the same conversation: the fork's model-visible context is the parent's.
  let child = Session::new(fork_header(), entries)
  let before = parent.context().messages
  let after = child.context().messages
  assert_eq(after.length(), before.length())
}

///|
fn fork_header() -> SessionHeader {
  {
    id: "child",
    timestamp: format_iso_utc(1700000009999L),
    cwd: "/tmp/project",
    parent_session: Some("/store/parent.jsonl"),
    version: Some(3),
  }
}

///|
/// **A turn the parent left open is closed in the copy.** Otherwise the fork opens on "this turn was
/// interrupted — continue or start over", which is a question about work in a conversation the reader
/// has just left.
test "a fork of an interrupted session does not open with an interrupted turn" {
  let parent = fork_parent()
  let open_turn = turn_start_entry("keep going", parent.leaf_id, 1700000005000L)
  let interrupted = parent.add_entries([open_turn])
  assert_true(interrupted.turn_in_flight())

  let (_, entries) = fork_session(
    interrupted, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  let child = Session::new(fork_header(), entries)
  assert_false(child.turn_in_flight())
  // Closed the same way the driver closes one it gives up on: an abandoned outcome, so the two ways a
  // turn is left behind read the same in the log.
  // Appended in order: the outcome that closes the turn, the marker, then the name.
  assert_true(
    entries[entries.length() - 3].kind is Custom(custom_type="turn-outcome", ..),
  )
  assert_true(
    entries[entries.length() - 2].kind is Custom(custom_type="fork", ..),
  )
  assert_true(entries[entries.length() - 1].kind is SessionInfo(_))
}

///|
/// **The fork marker and the name go on the end of the chain, in that order.** The marker's `parent_id`
/// is the fork point, which is what makes the copy a chain rather than a pile.
test "the fork marker and the name are appended, and the marker names the parent" {
  let parent = fork_parent()
  let (_, entries) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) dad", 1700000009999L,
  )
  let marker = entries[entries.length() - 2]
  assert_eq(marker.parent_id, Some("a2"))
  assert_true(marker.kind is Custom(custom_type="fork", ..))
  match marker.kind {
    Custom(data~, ..) =>
      match data {
        Some(Json::Object(fields)) => {
          match fields.get("parent") {
            Some(String(parent)) => assert_eq(parent, "/store/parent.jsonl")
            _ => fail("the marker does not name its parent")
          }
          match fields.get("from") {
            Some(String(from)) => assert_eq(from, "a2")
            _ => fail("the marker does not name the entry it ends at")
          }
        }
        _ => fail("the fork marker has no data")
      }
    _ => fail("not a fork marker")
  }
  match entries[entries.length() - 1].kind {
    SessionInfo(name~) => assert_eq(name, Some("(fork) dad"))
    _ => fail("the last entry is not the name")
  }
  // And it is readable back: the marker is how a reader finds out where this session came from.
  assert_eq(
    Session::new(fork_header(), entries).forked_from(),
    Some("/store/parent.jsonl"),
  )
}

///|
/// **A fork's spending starts at the fork.** The copied history was paid for in the parent, and counting
/// it again would bill one conversation's calls to two sessions.
test "a fork has spent nothing, though it carries the whole conversation" {
  let parent = fork_parent()
  assert_eq(parent.usage().replies, 2)
  assert_true(parent.usage().cost.total > 0.0)

  let (_, entries) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  let child = Session::new(fork_header(), entries)
  let total = child.usage()
  assert_eq(total.replies, 0)
  assert_eq(total.input, 0)
  assert_eq(total.output, 0)
  assert_eq(total.cost.total, 0.0)
  // The *context* is not reset, and must not be: the next request really does carry the parent's
  // conversation, and this figure is a measurement of the prompt rather than a bill.
  assert_eq(child.last_prompt_tokens(), parent.last_prompt_tokens())
}

///|
/// A turn in the fork counts, and only it.
test "spending in a fork is the fork's own" {
  let parent = fork_parent()
  let (_, entries) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  let child = Session::new(fork_header(), entries)
  let mine = fork_usage_entry("c1", child.leaf_id, "on it", 300, 30)
  let spent = child.add_entries([mine]).usage()
  assert_eq(spent.replies, 1)
  assert_eq(spent.input, 300)
  assert_eq(spent.output, 30)
}

///|
/// **A fork of a fork counts from the newest marker.** The rule is "after the last one", so the middle
/// session's own spending is not inherited either — no arithmetic, no baseline to keep.
test "a fork of a fork starts from its own marker" {
  let parent = fork_parent()
  let (_, first) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  let child = Session::new(fork_header(), first)
  // Appended the way the driver appends: under the session's own leaf, which is the fork's name entry.
  let spent = child.add_entries([
    fork_usage_entry("c1", child.leaf_id, "on it", 300, 30),
  ])
  assert_eq(spent.usage().replies, 1)

  let grandchild_header = fork_header()
  let (_, second) = fork_session(
    spent, "/store/child.jsonl", "grandchild", "(fork) (fork) x", 1700000010000L,
  )
  let grandchild = Session::new(grandchild_header, second)
  assert_eq(grandchild.usage().replies, 0)
  assert_eq(grandchild.usage().input, 0)
  // Two markers on the path, and the newest one decides.
  assert_eq(grandchild.forked_from(), Some("/store/child.jsonl"))
}

///|
/// The name is the literal prefix, whatever the parent's name happens to be. Not stripped: that would
/// make a child indistinguishable from its parent, and would name the wrong session as its origin.
test "the name is the prefix and the parent's name, verbatim" {
  assert_eq(fork_name("fix the banner"), "(fork) fix the banner")
  assert_eq(fork_name("(fork) fix the banner"), "(fork) (fork) fix the banner")
  assert_eq(fork_name("a513d43d"), "(fork) a513d43d")
}

///|
/// **The whole file, written and read back.** The fork is the one operation here that produces a session
/// file instead of extending one, so the writer and the parser have to agree about it — and this is the
/// test that would catch a missing trailing newline or a header written after an entry.
test "a fork's file round-trips through the parser" {
  let parent = fork_parent()
  let (header, entries) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  let text = session_file_text(header, entries)
  let read_back = parse_session_file(text)
  assert_eq(read_back.header, header)
  assert_eq(read_back.entries.length(), entries.length())
  assert_eq(read_back.leaf_id, Some(entries[entries.length() - 1].id))
  // Line-oriented: one line per record, which is what makes an append to it safe.
  let lines = text.trim().split("\n").collect()
  assert_eq(lines.length(), entries.length() + 1)
  // And the two facts a reader of the file needs are in it.
  assert_true(text.contains("\"parentSession\":\"/store/parent.jsonl\""))
  assert_true(text.contains("(fork) x"))
}

///|
/// Fails if the session's own usage is read from the wrong side of the marker — the anti-test for the
/// rule, stated as the number that must **not** appear.
test "the parent's spending is not in the fork" {
  let parent = fork_parent()
  let before = parent.usage().total_tokens
  assert_true(before > 0)
  let (_, entries) = fork_session(
    parent, "/store/parent.jsonl", "child", "(fork) x", 1700000009999L,
  )
  let child = Session::new(fork_header(), entries)
  assert_eq(child.usage().total_tokens, 0)
}
