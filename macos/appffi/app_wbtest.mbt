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
/// The row field that had to become per-session: `running` is read from the registry rather than
/// inferred, because with more than one turn possible "is a turn running" is no longer a question about
/// the process.
///
/// It is still one row per session, which is the shape the host's decoder is pinned against.
test "a session's row says whether that session is running" {
  let the_row = session_row(
    "/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl", "set up the project",
    1787466378656L, false, true,
  )
  let fields = match the_row {
    Json::Object(fields) => fields
    _ => fail("a row is not an object")
  }
  assert_true(fields.get("running") is Some(Json::True))
  // And the row that is not running says so: with two conversations open, a spinner is a claim about
  // *this* one, so it has to be per row rather than one flag for the list.
  let idle = match
    session_row(
      "/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl", "set up the project",
      1787466378656L, true, false,
    ) {
    Json::Object(fields) => fields
    _ => fail("a row is not an object")
  }
  assert_true(idle.get("running") is Some(Json::False))
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
    content="{\"kind\":\"user\",\"id\":\"h-1\",\"text\":\"list it\",\"complete\":true,\"blocks\":[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"list it\"}]}],\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false}\n{\"kind\":\"tool\",\"id\":\"h-2\",\"text\":\"\",\"complete\":true,\"blocks\":null,\"name\":\"bash\",\"detail\":\"ls\",\"output\":\"a.txt\",\"error\":false}",
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

///|
/// A live block's parse is sent when the block stops growing, and only then.
///
/// The timing is the whole of the design: a row that is still arriving is plain text on the host,
/// because re-parsing a growing block on every delta is quadratic — measured, the web UI paid for that
/// lesson with 40KB of reasoning in 64-character frames. So this event exists for the moment a block
/// is over, and what is sent is the same parse the `history` event carries, from the same `md` package
/// the web UI renders with.
test "a finished block carries its parse, and an empty one carries nothing" {
  let json = event("blocks", [
    ("id", Json::string("reply-2")),
    ("blocks", @md.blocks_json("## Heading\n\nwith `code`\n")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"blocks\",\"id\":\"reply-2\",\"blocks\":[{\"t\":\"h\",\"level\":2,\"spans\":[{\"t\":\"text\",\"text\":\"Heading\"}]},{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"with \"},{\"t\":\"code\",\"text\":\"code\"}]}]}",
  )
  // The three shapes the host branches on: a table, a fence with a language, and the null a row with
  // no text carries. All three are cases `AttributedString(markdown:)` gets wrong, which is why the
  // parse crosses as data rather than as source.
  inspect(
    @md.blocks_json("| a | b |\n|:--|--:|\n| 1 | 2 |\n").stringify(),
    content="[{\"t\":\"table\",\"header\":[[{\"t\":\"text\",\"text\":\"a\"}],[{\"t\":\"text\",\"text\":\"b\"}]],\"rows\":[[[{\"t\":\"text\",\"text\":\"1\"}],[{\"t\":\"text\",\"text\":\"2\"}]]],\"align\":[\"left\",\"right\"]}]",
  )
  inspect(
    @md.blocks_json("```moonbit\nfn main {}\n```\n").stringify(),
    content="[{\"t\":\"code\",\"lang\":\"moonbit\",\"text\":\"fn main {}\"}]",
  )
  // Nothing to parse is the one value the host treats as "draw the text instead". Asserted through
  // the JSON literal rather than the value's own printer, because it is the literal that crosses.
  inspect(blocks_of("") is Json::Null, content="true")
}

///|
/// A row of a history carries both the fact that it is finished and its parse.
///
/// `complete` is what tells the host the row has stopped changing, and the parse is what it draws it
/// with. Dropping either one breaks the window: without `complete` the row does not decode at all and
/// the whole transcript goes blank, which is exactly what happened when the parse was added and
/// `complete` was taken away in its place.
test "a history row is complete and carries its parse" {
  let session = @core.parse_session_file(@core.small_session_file)
  let rows = history_rows(session)
  for row in rows {
    let fields = match row {
      Json::Object(fields) => fields
      _ => fail("a row is not an object")
    }
    inspect(fields.get("complete").unwrap().stringify(), content="true")
    assert_true(fields.get("blocks") is Some(_), msg="no blocks field")
  }
}

///|
/// The composer's two new lines, pinned from the producing side.
///
/// Both are read by the host by field name, and the names are the contract — a rename that only one
/// side noticed is a composer that draws nothing under itself, or an attachment that never appears.
test "the images event says what is attached and whether it can be sent" {
  let json = images_event(
    "/store/4001.jsonl",
    [{ path: "/tmp/shot.png", mime_type: "image/png", data: "aGk=", }],
    false,
  )
  inspect(
    json.stringify(),
    content="{\"kind\":\"images\",\"session\":\"/store/4001.jsonl\",\"items\":[{\"path\":\"/tmp/shot.png\",\"mime\":\"image/png\",\"data\":\"aGk=\"}],\"can_send\":false}",
  )
  // Empty is the normal state, and it still says whether the model could be shown one.
  inspect(
    images_event("/store/4001.jsonl", [], true).stringify(),
    content="{\"kind\":\"images\",\"session\":\"/store/4001.jsonl\",\"items\":[],\"can_send\":true}",
  )
}

///|
/// The usage event: session totals, the measured prompt size, and the last turn's own figures.
///
/// The two optional things are asserted by their absence as well as their presence — a cache share
/// that does not exist, and a turn that has not happened, are both fields left out rather than zeroes.
/// A host that decoded `cache_hit` as a number would print `0%` for a conversation with no prompt,
/// which is a claim about the provider's cache rather than a fact.
test "the usage event carries the totals, the prompt size and the last turn" {
  let total : @core.SessionUsage = {
    input: 1200,
    output: 340,
    cache_read: 800,
    cache_write: 0,
    reasoning: 60,
    total_tokens: 2340,
    cost: {
      input: 0.00024,
      output: 0.00068,
      cache_read: 0.000008,
      cache_write: 0.0,
      total: 0.000928,
    },
    replies: 3,
  }
  let last : LastTurn = {
    usage: @core.Usage::zero(),
    model_calls: 2,
    tool_calls: 1,
    cost: 0.000928,
    present: true,
  }
  let fields = match
    usage_event("/store/4001.jsonl", total, 2000, 128000, last) {
    Object(fields) => fields
    _ => fail("the usage event is not an object")
  }
  let text = fields.get("kind").unwrap().stringify()
  inspect(text, content="\"usage\"")
  // Integers on the wire, not floats: a host decoding `3.0` as a count would have to decide what it
  // means, and the JSON spelling is how that decision is avoided.
  inspect(fields.get("turns").unwrap().stringify(), content="3")
  inspect(fields.get("total").unwrap().stringify(), content="2340")
  inspect(fields.get("prompt").unwrap().stringify(), content="2000")
  inspect(fields.get("window").unwrap().stringify(), content="128000")
  // 800 of 2000 prompt tokens were cached.
  inspect(fields.get("cache_hit").unwrap().stringify(), content="\"40\"")
  // Cost is already formatted by `core`, because that is where the decimals decision lives.
  inspect(fields.get("cost").unwrap().stringify(), content="\"0.000928\"")
  inspect(fields.get("last_model_calls").unwrap().stringify(), content="2")
  inspect(fields.get("last_tool_calls").unwrap().stringify(), content="1")

  // A session with nothing in it: no cache share at all, and no last turn.
  let empty : @core.SessionUsage = {
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    reasoning: 0,
    total_tokens: 0,
    cost: {
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    },
    replies: 0,
  }
  let bare = match
    usage_event("/store/4001.jsonl", empty, 0, 128000, no_last_turn()) {
    Object(fields) => fields
    _ => fail("the usage event is not an object")
  }
  assert_true(bare.get("cache_hit") is None, msg="a cache share was invented")
  assert_true(
    bare.get("last_cost") is None,
    msg="a turn that never happened was priced",
  )
  inspect(bare.get("prompt").unwrap().stringify(), content="0")
}

///|
/// Attaching is a set, not a list, and detaching is by the path the composer drew.
test "attaching the same file twice keeps one copy, and detaching removes it" {
  let first : @platform.LoadedImage = { data: "aGk=", mime_type: "image/png", }
  let mut attached = with_attachment([], "/tmp/a.png", first)
  let second : @platform.LoadedImage = {
    data: "b3RoZXI=",
    mime_type: "image/png",
  }
  attached = with_attachment(attached, "/tmp/b.png", second)
  assert_eq(attached.length(), 2)
  // The same path again: one row, and the newest bytes, which is the second pick of that file.
  let repicked : @platform.LoadedImage = {
    data: "dGhpcmQ=",
    mime_type: "image/png",
  }
  attached = with_attachment(attached, "/tmp/a.png", repicked)
  assert_eq(attached.length(), 2)
  assert_eq(attached[0].path, "/tmp/b.png")
  assert_eq(attached[1].data, "dGhpcmQ=")
  attached = without_attachment(attached, "/tmp/b.png")
  assert_eq(attached.length(), 1)
  assert_eq(attached[0].path, "/tmp/a.png")
  // Detaching something that is not there is a no-op rather than an error: the host can send this
  // twice, and a list that changes on a click that removed nothing is a list the reader did not
  // predict.
  assert_eq(without_attachment(attached, "/tmp/gone.png").length(), 1)
}

///|
/// A row's name is unique for the whole session, not merely within its turn.
///
/// This is the bug that made "the thinking and the tool calls disappear when I send the next
/// prompt": the shell named each turn's blocks from one, so the second turn's `thinking-1` and
/// `tool-1` were the *same names* as the first turn's. The host appends a delta to the row with that
/// id, so the second answer was written into the first answer's row, and the first turn's tool rows
/// were overwritten in place — a transcript that silently lost the work the reader was watching.
///
/// The rule is the web UI's, which names its live blocks `stream-<turn>-<seq>` for the same reason.
test "a turn's rows are named so two turns cannot collide" {
  inspect(row_id("reply", 1, 1), content="reply-1-1")
  inspect(row_id("tool", 2, 3), content="tool-2-3")
  // Different turns, same kind and sequence: different names, which is the whole point.
  assert_not_eq(row_id("thinking", 1, 1), row_id("thinking", 2, 1))
  // And the same turn never repeats itself.
  assert_not_eq(row_id("tool", 1, 1), row_id("tool", 1, 2))
}

///|
/// The limits, as the settings panel reads them.
///
/// Each limit carries its own source, because one flag can set one of the three: a panel that showed
/// one source for the group would have to pick a lie for the other two. A limit set by a flag is
/// shown rather than edited, which is what `flag` is for — the field would otherwise appear to accept
/// a value the process will ignore.
test "each limit carries its own value and source" {
  let limits : @core.Limits = {
    max_rounds: { value: 200.0, source: @core.Default, },
    max_cost: { value: 0.05, source: @core.Saved, },
    max_seconds: { value: 1800.0, source: @core.Flag, },
  }
  inspect(
    limits_json(limits).stringify(),
    content="{\"rounds\":{\"value\":\"200\",\"source\":\"default\"},\"cost\":{\"value\":\"0.05\",\"source\":\"saved\"},\"seconds\":{\"value\":\"1800\",\"source\":\"flag\"}}",
  )
  // A whole number is spelled without a decimal point: `200.0` in a field that takes a count reads
  // as a mistake, and a reader would correct it.
  inspect(limit_spelling(200.0), content="200")
  inspect(limit_spelling(0.0), content="0")
  inspect(limit_spelling(0.05), content="0.05")
  inspect(limit_spelling(1800.0), content="1800")
}

///|
/// A turn's continuation is marked on the wire, so the host can start a new set of row names without
/// drawing the question twice.
test "a continued turn says so" {
  let json = event("user", [
    ("text", Json::string("the question already in the log")),
    ("continued", Json::boolean(true)),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"user\",\"text\":\"the question already in the log\",\"continued\":true}",
  )
}

///|
/// A session says whether it holds an interrupted turn, and which question it was asked.
///
/// The host draws a notice with two ways out while this is true, and continuing is what makes it
/// false — so this field is the whole of the state the notice depends on. The prompt travels with it
/// because continuing means handing the model the same question back, and a reader should be able to
/// see which one they are being offered.
test "a session says whether its last turn was interrupted" {
  let json = event("session", [
    ("path", Json::string("/store/s.jsonl")),
    ("cwd", Json::string("/tmp")),
    ("model", Json::string("DeepSeek V4 Flash (deepseek-v4-flash)")),
    ("interrupted", Json::boolean(true)),
    ("interrupted_prompt", Json::string("refactor the parser")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"session\",\"path\":\"/store/s.jsonl\",\"cwd\":\"/tmp\",\"model\":\"DeepSeek V4 Flash (deepseek-v4-flash)\",\"interrupted\":true,\"interrupted_prompt\":\"refactor the parser\"}",
  )
}

///|
/// The three fields of a limits command, and the empty ones that mean "no opinion".
///
/// Missing fields are empty strings rather than an error: a panel that sends two of the three is
/// telling the shell to clear the third, and that is a decision it can only have made deliberately.
test "a limits command reads three fields, and a missing one is empty" {
  let full = set_limits_from("200 0.05 1800")
  assert_true(full is SetLimits("200", "0.05", "1800"))
  let partial = set_limits_from("200 0.05")
  assert_true(partial is SetLimits("200", "0.05", ""))
  let none = set_limits_from("   ")
  assert_true(none is SetLimits("", "", ""))
}

///|
/// The commands that carry a path, and the one that carries a path *and* a name.
///
/// The rename is split at the first space after the path: a path cannot contain one in this spelling,
/// and the name is allowed to.
test "rename splits at the first space, and the path commands keep their spaces" {
  assert_true(
    command_of("/rename /store/a.jsonl my session")
    is Rename("/store/a.jsonl", "my session"),
  )
  assert_true(
    command_of("/rename /store/a.jsonl ") is Rename("/store/a.jsonl", ""),
  )
  assert_true(
    command_of("/restore /store/a.jsonl") is Restore("/store/a.jsonl"),
  )
  // A path with spaces in it survives, which is why these are not split on every space.
  assert_true(
    command_of("/open /Users/me/my work/s.jsonl")
    is Open("/Users/me/my work/s.jsonl"),
  )
  assert_true(command_of("/skill moonbit") is ToggleSkill("moonbit"))
  // A prompt is a prompt: anything that is not one of the known first words goes to the model whole.
  assert_true(
    command_of("explain /rename to me") is Prompt("explain /rename to me"),
  )
}

///|
/// A command word with no argument is never a prompt.
///
/// The hole this closes was real and expensive: `/restore` with nothing after it fell through to the
/// final branch and was *sent to the model as a question* — billed for, answered, and in the log as
/// something the reader never asked. Every path command therefore has a bare form, and it reaches the
/// same handler as a bad argument does.
test "a bare command word is not a prompt" {
  assert_true(command_of("/restore") is Restore(""))
  assert_true(command_of("/attach") is Attach(""))
  assert_true(command_of("/detach") is Detach(""))
  assert_true(command_of("/open") is Open(""))
  assert_true(command_of("/delete") is Delete(""))
  assert_true(command_of("/rename") is Rename("", ""))
  assert_true(command_of("/key") is SaveKey(""))
  // A word that is not a command at all is still a prompt: a reader may well type `/foo` meaning it.
  assert_true(command_of("/foo") is Prompt("/foo"))
}

///|
/// The jobs event: only live jobs, and only the pids that are still there.
///
/// A finished job is kept in the store — it is how a restart accounts for a process it did not start,
/// and how a kill still reaches every pid — but the panel answers "what is still running", so it is
/// not sent. The pids are filtered for the same kind of reason: a command is registered with its own
/// shell and with the helper that reported it, and a reader looking for the process in `ps` should be
/// given the one they can find.
test "the jobs event carries live jobs and their surviving pids" {
  // Built by hand rather than through the store: what is under test is the *filter*, and a store
  // hands back copies — a job marked finished on a copy would be finished nowhere, and the test would
  // pass while asserting nothing.
  let running : @core.Job = {
    id: "bash-1",
    kind: "bash",
    label: "sleep 300",
    session: "/store/s.jsonl",
    status: @core.Running,
    started_at: 0L,
    finished_at: None,
    detail: "",
    pids: [101, 102],
    tail: "",
    output: None,
    call_open: false,
  }
  let finished : @core.Job = {
    id: "bash-2",
    kind: "bash",
    label: "ls",
    session: "/store/s.jsonl",
    status: @core.Completed,
    started_at: 0L,
    finished_at: Some(1000L),
    detail: "exited on its own",
    pids: [200],
    tail: "",
    output: None,
    call_open: false,
  }
  // 101 is alive and 102 is gone: the panel shows what a reader looking in `ps` can act on. 200 is
  // dead too, and its job is not sent at all — a row with nothing left to stop.
  inspect(
    jobs_event([running, finished], [101], 5000L).stringify(),
    content="{\"kind\":\"jobs\",\"items\":[{\"id\":\"bash-1\",\"kind\":\"bash\",\"label\":\"sleep 300\",\"status\":\"running\",\"age_ms\":5000,\"pids\":[101],\"session\":\"/store/s.jsonl\"}]}",
  )
}

///|
/// Nothing running is an empty list rather than no event: the host has to be able to draw "nothing
/// running", and a missing event would leave the last panel standing.
test "an empty jobs event is still an event" {
  inspect(
    jobs_event([], [], 0L).stringify(),
    content="{\"kind\":\"jobs\",\"items\":[]}",
  )
}

///|
/// A pasted image is disposed of by the shell, once, and only when it was told to.
test "temporary attachments are deleted, kept ones are not" {
  assert_true(
    command_of("/attach-temp /tmp/pi-pasted/paste-1.png")
    is AttachTemp("/tmp/pi-pasted/paste-1.png"),
  )
  assert_true(command_of("/attach-temp") is AttachTemp(""))
  assert_true(command_of("/attach /tmp/keep.png") is Attach("/tmp/keep.png"))
  assert_true(command_of("/job-kill bash-1") is KillJob("bash-1"))
  assert_true(command_of("/jobs") is ReportJobs)
}

///|
/// A compaction is a labelled row, and the label is the point of it.
///
/// The summary replaces the reader's own words, and everything above it in the transcript is what it
/// replaced. Drawn as a bare paragraph — which is what an unlabelled note is — it reads as an answer
/// somebody wrote, and the one fact a reader needs about it goes unsaid.
test "a compaction is drawn as a labelled note, not as a paragraph" {
  // Built from entries rather than parsed from a file: what is under test is how a compaction is
  // *drawn*, and a fixture would put the file format in the way of that.
  let header : @core.SessionHeader = {
    id: "s",
    timestamp: "2026-08-23T06:26:15.210Z",
    cwd: "/tmp",
    parent_session: None,
    version: Some(3),
  }
  let asked : @core.Entry = {
    id: "u1",
    parent_id: None,
    timestamp: "2026-08-23T06:26:18.662Z",
    kind: @core.Message(
      message=@core.User({
        content: [@core.Text("say something about earlier work")],
        timestamp: 1787466378656L,
      }),
    ),
  }
  let compacted : @core.Entry = {
    id: "c1",
    parent_id: Some("u1"),
    timestamp: "2026-08-23T06:26:20.000Z",
    kind: @core.Compaction(
      summary="the earlier work was about a parser",
      first_kept_entry_id="u1",
      tokens_before=900000,
      details=None,
      usage=None,
      from_hook=Some(false),
    ),
  }
  let session = @core.Session::new(header, [asked, compacted])
  let rows = history_rows(session)
  let mut found = 0
  for row in rows {
    let fields = match row {
      Json::Object(fields) => fields
      _ => fail("a row is not an object")
    }
    let kind = match fields.get("kind").unwrap() {
      Json::String(kind) => kind
      _ => fail("a row kind is not a string")
    }
    if kind == "note" {
      found += 1
      inspect(
        fields.get("name").unwrap().stringify(),
        content="\"context compacted\"",
      )
      assert_true(
        fields.get("text").unwrap().stringify().contains("parser"),
        msg="the summary is not in the row",
      )
    }
  }
  assert_eq(found, 1)
}

///|
/// The live case: the same thing, said when it happens rather than when the session is reopened.
test "a live compaction says so on the wire" {
  let json = event("note", [
    ("text", Json::string("they asked for a parser")),
    ("name", Json::string("context compacted")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"note\",\"text\":\"they asked for a parser\",\"name\":\"context compacted\"}",
  )
}

///|
/// What a bare `/skill` answers with: the names a turn could use, with their one-liners.
///
/// The row is the answer to "what is here", so it has to be the *enabled* set — the caller filters
/// before calling this — and it has to read as commands rather than as prose, because what the reader
/// does next is type one of them.
test "the skill list reads as a list of commands" {
  let skills : Array[@core.Skill] = [
    { name: "demo", description: "A demo skill", path: "/s/demo/SKILL.md", },
    { name: "plain", description: "", path: "/s/plain/SKILL.md", },
  ]
  inspect(
    skill_list_text(skills),
    content="/skill:demo — A demo skill\n/skill:plain",
  )
  // Nothing to offer is an empty string, and the caller says so in words rather than drawing a row
  // with no content.
  inspect(skill_list_text([]), content="")
}

///|
/// `/skill` on its own is a question about this machine, so it never reaches the model.
///
/// The check is `core`'s and shared with the web UI: a message beginning `/skill:` is not a path, a
/// division or a regex, which is what makes intercepting it safe. A bare `/skill` and a `/skill:`
/// with nothing after it are both what somebody types one character before the name.
test "the bare skill command is recognised, and prose is not" {
  assert_true(@core.is_skill_list_command("/skill"))
  assert_true(@core.is_skill_list_command("/skill:"))
  assert_true(@core.is_skill_list_command("  /skill  "))
  // The cases that must keep going to the model as they were typed.
  assert_false(@core.is_skill_list_command("/skill:demo"))
  assert_false(@core.is_skill_list_command("my /skill is broken"))
  assert_false(@core.is_skill_list_command("/skills"))
}

///|
/// A chosen folder's path survives intact, spaces and all, and a missing one is not a prompt.
///
/// The path is the whole command: a directory called `my work` is an ordinary thing to have, and
/// splitting on spaces would send the agent to `/Users/me/my`. The bare form reaches the same handler
/// as an empty path, which is the rule that keeps a truncated command from being billed for as a
/// question.
test "new-in keeps the path whole, and a bare one is not a prompt" {
  assert_true(command_of("/new-in /Users/me/src") is NewIn("/Users/me/src"))
  assert_true(
    command_of("/new-in /Users/me/my work/pi") is NewIn("/Users/me/my work/pi"),
  )
  // A chooser prints a trailing separator; the shell's `canonical_dir` settles both forms into one.
  assert_true(command_of("/new-in /Users/me/src/") is NewIn("/Users/me/src/"))
  assert_true(command_of("/new-in") is NewIn(""))
  // And it is a command, not prose: the word alone does not go to the model.
  assert_true(
    command_of("explain /new-in to me") is Prompt("explain /new-in to me"),
  )
}
