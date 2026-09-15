///|
/// The wire format, pinned from the producing side.
///
/// These assert on the JSON rather than on a log or a golden file, and they are the only place the
/// field names exist twice: the host decodes them by name, so a rename here that the host does not
/// know about is a pair of builds that disagree. `macos/PiShell/Tests` pins the same names from the
/// consuming side, and between them the contract has no unwatched edge.

///|
test "event carries its kind first" {
  let json = event("thing", [("a", Json::string("b"))])
  inspect(json.stringify(), content="{\"kind\":\"thing\",\"a\":\"b\"}")
}

///|
test "ready names the session, model, directory and key source" {
  let fields = match
    event("ready", [
      ("session", Json::string("/tmp/s.jsonl")),
      ("model", Json::string("DeepSeek V4 Flash (deepseek-v4-flash)")),
      ("cwd", Json::string("/tmp")),
      ("key", Json::string("missing")),
    ]) {
    Object(fields) => fields
    _ => fail("not an object")
  }
  inspect(fields.get("kind").unwrap().stringify(), content="\"ready\"")
  inspect(fields.get("key").unwrap().stringify(), content="\"missing\"")
  // The cwd in the ready event is what the header shows, so it has to be there rather than
  // derived by the host from its own working directory: the session decides where tools run.
  inspect(fields.get("cwd").unwrap().stringify(), content="\"/tmp\"")
}

