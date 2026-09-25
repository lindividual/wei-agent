///|
/// The facts store, through the shell that uses it.
///
/// `core/session_facts_test.mbt` pins the rules and `platform/session_facts_test.mbt` pins the reads.
/// What is only testable here is the join, and it has three parts:
///
///   **A cold launch defers the rename search.** It describes each session from the head of its log and
///   says nothing about names, because proving that a log holds no rename means reading all of it and a
///   window should not wait for that. What the reader gets immediately is the label — the first question
///   — which is the thing they recognise a conversation by.
///
///   **The sweep settles what was deferred**, in the background, and says the list again only if a name
///   actually appeared.
///
///   **A warm launch needs neither**, because the facts are on disk.
///
/// The failure mode all of it guards is the quiet one: a session drawn under its first question looks
/// exactly like a session nobody renamed. So every case below asserts the label a reader would see, and
/// the rename cases assert that the name arrives — not merely that it is somewhere in a file.

///|
/// A shell over a store, carrying facts a previous run left behind, and the events it sends.
fn shell_with(
  root : String,
  home : String,
  facts : Array[@core.SessionFacts],
) -> (Shell, () -> Array[Json]) {
  let seen : Array[Json] = []
  let shell = Shell::of(
    {
      home,
      settings: @core.decode_app_settings(""),
      root,
      start: "/tmp",
      base_url: "https://api.deepseek.com",
      jobs: @core.JobStore::new(),
      pins: [],
      session: @core.Session::new(session_header("probe"), []),
      path: "\{root}/not-a-real-file.jsonl",
      session_bytes: 0L,
      facts,
      debug_log: "",
    },
    out=json => seen.push(json),
  )
  (shell, () => seen)
}

