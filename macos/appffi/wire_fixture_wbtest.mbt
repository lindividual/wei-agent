///|
/// The wire, pinned as **one file both languages read**.
///
/// `app_wbtest.mbt` pins each event's shape against the producer that makes it, which is what turns a
/// field rename into a failing test. What it cannot do is notice a rename that happened on the *other*
/// side: the host decodes by name, and until now its tests built their own literals, so the two lists
/// of field names could drift apart with both builds green.
///
/// So the produced events go into a file. This side **generates and checks** it; the Swift side
/// (`WeiShell/Tests/WeiShellTests/WireFixtureTests.swift`) **decodes** it. A rename that only one side
/// made is now a build that fails on that side — which is the whole property. The second consumer had
/// to be made rather than assumed: `wei-cli` is not one (it prints lines and decodes nothing), so this
/// file is what makes the seam real rather than hypothetical.
///
/// **One line per kind**, not per emitter: `blocks_event` and `blocks_frame_event` are two producers of
/// one kind the host decodes, and the host's question is "can I read this kind" rather than "can I read
/// every way you might build it".

///|
/// Where the fixture lives, relative to the repository root.
///
/// Relative rather than absolute because both sides know the repository: this one runs from the root
/// (`moon test`), and the Swift test walks up from its own `#filePath`.
fn wire_fixture_path() -> String {
  // Whitebox test file (`_wbtest.mbt`) so it can see `Open`, `Attachment` and the builders; those are
  // priv to this package on purpose, and a blackbox test could not build the fixture at all.
  "macos/wire-fixtures.jsonl"
}

///|
/// A session with something in it, for the two events that carry rows.
fn fixture_session() -> @core.Session raise {
  let header =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
  @core.parse_session_file(header + "\n" + user_line("m1", "wire fixture"))
}

///|
/// The session on screen, as the events that are about it describe it.
fn fixture_open() -> Open raise {
  Open::new(
    "/store/s.jsonl",
    "/tmp",
    "deepseek-v4-flash",
    "high",
    fixture_session(),
  )
}

///|
/// Every kind the host must be able to decode, with one example of each.
///
/// The order is the order the host declares them in, so a reader can line the two up. The name is
/// carried alongside the event rather than read back out of it, so that a builder emitting the wrong
/// `kind` is a failure here rather than something this fixture agrees with.
fn wire_examples() -> Array[(String, Json)] raise {
  let p = "/store/s.jsonl"
  let open = fixture_open()
  [
    ("ready", ready_event(open, "DEEPSEEK_API_KEY")),
    ("session", session_snapshot(open)),
    ("elsewhere", elsewhere_event("/store/other.jsonl", "finished")),
    ("history", history_event(p, fixture_session())),
    ("earlier", earlier_event(p, fixture_session(), "h-2")),
    (
      "sessions",
      sessions_event([
        (
          "/tmp",
          "tmp",
          true,
          [
            Json::object(
              Map([
                ("path", Json::string(p)),
                ("id", Json::string("s1")),
                ("label", Json::string("wire fixture")),
                (
                  "modified",
                  Json::number(1756000000000.0, repr="1756000000000"),
                ),
                ("current", Json::boolean(true)),
                ("running", Json::boolean(false)),
              ]),
            ),
          ],
        ),
      ]),
    ),
    ("deleted", deleted_event(p, "the reader's name", true)),
    (
      "blocks",
      blocks_event(p, "reply-1-1", 0, @md.parse("## Heading\n\nwith `code`\n")),
    ),
    (
      "settings",
      settings_event(
        "environment",
        true,
        false,
        @core.ToolMode::Code,
        "/tmp/settings.json",
        [],
        { text: "Run the tests with moon test.", source: @core.Saved, },
        {
          max_rounds: { value: 200.0, source: @core.Default, },
          max_cost: { value: 1.0, source: @core.Default, },
          max_seconds: { value: 1800.0, source: @core.Default, },
        },
      ),
    ),
    ("user", user_event(p, "what is this?", false, [])),
    ("reply", piece_event(p, "reply", "reply-1", "hello")),
    ("thinking", piece_event(p, "thinking", "think-1", "let me think")),
    (
      "images",
      images_event(
        p,
        [{ path: "/tmp/shot.png", mime_type: "image/png", data: "AAA=", }],
        true,
      ),
    ),
    (
      "usage",
      usage_event(
        p,
        {
          input: 1200,
          output: 300,
          cache_read: 4000,
          cache_write: 0,
          reasoning: 0,
          total_tokens: 5500,
          cost: {
            input: 0.000168,
            output: 0.000084,
            cache_read: 0.0000112,
            cache_write: 0.0,
            total: 0.0002632,
          },
          replies: 3,
        },
        2000,
        {
          tokens: 3000,
          provider_measured: true,
          overhead: 1300,
          window: 128000,
          compact_soon: false,
        },
        {
          usage: @core.Usage::zero(),
          model_calls: 0,
          tool_calls: 0,
          cost: 0.0,
          present: false,
        },
      ),
    ),
    ("models", models_event(p, "deepseek-v4-flash")),
    ("think", think_event(p, "deepseek-v4-flash", "high")),
    (
      "jobs",
      jobs_event(
        [
          {
            id: "bash-1",
            kind: "bash",
            label: "npm run dev",
            session: p,
            status: @core.JobStatus::Running,
            started_at: 1756000000000L,
            finished_at: None,
            detail: "",
            pids: [4242],
            tail: "",
            output: None,
            call_open: false,
          },
        ],
        [4242],
        1756000002000L,
      ),
    ),
    ("tool", tool_event(p, "tool-1", "bash", "ls", true, "a.txt", false)),
    ("status", status_event(p, "thinking…")),
    ("note", note_event(p, "they asked for a parser", "context compacted")),
    ("end", end_event(p, "", 19, 3, 0.0)),
    ("error", error_event(p, "the turn failed: connection reset")),
  ]
}

