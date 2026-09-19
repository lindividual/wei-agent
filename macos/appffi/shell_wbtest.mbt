///|
/// A shell, without a world
///
/// The seam, exercised. `app_wbtest.mbt` asserts on a *value* an emitter produced, which
/// leaves one thing untested and it is the expensive one: whether a command is allowed to happen at
/// all, what it says when it is refused, and in what order those two things occur. Those decisions
/// live in `Shell::` methods, and until `Shell::of` existed a `Shell` could only be built by
/// launching the app — so the only way to reach one was to open the window and look.
///
/// These tests build one from a literal `World` and an array to record into. No store, no socket, no
/// environment, and the same seam the host crosses.

///|
/// A shell over a literal world, and the list of everything it says.
///
/// The recorder is what makes the difference visible: `out` is the shell's field, so a test stands
/// in the same place the wire does.
fn test_shell(busy? : Bool = false) -> (Shell, () -> Array[Json]) {
  let seen : Array[Json] = []
  let session = @core.Session::new(
    {
      id: "s",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [],
  )
  let shell = shell_in("/tmp/sessions", "/tmp/s.jsonl", session, json => {
    seen.push(json)
  })
  let open = shell.shown()
  open.busy = busy
  (shell, () => seen)
}

///|
/// A shell over a world the caller chooses, saying things into `out`.
///
/// The same seam `Shell::of` opens; this is the shorthand the tests below use so that each one is only
/// about the value it changes.
fn shell_in(
  root : String,
  path : String,
  session : @core.Session,
  out : (Json) -> Unit,
) -> Shell {
  Shell::of(
    {
      home: "/tmp",
      settings: @core.decode_app_settings(""),
      root,
      start: "/tmp",
      base_url: "https://api.deepseek.com",
      jobs: @core.JobStore::new(),
      pins: [],
      session,
      path,
      debug_log: "",
    },
    out~,
  )
}

///|
/// The kinds of every event a shell sent, in the order it sent them.
fn kinds_of(lines : Array[Json]) -> Array[String] raise {
  let kinds : Array[String] = []
  for line in lines {
    match line {
      Object(fields) =>
        match fields.get("kind") {
          Some(String(kind)) => kinds.push(kind)
          _ => fail("an event with no kind")
        }
      _ => fail("an event that is not an object")
    }
  }
  kinds
}

///|
/// Whether one field of one event is exactly this string.
///
/// A function rather than `assert_true(... contains ...)` at each site so that a failure says which
/// field of which event disagreed, which is the difference between a test that locates a bug and one
/// that only reports its existence.
fn text_field_contains(
  line : Json,
  key : String,
  expected : String,
) -> Bool raise {
  text_field(line, key) == expected
}

///|
/// One string field of one event, or a failure saying which one was missing.
fn text_field(line : Json, key : String) -> String raise {
  match line {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => value
        Some(other) => fail("\{key} is not a string: \{other.stringify()}")
        None => fail("no \{key} in \{line.stringify()}")
      }
    _ => fail("not an object")
  }
}

///|
/// A refusal is a decision and a sentence, and they are one value now.
///
/// `gate` replaced a `Shell::idle() -> Bool` that answered the question **and** wrote the refusal —
/// so asking it had a side effect, and its own doc comment had drifted into naming three commands
/// (delete, rename, open-a-fresh-one) as guarded that had since been un-gated on purpose. The stale
/// names are the test cases below: what is pinned here is the rule, not the prose about the rule.
test "the gate names the two commands a running turn refuses, and nothing else" {
  let refusal = Refused("a turn is running here — stop it first")
  // The two that decide something *about* the turn on screen.
  assert_eq(gate(ContinueTurn, true), refusal)
  assert_eq(gate(DismissTurn, true), refusal)
  // The three the old doc comment claimed to guard, and does not — each for a reason written beside
  // its arm: they carry a path of their own, so "is the session on screen busy" is not their question.
  assert_eq(gate(Delete("/s.jsonl"), true), Allowed)
  assert_eq(gate(Rename("/s.jsonl", "x"), true), Allowed)
  assert_eq(gate(WorkspaceDelete("/tmp"), true), Allowed)
  // And the two that have to work *while* a turn runs, or the reader is stuck.
  assert_eq(gate(Abort, true), Allowed)
  assert_eq(gate(Prompt("hi"), true), Allowed)
}

///|
/// With nothing running, nothing is refused — the table is about a live turn, not about commands.
test "an idle session refuses nothing" {
  for command in [ContinueTurn, DismissTurn, Delete("/s.jsonl"), Prompt("hi")] {
    assert_eq(gate(command, false), Allowed)
  }
}

///|
/// The jobs panel's rule — **sent when it changed, and only then** — is a decision, not a field.
///
/// It exists because the tick is every two seconds and most of the time nothing is running, so an
/// unconditional send would put thirty identical empty events a minute on the wire and wake the host
/// just as often. That rule lived inside a method that could not be called without a running app, so
/// "once, not every tick" was only ever checked by watching the log by hand.
test "an unchanged jobs panel is not re-sent" {
  let (shell, seen) = test_shell()
  shell.say_jobs()
  inspect(seen().length(), content="1")
  shell.say_jobs()
  shell.say_jobs()
  // Three ticks, one event: the second and third found the text unchanged.
  inspect(seen().length(), content="1")
}

///|
/// A level the model has not got is said out loud, and what the session records is not what was typed.
///
/// Two decisions in one call, and neither was reachable before: the word the reader typed is checked
/// against the model's own list, and the sentence says which one is in force when they disagree. An
/// unknown level that fell back silently would be a setting the reader believes they changed.
test "a level this model has not got is refused in words, and the model's default is what sticks" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  shell.set_think_level(open, "bogus")
  let lines = seen()
  // The sentence, and then the menu re-said with the level actually in force — a menu left ticking a
  // level the session is not on would be the same lie in a second place.
  inspect(lines.length(), content="2")
  match lines[0] {
    Object(fields) =>
      match fields.get("text") {
        Some(text) =>
          assert_true(
            text.stringify().contains("has no bogus level"),
            msg="the refusal did not name the level that was asked for",
          )
        None => fail("the status carries no text")
      }
    _ => fail("the status is not an object")
  }
  // The session records the level in force, never the one that was typed.
  assert_true(open.think_level != "bogus")
}