///|
/// A session file line, built with the real encoder.
///
/// Hand-written JSON was tried here first and it silently produced **no label**: a user message needs
/// a `timestamp` *inside* `message`, not only beside it, so a fixture that omits it decodes to nothing
/// — which reads as "a session nobody has asked anything in", and made this test's first version pass
/// its own assertions for the wrong reason. The encoder cannot make that mistake.
fn user_entry(id : String, text : String, parent : String?) -> @core.Entry {
  {
    id,
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
fn rename_entry(id : String, parent : String, name : String) -> @core.Entry {
  {
    id,
    parent_id: Some(parent),
    timestamp: @core.format_iso_utc(1700000000000L),
    kind: @core.SessionInfo(name=Some(name)),
  }
}

///|
fn session_header(id : String) -> @core.SessionHeader {
  {
    id,
    timestamp: @core.format_iso_utc(1700000000000L),
    cwd: "/facts/project",
    parent_session: None,
    version: Some(3),
  }
}

///|
/// A store with one session in it, and the home and path a test drives it with.
async fn facts_store(name : String) -> (String, String, String) {
  let root = "_build/facts_test/\{name}-\{@core.new_entry_id()}"
  let home = "\{root}/home"
  @platform.make_dirs(home)
  let dir = @core.session_dir_for(root, "/facts/project")
  @platform.make_dirs(dir)
  let path = "\{dir}/2026-08-23T06-26-15.210Z_abc12345.jsonl"
  ignore(
    @platform.write_session(
      path,
      @core.session_file_text(session_header("abc12345"), [
        user_entry("m1", "what went wrong here", None),
      ]),
    ),
  )
  (root, home, path)
}

///|
/// One session's facts, by path.
///
/// By path and not by position: encoding sorts the records, but the *direction* of that sort is not a
/// promise to anybody, so reading them by index would be pinning an accident.
fn fact_for(
  facts : Array[@core.SessionFacts],
  path : String,
) -> @core.SessionFacts? {
  for fact in facts {
    if fact.path == path {
      return Some(fact)
    }
  }
  None
}

///|
/// The label of the row for `path`, out of the last event — which is what a reader sees.
fn label_in(seen : Array[Json], path : String) -> String raise {
  let last = seen[seen.length() - 1]
  match last {
    Object(fields) =>
      match fields.get("workspaces") {
        Some(Array(workspaces)) =>
          for workspace in workspaces {
            match workspace {
              Object(group) =>
                match group.get("sessions") {
                  Some(Array(rows)) =>
                    for row in rows {
                      match row {
                        Object(row_fields) =>
                          match
                            (row_fields.get("path"), row_fields.get("label")) {
                            (Some(String(row_path)), Some(String(row_label))) =>
                              if row_path == path {
                                return row_label
                              }
                            _ => ()
                          }
                        _ => ()
                      }
                    }
                  _ => ()
                }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  fail("no row for \{path} in the last event")
}

///|
/// **A cold launch describes a session from the head of its log and defers its rename.**
///
/// This is the shape the whole design turned on, and the assertion that would catch it being thrown
/// away: a log that *does* hold a rename is drawn without it, immediately, and the sweep is what finds
/// it. The reader gets a window in milliseconds and a correct label; they wait for nothing.
async test "a cold launch draws the label and defers the rename" {
  let (root, home, path) = facts_store("deferred")
  // Give the file a rename, so "no name" is a deliberate deferral rather than an absence.
  ignore(
    @platform.write_session(
      path,
      @core.session_file_text(session_header("abc12345"), [
        user_entry("m1", "what went wrong here", None),
        rename_entry("i1", "m1", "the naming bug"),
      ]),
    ),
  )

  let (shell, seen) = shell_with(root, home, [])
  shell.say_sessions()
  // The label is right, immediately — the head of the log is 16 KiB whatever the conversation weighs.
  assert_eq(label_in(seen(), path), "what went wrong here")
  // And the name is not there *yet*, which is the deferral.
  let recorded = fact_for(@platform.load_facts(home), path).unwrap()
  assert_eq(recorded.label, "what went wrong here")
  assert_eq(recorded.name, None)
  // A sweep mark of zero is how "not searched" is written down — the marker `sweep` looks for, and the
  // only thing that distinguishes this from a log that was searched and had nothing in it.
  assert_eq(recorded.scanned, 0L)
  assert_true(shell.labels.deferred)

  // The sweep settles it, and says the list again because a name appeared.
  let before = seen().length()
  shell.sweep_deferred()
  assert_eq(label_in(seen(), path), "the naming bug")
  assert_true(seen().length() > before, msg="the list was said again")
  let settled = fact_for(@platform.load_facts(home), path).unwrap()
  assert_eq(settled.name, Some("the naming bug"))
  assert_eq(settled.scanned, @platform.file_size(path))
}

///|
/// **A store nobody has renamed is swept in silence.**
///
/// The common case by a wide margin, and the reason `sweep_deferred` only says the list when a name
/// appears: a sweep that emitted once per file would rebuild the host's whole sidebar once per session
/// in the store, to draw the same list.
async test "a sweep that finds no rename says nothing" {
  let (root, home, path) = facts_store("quiet")
  let (shell, seen) = shell_with(root, home, [])
  shell.say_sessions()
  let after_list = seen().length()
  shell.sweep_deferred()
  assert_eq(seen().length(), after_list, msg="no second event")
  // Settled anyway: the search ran and recorded that it did.
  let settled = fact_for(@platform.load_facts(home), path).unwrap()
  assert_eq(settled.scanned, @platform.file_size(path))
}

///|
/// A warm launch needs neither the deferral nor the sweep — and draws the same list.
///
/// The whole point: what run one slowly learned, run two reads from a file in a single bounded read.
/// Equality is the assertion, because "the second launch is faster" is only worth anything if it is
/// also *the same list*.
async test "a warm launch draws the same list without reading the logs" {
  let (root, home, path) = facts_store("warm")
  let (first, first_seen) = shell_with(root, home, [])
  first.say_sessions()
  assert_eq(label_in(first_seen(), path), "what went wrong here")
  // Nothing was owed, because there was no rename in this log to find — so a second launch has nothing
  // to sweep, which is what `deferred` being false means.
  first.sweep_deferred()
  assert_false(first.labels.deferred)

  let saved = @platform.load_facts(home)
  assert_eq(fact_for(saved, path).unwrap().scanned, @platform.file_size(path))
  let (second, second_seen) = shell_with(root, home, saved)
  second.say_sessions()
  assert_eq(label_in(second_seen(), path), "what went wrong here")
  // Nothing left owed, so a launch that was already warm starts no background work.
  assert_false(second.labels.deferred)
}

///|
/// **A rename is seen, whether it was appended or written in place.**
///
/// *Appended* is the ordinary case — the reader renames a session whose facts are already settled, and
/// the entry lands at the end of a long log. Only the bytes past the mark are searched, so this is also
/// the case that proves the resume is not skipping the answer.
///
/// *Rewritten to the same length* is the case a size comparison cannot see, and the one that must
/// degrade to reading the file. `@agent.repair_session` rewrites suffixes, and an entry that moved
/// **into** the swept region would be invisible to an incremental search forever — so the rule is that
/// a log which did not grow is read whole. Pinned to the exact recorded length, because that is the
/// only way to reach the branch.
async test "a rename is seen whether it was appended or written in place" {
  // Appended, the ordinary case.
  let (root, home, path) = facts_store("appended")
  let (first, _) = shell_with(root, home, [])
  first.say_sessions()
  first.sweep_deferred()
  let settled = @platform.load_facts(home)
  assert_eq(fact_for(settled, path).unwrap().name, None)
  assert_eq(fact_for(settled, path).unwrap().scanned, @platform.file_size(path))

  @platform.append_entry(
    path,
    rename_entry("i1", "m1", "the rename I just did"),
  )
  let (second, second_seen) = shell_with(root, home, settled)
  second.say_sessions()
  assert_eq(label_in(second_seen(), path), "the rename I just did")

  // And the entry is remembered, so the *next* refresh does not have to find it again.
  let after = fact_for(@platform.load_facts(home), path).unwrap()
  assert_eq(after.name, Some("the rename I just did"))
  assert_eq(after.scanned, @platform.file_size(path))

  // Rewritten to exactly the length the facts were derived against.
  let (root2, home2, path2) = facts_store("in-place")
  // A first turn long enough that the rewrite below has room to carry a rename line at the same total
  // length. A short original could only be *grown* by adding an entry, and growing is the easy case.
  ignore(
    @platform.write_session(
      path2,
      @core.session_file_text(session_header("abc12345"), [
        user_entry("m1", "a".repeat(2000), None),
      ]),
    ),
  )
  let (a, _) = shell_with(root2, home2, [])
  a.say_sessions()
  a.sweep_deferred()
  let target = fact_for(@platform.load_facts(home2), path2).unwrap().scanned
  // Built line by line rather than through `session_file_text`, because this fixture's whole point is
  // to land on one exact byte length.
  let header_line = session_header("abc12345").to_line()
  let blank_user = user_entry("m1", "", None).to_line()
  let rename_line = rename_entry("i1", "m1", "renamed in place").to_line()
  let room = target -
    header_line.length().to_int64() -
    blank_user.length().to_int64() -
    rename_line.length().to_int64()
  assert_true(room > 0L)
  let content = header_line +
    user_entry("m1", "z".repeat(room.to_int()), None).to_line() +
    rename_line
  // The whole point of this fixture: the rewrite is invisible to a size comparison.
  assert_eq(content.length(), target.to_int())
  @platform.write_text(path2, content)

  let facts2 = @platform.load_facts(home2)
  let (b, b_seen) = shell_with(root2, home2, facts2)
  b.say_sessions()
  // Both facts move, because the file was read again rather than resumed: the name, **and** the label,
  // which the incremental path would have kept from the previous conversation.
  assert_eq(label_in(b_seen(), path2), "renamed in place")
}

///|
/// A session whose first question had not been written yet gets its label when it does.
///
/// The one fact an append can still be the first to supply, and the reason `plan_read` carries a
/// `relabel` at all: taking a cached empty label at face value would draw the session as its id for the
/// rest of its life, and the first prompt would never appear in the sidebar.
///
/// A session is created empty — the row appears before the first prompt is written — so this is a
/// window a reader is in every time they press ⌘N and type.
async test "a session created empty is labelled when its first question is written" {
  let (root, home, _) = facts_store("empty-first")
  let dir = @core.session_dir_for(root, "/facts/project")
  let fresh = "\{dir}/2026-08-23T06-26-20.000Z_new11111.jsonl"
  ignore(
    @platform.write_session(
      fresh,
      @core.session_file_text(session_header("new11111"), []),
    ),
  )

  let (first, first_seen) = shell_with(root, home, [])
  first.say_sessions()
  // Nothing to call it yet: the id, which is what a reader sees for a session with no question.
  assert_eq(label_in(first_seen(), fresh), "new11111")
  let known = @platform.load_facts(home)
  // The empty label was recorded as a fact, which is what makes this case dangerous.
  assert_eq(fact_for(known, fresh).unwrap().label, "")

  // The reader types. The first turn is written, and the label has to appear.
  @platform.append_entry(
    fresh,
    user_entry("m1", "the very first thing I asked", None),
  )
  let (second, second_seen) = shell_with(root, home, known)
  second.say_sessions()
  assert_eq(label_in(second_seen(), fresh), "the very first thing I asked")
}

///|
/// A session that has been deleted does not leave a record that a later session inherits.
///
/// `Labels::forget` is the only way the store learns a file moved aside, and a record is keyed by path
/// — so a forgotten path left in the file would be a fact about a session that no longer exists, and a
/// *different* session created at that path later would be drawn with the old one's label. The list
/// after the delete is where the save happens, so that is what this drives.
async test "a deleted session's facts are dropped, not left for its replacement" {
  let (root, home, path) = facts_store("deleted")
  let (shell, _) = shell_with(root, home, [])
  shell.say_sessions()
  assert_true(fact_for(@platform.load_facts(home), path) is Some(_))

  shell.discard(path, purge=false)
  // A refresh after the delete is what writes the facts out — the same refresh every other change ends
  // with.
  shell.say_sessions()
  assert_eq(fact_for(@platform.load_facts(home), path), None)

  // **And the record is gone rather than merely overwritten in this process's memory.** A session
  // created at the same path afterwards must start with nothing known about it, or it would inherit the
  // deleted conversation's label.
  ignore(
    @platform.write_session(
      path,
      @core.session_file_text(session_header("abc12345"), []),
    ),
  )
  let (fresh, fresh_seen) = shell_with(root, home, @platform.load_facts(home))
  fresh.say_sessions()
  // Its id, not "what went wrong here": nothing about the new session was known, and nothing about the
  // old one survived the path being reused.
  assert_eq(label_in(fresh_seen(), path), "abc12345")
}
