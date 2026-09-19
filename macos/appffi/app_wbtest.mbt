///|
/// The wire format, pinned from the producing side.
///
/// These assert on the JSON rather than on a log or a golden file, and they are the only place the
/// field names exist twice: the host decodes them by name, so a rename here that the host does not
/// know about is a pair of builds that disagree. `macos/WeiShell/Tests` pins the same names from the
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
/// A deleted conversation, as the host hears about it.
///
/// The event exists because the *outcome* of a delete is not knowable from the click: the shell refuses
/// one with a turn running in it, or a background job still going, and it replaces the session on
/// screen rather than refusing that. A host that put its own offer up would be announcing a delete that
/// may not have happened.
///
/// The path is in the payload as well as in the routing field, and this test is where that is stated:
/// the routing is the envelope's (which session this is about), the payload is what `/restore` takes.
/// `restorable` is the other half of the same point — the checkbox turned "the file is renamed aside"
/// into "the file is gone", and only this side knows which one was asked for.
test "a deleted session is announced with its path, its label and whether it can come back" {
  let kept = deleted_event(
    "/store/--tmp--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl", "set up the project",
    true,
  )
  inspect(
    kept.stringify(),
    content=(
      #|{"kind":"deleted","session":"/store/--tmp--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl","path":"/store/--tmp--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl","label":"set up the project","restorable":true}
    ),
  )
  // The purge: the same event, and the one field that says there is nothing to put back. The host is
  // told rather than left to infer it, because an Undo button on a removed file is a button that lies.
  let gone = deleted_event(
    "/store/--tmp--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl", "set up the project",
    false,
  )
  inspect(
    gone.stringify(),
    content=(
      #|{"kind":"deleted","session":"/store/--tmp--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl","path":"/store/--tmp--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl","label":"set up the project","restorable":false}
    ),
  )
  // And it is *not* a `status`: that event says what the shell is doing, and the host draws it as a
  // line under the composer. Which conversation just left the store is a different fact, and the one
  // that decides whether an Undo button has anything to offer.
  let fields = match kept {
    Json::Object(fields) => fields
    _ => fail("a deleted event is not an object")
  }
  assert_true(fields.get("kind") is Some(Json::String("deleted")))
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
  // A file that is not named the way upstream names them still gets an id rather than a crash.
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
  // **The question carries no parse, and that is the rule rather than an omission.** `blocks` is read
  // by the host in exactly one place — `RootView`'s `case .reply` — and a question is drawn from
  // `text` and `images`; a parse for it is bytes nobody reads (see `draws_markdown`, where the
  // measurement is written down). The tool row is `null` for a different reason: it has no text to
  // parse.
  //
  // `images` is on every row, empty for all of them here: a field that appeared and disappeared would
  // be one more shape for the host to decode, and its default is the empty list either way.
  inspect(
    rows.map(row => row.stringify()).join("\n"),
    content="{\"kind\":\"user\",\"id\":\"h-1\",\"text\":\"list it\",\"complete\":true,\"blocks\":null,\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false,\"images\":[]}\n{\"kind\":\"tool\",\"id\":\"h-2\",\"text\":\"\",\"complete\":true,\"blocks\":null,\"name\":\"bash\",\"detail\":\"ls\",\"output\":\"a.txt\",\"error\":false,\"images\":[]}",
  )
}

///|
/// **A question's picture comes back with the question.** It is in the log, and it used to be drawn
/// nowhere: the reader's own message showed only its words, so a screenshot they had just sent read as
/// one that had not gone.
///
/// An image-only prompt is the sharper half of the same fact: there is no text at all, and a row that
/// was skipped for having no text would drop the message entirely.
test "history gives a question its pictures" {
  let text =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
    #|{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-23T06:26:18.662Z","message":{"role":"user","content":[{"type":"image","data":"AAA=","mimeType":"image/png"},{"type":"text","text":"what is this?"}],"timestamp":1}}
    #|{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-08-23T06:26:19.662Z","message":{"role":"user","content":[{"type":"image","data":"BBB=","mimeType":"image/jpeg"}],"timestamp":2}}
  let rows = history_rows(@core.parse_session_file(text))
  assert_eq(
    rows[0].stringify(),
    "{\"kind\":\"user\",\"id\":\"h-1\",\"text\":\"what is this?\",\"complete\":true,\"blocks\":null,\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false,\"images\":[{\"mime\":\"image/png\",\"data\":\"AAA=\"}]}",
  )
  // The picture-only one: no text, one picture, and it is still a row.
  assert_eq(
    rows[1].stringify(),
    "{\"kind\":\"user\",\"id\":\"h-2\",\"text\":\"\",\"complete\":true,\"blocks\":null,\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false,\"images\":[{\"mime\":\"image/jpeg\",\"data\":\"BBB=\"}]}",
  )
}