///|
/// The fixture, as the file holds it: one JSON object per line, in `wire_examples` order.
fn wire_fixture_text() -> String raise {
  let lines : Array[String] = []
  for entry in wire_examples() {
    lines.push(entry.1.stringify())
  }
  lines.join("\n") + "\n"
}

///|
/// **The fixture is what this shell actually sends, and every kind is in it.**
///
/// Two jobs in one test, because they fail together and mean the same thing: the file matches what the
/// producers emit (so the host is being tested against reality rather than against a copy of it), and
/// the kinds in it are exactly the kinds the host must decode (so adding an event cannot quietly skip
/// the fixture).
///
/// Run with `WEI_UPDATE_FIXTURES=1` to rewrite the file after an intentional wire change:
///
/// ```
/// WEI_UPDATE_FIXTURES=1 moon test -p macos/appffi
/// ```
async test "the wire fixture matches what this shell sends" {
  let examples = wire_examples()
  // The names are the host's list, in the host's order. A new kind has to be added in both places,
  // which is the same discipline `ShellEvent`'s exhaustive switch already enforces on the Swift side.
  let expected : Array[String] = [
    "ready", "session", "elsewhere", "history", "earlier", "sessions", "deleted",
    "blocks", "settings", "user", "reply", "thinking", "images", "usage", "models",
    "think", "jobs", "tool", "status", "note", "end", "error",
  ]
  let kinds : Array[String] = []
  for entry in examples {
    kinds.push(entry.0)
    // And each event says the kind it is: a builder that disagreed with the name above would be a
    // fixture that documents one thing and ships another.
    match entry.1 {
      Object(fields) =>
        match fields.get("kind") {
          Some(String(kind)) =>
            assert_true(
              kind == entry.0,
              msg="\{entry.0}'s event says kind \\{kind}",
            )
          _ => fail("\{entry.0} carries no kind")
        }
      _ => fail("\{entry.0} is not an object")
    }
  }
  assert_eq(kinds, expected)

  let produced = wire_fixture_text()
  if @env.get_env_var("WEI_UPDATE_FIXTURES") is Some(_) {
    @platform.write_text(wire_fixture_path(), produced)
    return
  }
  let on_disk = @platform.read_text(wire_fixture_path()) catch {
    _ =>
      fail(
        "\\{wire_fixture_path()} is missing — run with WEI_UPDATE_FIXTURES=1 to write it",
      )
  }
  assert_eq(
    on_disk,
    produced,
    msg="the wire fixture is stale: re-emit it with WEI_UPDATE_FIXTURES=1 and check that the host still decodes it",
  )
}