///|
test "a piece says which block it belongs to" {
  let json = event("reply", [
    ("id", Json::string("reply-1")),
    ("delta", Json::string("hi")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"reply\",\"id\":\"reply-1\",\"delta\":\"hi\"}",
  )
}

///|
test "a tool row carries its whole state, running or done" {
  let running = event("tool", [
    ("id", Json::string("tool-1")),
    ("name", Json::string("bash")),
    ("detail", Json::string("ls")),
    ("done", Json::boolean(false)),
    ("output", Json::string("")),
    ("error", Json::boolean(false)),
  ])
  inspect(
    running.stringify(),
    content="{\"kind\":\"tool\",\"id\":\"tool-1\",\"name\":\"bash\",\"detail\":\"ls\",\"done\":false,\"output\":\"\",\"error\":false}",
  )
}

///|
test "counts are integers on the wire, not floats" {
  // The host decodes them as `Int`, and a float spelling would make every count a decoding
  // decision. `Json::number` with a `repr` is the only way to say that.
  let json = event("end", [
    ("calls", Json::number(19.0, repr="19")),
    ("tools", Json::number(0.0, repr="0")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"end\",\"calls\":19,\"tools\":0}",
  )
}

///|
test "a turn that finished normally has nothing to report" {
  let result : @agent.TurnResult = {
    session: @core.Session::new(
      {
        id: "x",
        timestamp: "",
        cwd: "/",
        parent_session: None,
        version: Some(3),
      },
      [],
    ),
    replies: [],
    model_calls: 0,
    tool_calls: 0,
    compactions: 0,
    usage: @core.Usage::zero(),
    settled: true,
    cost_limit_hit: false,
    time_limit_hit: false,
    truncated: false,
    request_drift: [],
  }
  inspect(ending_text(result, false), content="")
  inspect(ending_text(result, true), content="stopped")
}

///|
/// The sidebar's own wire, pinned the same way as the rest: field names first.
///
/// `sessions_event` is pure — the store is read into groups by the caller — which is what makes the
/// shape assertable here without a disk. The host decodes these names by hand, so a rename that only
/// one side noticed is a sidebar that never fills.
test "the session list carries its workspaces and their sessions" {
  let json = sessions_event([
    (
      "/home/me/project",
      "project",
      true,
      [
        session_row(
          "/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl", "set up the project",
          1787466378656L, true, false,
        ),
      ],
    ),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"sessions\",\"workspaces\":[{\"cwd\":\"/home/me/project\",\"label\":\"project\",\"current\":true,\"sessions\":[{\"path\":\"/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl\",\"id\":\"01a02d4c\",\"label\":\"set up the project\",\"modified\":1787466378656,\"current\":true,\"running\":false}]}]}",
  )
}

///|
test "a session's id is the last part of its file name" {
  // The same string the web UI's sidebar shows, because both front ends describe one store and two
  // ids for one session would be two names for it.
  assert_eq(
    short_id("/store/--tmp--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl"),
    "01a02d4c",
  )
  // A file that is not named the way pi names them still gets an id rather than a crash.
  assert_eq(short_id("/tmp/plain.jsonl"), "plain")
  assert_eq(short_id("/tmp/nothing"), "nothing")
}

///|
/// A history is rows, not events: nothing in it is still arriving, which is what lets the host render
/// its markdown for the whole of it.
test "a replayed session is rows, all of them complete" {
  let session = @core.parse_session_file(@core.small_session_file)
  let rows = history_rows(session)
  let kinds : Array[String] = []
  for row in rows {
    let fields = match row {
      Json::Object(fields) => fields
      _ => fail("a row is not an object")
    }
    kinds.push(
      match fields.get("kind").unwrap() {
        Json::String(kind) => kind
        _ => fail("a row kind is not a string")
      },
    )
    inspect(fields.get("complete").unwrap().stringify(), content="true")
    // The host appends live deltas to ids it was given by the shell, so a history id has to be a
    // name the live stream would never choose.
    assert_true(fields.get("id").unwrap().stringify().has_prefix("\"h-"))
  }
  // A thinking block and the answer after it are two rows, as they are in the live transcript.
  assert_eq(kinds, ["user", "thinking", "reply"])
}

///|
test "history keeps one row per tool, with its output attached" {
  let text =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
    #|{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-23T06:26:18.662Z","message":{"role":"user","content":[{"type":"text","text":"list it"}],"timestamp":1}}
    #|{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-08-23T06:26:19.662Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"bash","arguments":{"command":"ls"}}],"api":"a","provider":"p","model":"m","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","timestamp":2}}
    #|{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-08-23T06:26:20.662Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"bash","content":[{"type":"text","text":"a.txt"}],"isError":false,"timestamp":3}}
  let rows = history_rows(@core.parse_session_file(text))
  inspect(
    rows.map(row => row.stringify()).join("\n"),
    content="{\"kind\":\"user\",\"id\":\"h-1\",\"text\":\"list it\",\"complete\":true,\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false}\n{\"kind\":\"tool\",\"id\":\"h-2\",\"text\":\"\",\"complete\":true,\"name\":\"bash\",\"detail\":\"ls\",\"output\":\"a.txt\",\"error\":false}",
  )
}

///|
test "a compaction stands in for the history it replaced" {
  let text =
    #|{"type":"session","version":3,"id":"s2","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
    #|{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-23T06:26:18.662Z","message":{"role":"user","content":[{"type":"text","text":"the old question"}],"timestamp":1}}
    #|{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-08-23T06:26:19.662Z","message":{"role":"user","content":[{"type":"text","text":"the current question"}],"timestamp":2}}
    #|{"type":"compaction","id":"c1","parentId":"m2","timestamp":"2026-08-23T06:26:20.662Z","summary":"it was about the old question","firstKeptEntryId":"m2","tokensBefore":100}
  let rows = history_rows(@core.parse_session_file(text))
  let kinds : Array[String] = []
  for row in rows {
    match row {
      Json::Object(fields) =>
        kinds.push(
          match fields.get("kind").unwrap() {
            Json::String(kind) => kind
            _ => fail("a row kind is not a string")
          },
        )
      _ => fail("a row is not an object")
    }
  }
  // The summary is the only record of what it replaced, and the question it stands in front of is
  // still there: a replay that dropped either would show a conversation with a hole in it.
  assert_eq(kinds, ["note", "user"])
}

///|
/// The settings the host needs to draw a panel: where the key comes from, and which tools are on.
///
/// The key itself is not in it, and that is the point of the event rather than an omission — the host
/// draws a panel, not a turn, and the value of a credential has no business on a wire that only ever
/// shows it dimmed.
test "the settings event names the key source and never the key" {
  inspect(
    key_source_name(Some({ key: "sk-secret", source: @core.Environment, })),
    content="environment",
  )
  inspect(
    key_source_name(Some({ key: "sk-secret", source: @core.Saved, })),
    content="saved",
  )
  inspect(
    key_source_name(Some({ key: "sk-secret", source: @core.Pi, })),
    content="pi",
  )
  inspect(key_source_name(None), content="none")
}

///|
/// A double-clicked `.app` gets `/` as its working directory, and `/` is not a workspace.
///
/// The substitution is asserted here rather than left to the launch, because the failure it prevents
/// is invisible from the outside: a session that works, in a store slice nobody will ever find again.
test "the root directory is read as no directory at all" {
  inspect(working_dir("/", "/Users/me"), content="/Users/me")
  inspect(
    working_dir("/Users/me/project", "/Users/me"),
    content="/Users/me/project",
  )
  // A directory that happens to be `home` is still the directory it is, not a second guess.
  inspect(working_dir("/Users/me", "/Users/me"), content="/Users/me")
}

///|
/// The three words the panel sends, and what each one is parsed as.
///
/// A key is the one argument that is not trimmed: it is a credential, and a space inside one belongs
/// to the credential. Everything else is a path or a mode, where whitespace is the sender's mistake
/// rather than the value.
test "the panel's commands parse to what they say" {
  // The key is the case worth pinning: it is the one argument that keeps its spaces.
  assert_true(
    command_of("/key sk-abc def") is SaveKey(key) && key == "sk-abc def",
  )
  assert_true(command_of("/key-clear") is ClearKey)
  assert_true(command_of("/settings") is ListSettings)
  assert_true(command_of("/mode code") is SetMode(name) && name == "code")
  // The commands that were already there are not shadowed by the new prefixes.
  assert_true(
    command_of("/model deepseek-v4-flash") is Model(id) &&
    id == "deepseek-v4-flash",
  )
  assert_true(command_of("hello") is Prompt(text) && text == "hello")
}

///|
/// The settings event as the host's decoder sees it, pinned from the producing side.
///
/// The same literal `PiModelTests/SettingsTests.swift` decodes. `path` is the one field a reader acts
/// on when they would rather edit the file, so it is asserted rather than left to the schema.
test "settings carry the key source, the flags, the mode and the file" {
  let json = event("settings", [
    ("key", Json::string("environment")),
    ("env", Json::boolean(true)),
    ("saved", Json::boolean(true)),
    ("mode", Json::string("code")),
    ("path", Json::string("/Users/me/.pi-mb/settings.json")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"settings\",\"key\":\"environment\",\"env\":true,\"saved\":true,\"mode\":\"code\",\"path\":\"/Users/me/.pi-mb/settings.json\"}",
  )
}