///|
/// The text of a question does **not** say "(image attachment)" any more — the picture is drawn
/// instead, and a bubble under a picture that says a picture is there is one thing described twice.
///
/// The placeholder stays for every other reader of the same text, which is what makes this a property
/// of the *question* rather than a change to `content_text`: a tool result for a model that read a
/// file, and the answer text a text-only model is shown, still have to say it in words.
test "a question's own text leaves the pictures out" {
  let content = [
    @core.Content::Image(data="AAA=", mime_type="image/png"),
    @core.Content::Text("what is this?"),
  ]
  assert_eq(user_text(content), "what is this?")
  assert_eq(content_text(content), "(image attachment)\nwhat is this?")
  // And a question that is only a picture says nothing at all, which is what makes it draw as a
  // picture with no bubble under it.
  assert_eq(
    user_text([@core.Content::Image(data="AAA=", mime_type="image/png")]),
    "",
  )
}

///|
/// The rule itself, at the one place it is decided: only the answer is drawn as markdown.
///
/// Pinned because it is a fact *two* sides have to agree about — the shell decides what to send and the
/// host decides what to read — and a disagreement is silent in the cheap direction (a parse nobody
/// reads) and invisible in the other until a row stops rendering. The measurement behind the rule is in
/// `draws_markdown`.
test "only the answer's row is drawn as markdown" {
  assert_true(
    blocks_of("reply", "**bold**").stringify().has_prefix("[{\"t\":\"p\""),
  )
  for kind in ["user", "thinking", "tool", "note"] {
    assert_true(
      blocks_of(kind, "**bold**") is Json::Null,
      msg="a \{kind} row is drawn from its text, so it carries no parse",
    )
  }
  // A row with nothing to parse is `null` whatever its kind: one rule for the host, not two.
  assert_true(blocks_of("reply", "") is Json::Null)
}

///|
/// History ids are counted **per session**, so two sessions both number their rows `h-1`, `h-2`, …
///
/// Pinned because a host-side consequence depends on it and nothing in the shell would notice if it
/// changed: the host draws a transcript with `ForEach(turns, id: \.element.id)`, and a turn's id is its
/// question's row id. Two conversations that both start `h-1` therefore hand SwiftUI the *same* row
/// identities across a switch, and a view it considers unchanged keeps its `@State` — which is how a
/// fold the reader opened in one conversation comes back open over a different one. The host answers
/// that by scoping the transcript's rows to their session (`RootView.swift`), which is correct whether
/// or not this stays true; this test is here so that a change in the shell is a *decision* rather than
/// a surprise.
test "history ids start over in every session" {
  let first = history_rows(@core.parse_session_file(@core.small_session_file))
  let second = history_rows(@core.parse_session_file(@core.small_session_file))
  let ids = fn(rows : Array[Json]) {
    rows.map(fn(row) {
      match row {
        Json::Object(fields) => fields.get("id").unwrap().stringify()
        _ => "?"
      }
    })
  }
  assert_eq(ids(first), ids(second))
  assert_eq(ids(first)[0], "\"h-1\"")
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
/// The same literal `WeiModelTests/SettingsTests.swift` decodes. `path` is the one field a reader acts
/// on when they would rather edit the file, so it is asserted rather than left to the schema.
test "settings carry the key source, the flags, the mode and the file" {
  let json = event("settings", [
    ("key", Json::string("environment")),
    ("env", Json::boolean(true)),
    ("saved", Json::boolean(true)),
    ("mode", Json::string("code")),
    ("path", Json::string("/Users/me/.wei/settings.json")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"settings\",\"key\":\"environment\",\"env\":true,\"saved\":true,\"mode\":\"code\",\"path\":\"/Users/me/.wei/settings.json\"}",
  )
}

///|
/// A finished reasoning block crosses as text and **not** as a parse.
///
/// The largest single saving on this wire, and the one worth a test of its own: on a measured 30MB
/// session reasoning was 1.6MB of the 4.05MB `history` event, and the host draws it as a three-line
/// peek of `row.text`. Its parse was the most expensive thing the shell produced per session opened
/// (29ms) and nothing read it.
///
/// Asserted through `draws_markdown` rather than through a rendered event, because the emit path is
/// C and cannot be captured here; the pairing with the response shape is the test above.
test "a reasoning block is not drawn as markdown" {
  assert_true(draws_markdown("reply"))
  for kind in ["thinking", "user", "tool", "note"] {
    assert_true(
      draws_markdown(kind) == false,
      msg="\{kind} is drawn from its text",
    )
  }
}

///|
/// A block's rendering crosses as the same parse the `history` event carries, from the same `md`
/// package — and it names how much of it the host is expected to already have.
///
/// The `from` field is what makes rendering an answer while it arrives possible: a block that is still
/// growing is re-sent as the part that changed, so the part the reader has already read is never sent
/// twice. `0` means the whole block, which is what a block that has stopped growing always sends.
test "a block's rendering carries its parse and the index it starts at" {
  let json = event("blocks", [
    ("id", Json::string("reply-2")),
    ("from", Json::number(0, repr="0")),
    ("blocks", @md.blocks_json("## Heading\n\nwith `code`\n")),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"blocks\",\"id\":\"reply-2\",\"from\":0,\"blocks\":[{\"t\":\"h\",\"level\":2,\"spans\":[{\"t\":\"text\",\"text\":\"Heading\"}]},{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"with \"},{\"t\":\"code\",\"text\":\"code\"}]}]}",
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
  inspect(blocks_of("reply", "") is Json::Null, content="true")
}

///|
/// The live rendering of a block that is still growing: the finished part, once, and never the part
/// that is still being written.
///
/// The rule is the one thing that makes the feature affordable: the prefix up to the last blank line
/// is parsed and sent when it first appears, and every frame after that is a diff — so the bytes on
/// the wire are the bytes of the answer rather than the answer once per frame. What the reader has
/// already read never moves, which is also what keeps the screen from reflowing under them.
fn live_state(id : String) -> LiveMarkdown {
  { id, sent: [], at_length: 0, at_ms: 0, }
}

///|
test "a live frame carries the blocks that finished, not the one being written" {
  let state = live_state("reply-1-1")
  let frame = live_frame(state, "one\n\ntwo", 9, 1000).unwrap()
  inspect(
    event("blocks", frame.fields()).stringify(),
    content="{\"kind\":\"blocks\",\"id\":\"reply-1-1\",\"from\":0,\"blocks\":[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"one\"}]}]}",
  )
  // The open paragraph is not in the frame: it is already on the host's screen as text, and sending
  // it would be a frame that redraws it. The frame also recorded what it has sent.
  inspect(state.sent.length().to_string(), content="1")
}

///|
/// The second frame of the same block is only the part that changed — which is the whole point of the
/// diff, and the difference between one parse per block and one parse per frame.
test "a later live frame starts where the last one ended" {
  let state = live_state("reply-1-1")
  ignore(live_frame(state, "one\n\ntwo", 9, 1000))
  let frame = live_frame(state, "one\n\ntwo\n\nthree", 17, 1200).unwrap()
  inspect(
    event("blocks", frame.fields()).stringify(),
    content="{\"kind\":\"blocks\",\"id\":\"reply-1-1\",\"from\":1,\"blocks\":[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"two\"}]}]}",
  )
}

///|
/// The two gates, and both of them are needed. The clock alone would let a fast model pile up a
/// second of text and then send it all at once — a stall in the middle of a stream, which is the one
/// thing streaming exists to avoid. The size alone would make a slow model's every delta pay for a
/// parse, and a model trickling out one character at a time is exactly the case this is *not* for.
test "a live frame is refused until enough has changed or enough time has passed" {
  let state = live_state("reply-1-1")
  ignore(live_frame(state, "one\n\ntwo", 9, 1000))
  // Same text, no time: refused, and refused *before* anything is parsed — which is the whole reason
  // the gate is its own function: this is the common case, one delta out of many.
  inspect(live_due(state, 9, 1010), content="false")
  // Enough text, no time: due. (`LIVE_MARKDOWN_CHARS` is 64, and the paragraph below is longer.)
  let grown = "one\n\ntwo\n\n" + "x".repeat(80)
  inspect(live_due(state, grown.length(), 1010), content="true")
  // Time alone: due, so a model sending a few characters a second still renders.
  inspect(live_due(state, 9, 1300), content="true")
}

///|
/// A due frame with nothing new *finished* in it says nothing.
///
/// The open paragraph is already on the host's screen as text, so a frame that re-sent it would
/// redraw the same paragraph — and the clock having moved does not change that.
test "a due frame with nothing finished in it is empty" {
  let state = live_state("reply-1-1")
  ignore(live_frame(state, "one\n\ntwo", 9, 1000))
  inspect(live_frame(state, "one\n\ntwo", 9, 9999) is None, content="true")
  // But the attempt still moved the clock, so the next delta is judged against it.
  inspect(live_due(state, 9, 9999), content="false")
}

///|
/// The host's copy of a row after a frame — the same rule `WeiModel`'s `Conversation.apply` uses.
///
/// Kept here rather than in the shell because it is the host's behaviour that the frames have to
/// reconstruct, and the shell has no use for it.
fn applied(held : Array[@md.Block], frame : LiveFrame) -> Array[@md.Block] {
  let head = if frame.from < held.length() {
    held[:frame.from].to_owned()
  } else {
    held
  }
  head + frame.blocks
}

///|
/// **The property the whole live path rests on**: replaying a block's frames gives the same document
/// as parsing the finished block once.
///
/// Asserted by replaying the deltas of a real-shaped answer the way the shell streams them — in
/// 40-character pieces, at 20ms intervals, so the two gates admit some frames and refuse others — and
/// comparing the host's copy with one parse of the whole block.
///
/// This is the test that catches a frame dropped, a diff off by one, a tail that repeats the head, and
/// a final block that never arrives. It caught the second of those: the first version of the live frame
/// carried the whole parse rather than the tail, and the host applied it as `head + head + tail` —
/// which no single-frame test would have noticed, because one frame of a block with no history looks
/// exactly right either way.
test "replaying the frames of a block gives back the block" {
  let source = "## Title\n\nfirst paragraph here\n\nsecond paragraph\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- one\n- two\n\ntail\n\n"
  let state = live_state("reply-9-1")
  let mut held : Array[@md.Block] = []
  let mut now = 1000UL
  for at in 0..<(source.length() + 1) {
    let arrived = source[:at].to_owned()
    // The shell's own cadence: the clock moves, so the time gate admits frames as the block grows.
    now += 20
    match live_frame(state, arrived, at, now) {
      Some(frame) => held = applied(held, frame)
      None => ()
    }
  }
  // The end of a block is not a live frame: the shell parses the whole of it and diffs, which is the
  // one parse that is allowed to be of the whole thing.
  let whole = @md.parse(source)
  let from = @md.diff_prefix(state.sent, whole)
  held = applied(held, {
    id: "reply-9-1",
    from,
    blocks: whole[from:].to_owned(),
  })
  inspect(held == whole, content="true")
  // And more than one frame was needed, or the replay above would be testing nothing.
  inspect(state.sent.length() > 1, content="true")
}

///|
/// A block that has not written a blank line yet has nothing finished in it, so there is nothing to
/// render — the host draws the text, which is always right.
test "a block with nothing finished sends no frame" {
  let state = live_state("reply-2-1")
  inspect(
    live_frame(state, "one long paragraph", 17, 1000) is None,
    content="true",
  )
}

///|
/// A fence is the case that would come out wrong: a blank line inside it is a blank line in a code
/// block, not between blocks — cutting there would show two code blocks where the model wrote one.
test "a blank line inside an open fence is not a live frame" {
  let state = live_state("reply-3-1")
  inspect(live_frame(state, "```\na\n\nb", 8, 1000) is None, content="true")
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
///
/// The context block is asserted the same way round: a figure for the next request, where that figure
/// came from, what part of it the reader cannot change, and whether the window is nearly full. The
/// three ways those go wrong are all here — a figure reported as a measurement when it was a guess, a
/// session with nothing in it reported as a context of the system prompt's size, and a window that is
/// about to be compacted reported as nothing special.
test "the usage event carries the totals, the context pressure and the last turn" {
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
  let context : ContextFacts = {
    tokens: 3000,
    provider_measured: true,
    overhead: 1300,
    window: 128000,
    compact_soon: false,
  }
  let fields = match
    usage_event("/store/4001.jsonl", total, 2000, context, last) {
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
  // The number that decides when the conversation is summarized, and it is *larger* than the prompt
  // size on purpose: the prompt is what the last request measured, and this is that plus what has
  // been added since.
  inspect(fields.get("context").unwrap().stringify(), content="3000")
  inspect(
    fields.get("context_source").unwrap().stringify(),
    content="\"provider\"",
  )
  inspect(fields.get("overhead").unwrap().stringify(), content="1300")
  inspect(fields.get("window").unwrap().stringify(), content="128000")
  inspect(fields.get("compact_soon").unwrap().stringify(), content="false")
  inspect(fields.get("reasoning").unwrap().stringify(), content="60")
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
    usage_event("/store/4001.jsonl", empty, 0, empty_context(), no_last_turn()) {
    Object(fields) => fields
    _ => fail("the usage event is not an object")
  }
  assert_true(bare.get("cache_hit") is None, msg="a cache share was invented")
  assert_true(
    bare.get("last_cost") is None,
    msg="a turn that never happened was priced",
  )
  assert_true(
    bare.get("last_cache_read") is None,
    msg="a last turn that never happened was given cache readings",
  )
  inspect(bare.get("prompt").unwrap().stringify(), content="0")
  // And no context: a session that has asked nothing has not "used the system prompt", which is what
  // a figure of `overhead` here would say.
  inspect(bare.get("context").unwrap().stringify(), content="0")
  inspect(
    bare.get("context_source").unwrap().stringify(),
    content="\"estimated\"",
  )
  inspect(bare.get("compact_soon").unwrap().stringify(), content="false")
}

///|
/// A context with nothing in it, as `context_facts` builds one for an empty session.
///
/// Written out rather than derived from a session because the two properties under test are the ones
/// an empty session exists to check: the figure is zero, and it is *not* a measurement.
fn empty_context() -> ContextFacts {
  {
    tokens: 0,
    provider_measured: false,
    overhead: 1300,
    window: 128000,
    compact_soon: false,
  }
}

///|
/// A window that is nearly full says so, and the last turn's own cache and reasoning come with it.
///
/// Both are the figures a reader reaches for when one turn was much cheaper than another, and neither
/// is derivable from the session totals: a turn whose prompt was already cached is one the totals show
/// as expensive.
test "a nearly full window and a cached last turn are both visible" {
  let total : @core.SessionUsage = {
    input: 100,
    output: 20,
    cache_read: 900,
    cache_write: 0,
    reasoning: 0,
    total_tokens: 120,
    cost: {
      input: 0.000014,
      output: 0.0000028,
      cache_read: 0.00000042,
      cache_write: 0.0,
      total: 0.00001722,
    },
    replies: 1,
  }
  let last_usage : @core.Usage = {
    input: 40,
    output: 20,
    cache_read: 900,
    cache_write: 0,
    reasoning: Some(11),
    total_tokens: 60,
    cost: {
      input: 0.0000056,
      output: 0.0000028,
      cache_read: 0.00000042,
      cache_write: 0.0,
      total: 0.00000882,
    },
  }
  let last : LastTurn = {
    usage: last_usage,
    model_calls: 1,
    tool_calls: 0,
    cost: 0.00000882,
    present: true,
  }
  let tight : ContextFacts = {
    tokens: 120000,
    provider_measured: false,
    overhead: 1300,
    window: 128000,
    compact_soon: true,
  }
  let fields = match
    usage_event("/store/4001.jsonl", total, 119000, tight, last) {
    Object(fields) => fields
    _ => fail("the usage event is not an object")
  }
  inspect(fields.get("compact_soon").unwrap().stringify(), content="true")
  inspect(
    fields.get("context_source").unwrap().stringify(),
    content="\"estimated\"",
  )
  inspect(fields.get("last_cache_read").unwrap().stringify(), content="900")
  inspect(fields.get("last_reasoning").unwrap().stringify(), content="11")
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
/// **The prompt carries its pictures with it.** It is the only moment they can: the shell empties the
/// composer in the same breath, so a host that read them from `images` afterwards would be drawing a
/// composer that no longer has them.
///
/// Echoed rather than pointed at by path, and that is the same decision `core` makes about the log: the
/// file behind a picture may be temp, may be gone, and may never have existed on the reader's machine.
test "a prompt carries the pictures it was sent with" {
  let json = event("user", [
    ("text", Json::string("what is this?")),
    ("continued", Json::boolean(false)),
    (
      "images",
      Json::array([
        image_row("image/png", "AAA="),
        image_row("image/jpeg", "BBB="),
      ]),
    ),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"user\",\"text\":\"what is this?\",\"continued\":false,\"images\":[{\"mime\":\"image/png\",\"data\":\"AAA=\"},{\"mime\":\"image/jpeg\",\"data\":\"BBB=\"}]}",
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
  // The other answer to "and the file?", and a word rather than a flag inside the other one: the two
  // are two intentions, and a reader of a wire log can see which was asked for.
  assert_true(command_of("/purge") is Purge(""))
  assert_true(command_of("/purge /store/a.jsonl") is Purge("/store/a.jsonl"))
  // The two halves of removing a project, spelled as two words for the same reason: one answer leaves
  // the conversations on disk and the other does not, and a wire log should say which was asked for.
  assert_true(command_of("/workspace-remove") is WorkspaceRemove(""))
  assert_true(command_of("/workspace-delete") is WorkspaceDelete(""))
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
    command_of("/attach-temp /tmp/wei-pasted/paste-1.png")
    is AttachTemp("/tmp/wei-pasted/paste-1.png"),
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
    command_of("/new-in /Users/me/my work/wei")
    is NewIn("/Users/me/my work/wei"),
  )
  // A chooser prints a trailing separator; the shell's `canonical_dir` settles both forms into one.
  assert_true(command_of("/new-in /Users/me/src/") is NewIn("/Users/me/src/"))
  assert_true(command_of("/new-in") is NewIn(""))
  // And it is a command, not prose: the word alone does not go to the model.
  assert_true(
    command_of("explain /new-in to me") is Prompt("explain /new-in to me"),
  )
}

///|
/// "New session" carries the project the reader is looking at, and the two new-session words do not
/// get in each other's way.
///
/// **This is the bug the window had.** The middle column lists *one* project while the shell knew only
/// the project of the session on screen, so `/new` with no payload created the session in the old
/// project — and the window, following `currentPath`, moved its own selection back there. The payload
/// is what fixes it: the reader's project crosses with the click, the same way the web UI's row has
/// always carried `data-new`. The bare form stays, and means "where the session on screen is".
///
/// The near-miss worth pinning is the pair: `/new-in /x` must not be read as `/new` with the project
/// `-in /x`, and `-` is not a space, so it cannot be — but that is exactly the kind of assumption a
/// test is for.
test "new-session names its project, and is not confused with new-in" {
  assert_true(command_of("/new") is NewSession(""))
  assert_true(command_of("/new /Users/me/src") is NewSession("/Users/me/src"))
  // A path is a path here too: a directory called `my work` is an ordinary thing to have.
  assert_true(
    command_of("/new /Users/me/my work/wei")
    is NewSession("/Users/me/my work/wei"),
  )
  // The other word keeps its own meaning: this one adds a workspace, and its payload is not shifted
  // by the new parse sitting next to it.
  assert_true(command_of("/new-in /Users/me/src") is NewIn("/Users/me/src"))
  // And the word alone is a command rather than prose — the rule that keeps a truncated command from
  // being billed for as a question.
  assert_true(command_of("explain /new to me") is Prompt("explain /new to me"))
}

///|
/// A project's path crosses whole, spaces and all — the same rule a chosen folder follows.
///
/// The two words differ only in the answer to "and the conversations?", so they share this: neither
/// splits its argument, and `/workspaces` (the plural, which is what somebody will type) is still an
/// ordinary message rather than a command that silently does something.
test "the two ways to remove a project keep the path whole" {
  assert_true(
    command_of("/workspace-remove /Users/me/src")
    is WorkspaceRemove("/Users/me/src"),
  )
  assert_true(
    command_of("/workspace-delete /Users/me/my work/wei")
    is WorkspaceDelete("/Users/me/my work/wei"),
  )
  // A path with a trailing separator is the chooser's spelling, not a different project.
  assert_true(
    command_of("/workspace-remove /tmp/x/") is WorkspaceRemove("/tmp/x/"),
  )
  assert_true(command_of("/workspaces") is Prompt("/workspaces"))
}

///|
/// Stop reaches the command that is running, and reaches it once.
///
/// This is the difference between a stop that works and a stop that looks like it works: the `aborting`
/// flag is read between steps, and the step in progress *is* the tool — so before the handle was kept, a
/// reader who pressed Stop during a long command watched it run to the end while the status line said
/// "stopping…".
test "stop reaches the running tool, and only once" {
  let stopped : Ref[Int] = { val: 0, }
  let handle : @agent.ToolHandle = {
    name: "bash",
    detail: "sleep 60",
    arguments: Json::string("sleep 60"),
    stop: () => stopped.val = stopped.val + 1,
  }
  let open = Open::new(
    "/tmp/s.mbt",
    "/tmp",
    "m",
    @core.Session::new(
      {
        id: "s",
        timestamp: @core.format_iso_utc(0L),
        cwd: "/tmp",
        parent_session: None,
        version: Some(3),
      },
      [],
    ),
  )

  // Nothing running: a stop is not an error and stops nothing.
  stop_running_tool(open)
  assert_eq(stopped.val, 0)

  // Running: the handle's own stop is what runs — this is the call that cancels the tool's task and, with
  // it, the child process.
  open.running_tool = Some(handle)
  stop_running_tool(open)
  assert_eq(stopped.val, 1)

  // Taken, not read: a second Stop — two clicks, or one arriving after the tool has already reported — must
  // not cancel whatever the turn started next.
  assert_true(open.running_tool is None)
  stop_running_tool(open)
  assert_eq(stopped.val, 1)
}

///|
/// A handle from a finished turn does not outlive it.
///
/// A stale handle would let Stop cancel work belonging to a reader's *next* question, which is a worse
/// failure than not stopping at all: it would look like the agent dropping a command for no reason.
test "the turn's end forgets its tool" {
  let open = Open::new(
    "/tmp/s.mbt",
    "/tmp",
    "m",
    @core.Session::new(
      {
        id: "s",
        timestamp: @core.format_iso_utc(0L),
        cwd: "/tmp",
        parent_session: None,
        version: Some(3),
      },
      [],
    ),
  )
  open.running_tool = Some({
    name: "bash",
    detail: "sleep 60",
    arguments: Json::string("sleep 60"),
    stop: () => (),
  })
  clear_running_tool(open)
  assert_true(open.running_tool is None)
}

///|
/// Paging a transcript: the rules the reader feels.
///
/// These are arithmetic over rows, so they are asserted without a session, a window or an emit — the
/// same reason `page_of` is a pure function. The two that matter most are the two a reader would notice
/// immediately: a page is **never empty** (a window that scrolls into nothing looks broken), and a page
/// **never ends mid-turn** (the host's grouping, `WeiModel.turns(of:)`, describes a turn as "a question
/// and everything after it", and half of one is a conversation that cannot be shown).

///|
/// Rows for a session of `turns` turns, each `fill` characters of answer.
fn rows_of(turns : Int, fill? : Int = 10) -> Array[Json] {
  let rows : Array[Json] = []
  let mut n = 0
  for turn in 0..<turns {
    n += 1
    rows.push(
      Json::object(
        Map([
          ("kind", Json::string("user")),
          ("id", Json::string("h-\{n}")),
          ("text", Json::string("question \{turn}")),
        ]),
      ),
    )
    n += 1
    rows.push(
      Json::object(
        Map([
          ("kind", Json::string("reply")),
          ("id", Json::string("h-\{n}")),
          ("text", Json::string("x".repeat(fill))),
        ]),
      ),
    )
  }
  rows
}

///|
/// The ids of a page, in order.
fn ids_of(rows : Array[Json]) -> Array[String] {
  rows.map(fn(row) {
    match row {
      Json::Object(fields) =>
        match fields.get("id") {
          Some(Json::String(value)) => value
          _ => ""
        }
      _ => ""
    }
  })
}

///|
test "the first page is the newest turns and says what to ask for next" {
  let (page, oldest, more) = page_of(rows_of(10), "", 3, 1_000_000)
  // Three turns, newest last: ids 15..20, and the reader has more above.
  assert_eq(ids_of(page), ["h-15", "h-16", "h-17", "h-18", "h-19", "h-20"])
  assert_eq(oldest, "h-15")
  assert_true(more)
}

///|
/// The page before a cursor ends **exactly** where the cursor starts — no gap, no overlap — and that is
/// the whole contract between the two sides.
test "the page before a cursor ends where the cursor is" {
  let rows = rows_of(10)
  let (first, oldest, _) = page_of(rows, "", 3, 1_000_000)
  let (second, older, _) = page_of(rows, oldest, 3, 1_000_000)
  // The two pages are adjacent and do not overlap.
  assert_eq(ids_of(second), ["h-9", "h-10", "h-11", "h-12", "h-13", "h-14"])
  assert_eq(older, "h-9")
  // Walking all the way up reaches the first row and then says there is nothing more.
  let (third, third_oldest, more) = page_of(rows, older, 3, 1_000_000)
  assert_eq(ids_of(third), ["h-3", "h-4", "h-5", "h-6", "h-7", "h-8"])
  assert_eq(third_oldest, "h-3")
  assert_true(more)
  // The last page is the head of the session, and it says there is nothing before it.
  let (fourth, fourth_oldest, none) = page_of(rows, third_oldest, 3, 1_000_000)
  assert_eq(ids_of(fourth), ["h-1", "h-2"])
  assert_eq(fourth_oldest, "h-1")
  assert_true(
    none == false,
    msg="that was the first row, so there is no page before it",
  )
  assert_true(first.length() > 0)
}

///|
/// **A page is never empty.** A budget of nothing still answers with the turn it is standing on, because
/// a host that asked for more and got nothing stops asking — and the reader is left at the top of a
/// conversation with no way further up.
test "a page is never empty, however small the budget" {
  // Four turns, three allowed, and a byte budget of one: the answer is the newest turn, whole.
  let (page, oldest, more) = page_of(rows_of(4), "", 3, 1)
  assert_eq(ids_of(page), ["h-7", "h-8"])
  assert_eq(oldest, "h-7")
  assert_true(more)
  // And a short session with a real budget is ONE page — which is the path every ordinary session
  // takes, and the reason this feature does not engage at all for them.
  let (all, first, none) = page_of(rows_of(2), "", 6, 262144)
  assert_eq(ids_of(all), ["h-1", "h-2", "h-3", "h-4"])
  assert_eq(first, "h-1")
  assert_true(none == false)
}

///|
/// **A page never ends mid-turn**: whatever the budget, the row it starts on is a `user` row — unless it
/// starts at the beginning of the session, which is the one place a page can start on anything.
test "a page always starts on a question" {
  for cap in [1, 40, 100, 200, 400, 800] {
    let (page, _, _) = page_of(rows_of(8, fill=200), "", 4, cap)
    assert_true(page.length() > 0)
    assert_eq(
      row_kind(page[0]),
      "user",
      msg="a page starting mid-turn, with budget \{cap}",
    )
  }
  // And the same walking up from a cursor.
  let (first, oldest, _) = page_of(rows_of(8, fill=200), "", 2, 1_000_000)
  let (second, _, _) = page_of(rows_of(8, fill=200), oldest, 4, 120)
  assert_true(second.length() > 0)
  assert_eq(row_kind(second[0]), "user")
  assert_true(first.length() > 0)
}

///|
/// A cursor this session does not have — a stale request, or a session rewritten under the host — is
/// answered with the newest page rather than with nothing.
test "an unknown cursor is answered with the newest page" {
  let (page, oldest, more) = page_of(
    rows_of(5),
    "h-does-not-exist",
    2,
    1_000_000,
  )
  assert_eq(oldest, "h-7")
  assert_true(more)
  assert_eq(ids_of(page), ["h-7", "h-8", "h-9", "h-10"])
}

///|
/// A session with nothing in it has no pages, and the answer says so rather than looking like a page
/// that failed.
test "an empty session has no pages" {
  let (page, oldest, more) = page_of([], "", 6, 262144)
  assert_true(page.is_empty())
  assert_eq(oldest, "")
  assert_true(more == false)
}

///|
/// The page ends just before the cursor, so a host that has rows *after* the cursor keeps them. Asserted
/// because the page is built backwards from the cursor, and "ends where the cursor is" is the property
/// the host's prepend depends on.
test "the cursor row itself is not in the page" {
  let rows = rows_of(4)
  let (page, _, _) = page_of(rows, "h-5", 6, 1_000_000)
  assert_eq(ids_of(page), ["h-1", "h-2", "h-3", "h-4"])
}
