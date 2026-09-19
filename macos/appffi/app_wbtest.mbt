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
  // Through the real producer. This used to rebuild the four fields by hand with `event(...)` — which
  // is not the function this event goes out with, and omits its routing `session` — so what it pinned
  // was a shape nothing sends.
  let open = Open::new(
    "/tmp/s.jsonl",
    "/tmp",
    "deepseek-v4-flash",
    "off",
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
  inspect(
    ready_event(open, "missing").stringify(),
    content="{\"kind\":\"ready\",\"session\":\"/tmp/s.jsonl\",\"model\":\"DeepSeek V4 Flash (deepseek-v4-flash)\",\"cwd\":\"/tmp\",\"key\":\"missing\"}",
  )
}

///|
test "a piece says which block it belongs to" {
  inspect(
    piece_event("/tmp/s.jsonl", "reply", "reply-1", "hi").stringify(),
    content="{\"kind\":\"reply\",\"session\":\"/tmp/s.jsonl\",\"id\":\"reply-1\",\"delta\":\"hi\"}",
  )
}

///|
/// The model menu's wire: what each model costs, cut to its column, and the unit said once.
///
/// The prices are strings here for the reason `Pricing::columns` gives — three of them are compared
/// *down* a menu, so their widths are a fact about characters and the shell is the side that owns the
/// rule. What this pins is the shape the host decodes, and the alignment that is the whole point:
/// `0.14`, `0.30` and `1.32` are all four characters, because they all come from one catalog-wide
/// width rather than from each row's own number.
test "the model menu carries each model's prices" {
  inspect(
    models_event("/tmp/s.jsonl", "deepseek-v4-flash").stringify(),
    content="{\"kind\":\"models\",\"session\":\"/tmp/s.jsonl\",\"items\":[{\"id\":\"deepseek-v4-flash\",\"label\":\"DeepSeek V4 Flash\",\"vision\":true,\"prices\":{\"input\":\"0.14\",\"output\":\"0.28\",\"cached\":\"0.0028\"}},{\"id\":\"deepseek-flash\",\"label\":\"DeepSeek V4.1 Flash\",\"vision\":true,\"prices\":{\"input\":\"0.30\",\"output\":\"1.20\",\"cached\":\"0.0060\"}},{\"id\":\"deepseek-v4-pro\",\"label\":\"DeepSeek V4 Pro\",\"vision\":false,\"prices\":{\"input\":\"1.32\",\"output\":\"3.96\",\"cached\":\"0.0440\"}}],\"current\":\"deepseek-v4-flash\",\"unit\":\"US dollars per million tokens — in · out · cached\"}",
  )
}

///|
/// The label is the name, and the id is asked for separately.
///
/// One test, because the two were one string and the split is the whole change: the menu beside a
/// message draws the name, and `model_report` — where a reader is about to type the id — asks for it.
/// The name-only form is what keeps the composer's menu narrower than the one it replaced.
test "a model's label is its name and the id is a separate answer" {
  assert_eq(@core.default_model().label(), "DeepSeek V4 Flash")
  assert_eq(
    @core.default_model().label_with_id(),
    "DeepSeek V4 Flash (deepseek-v4-flash)",
  )
}

///|
/// The thinking menu's wire: the levels *this model* has, and the one in force.
///
/// The literal is the same one `EventTests.testTheThinkingMenuOffersThisModelsLevels` decodes, so the
/// field names have no unwatched edge — and the fact it pins is the one worth pinning: the list is the
/// model's, so `low` is here and is not in the pro model's. A menu drawn from a fixed list would offer
/// it, and the API would refuse the request.
test "the thinking menu carries the model's own levels" {
  inspect(
    think_event("/tmp/s.jsonl", "deepseek-v4-flash", "high").stringify(),
    content="{\"kind\":\"think\",\"session\":\"/tmp/s.jsonl\",\"items\":[{\"id\":\"off\",\"label\":\"Off\",\"detail\":\"fastest and cheapest; answers may be shallower\",\"default\":false},{\"id\":\"low\",\"label\":\"Low\",\"detail\":\"thinks briefly; a sooner first word\",\"default\":false},{\"id\":\"high\",\"label\":\"High\",\"detail\":\"thinks before answering\",\"default\":true},{\"id\":\"max\",\"label\":\"Max\",\"detail\":\"thinks longest; slowest and dearest\",\"default\":false}],\"current\":\"high\"}",
  )
}

///|
/// The pro model's menu is a shorter list, and that is the whole reason the event exists.
///
/// `low` is absent because `deepseek-v4-pro` has no such level. The threshold this crosses is not
/// cosmetic: `low` sent to that model is a request the API refuses.
test "a model without low does not offer it" {
  let json = think_event("/tmp/s.jsonl", "deepseek-v4-pro", "high")
  let text = json.stringify()
  assert_false(text.contains("\"low\""))
  assert_true(text.contains("\"id\":\"high\""))
  assert_true(text.contains("\"id\":\"max\""))
}

///|
/// Every level a menu can offer is a level the request builder will really send.
///
/// The pair is the point: `offered` is what a reader may choose and `resolve` is what goes on the
/// wire, and a level offered but not sendable would be a menu item that either does nothing or is
/// refused. `off` is the case worth checking by hand — it is offered by every model and it is *not* an
/// effort, it is the disabled form.
test "every offered level resolves to something sendable" {
  for spec in @core.model_catalog() {
    for level in spec.thinking_levels.offered() {
      let thinking = spec.thinking_levels.resolve(Some(level))
      match thinking {
        Disabled => assert_eq(level, "off", msg="only off disables")
        Enabled(effort~) =>
          assert_true(effort is Some(_), msg="\{spec.id} \{level}")
      }
    }
    // And the level in force is always one of them, which is what `say_think` relies on for its tick.
    assert_true(
      spec.thinking_levels
      .offered()
      .contains(spec.thinking_levels.in_force(Some("paranoid"))),
      msg=spec.id,
    )
  }
}

///|
test "a tool row carries its whole state, running or done" {
  // The real producer, not a transcription of it. This used to rebuild the same six fields by hand
  // with `event(...)` — the wrong builder, which emits no `session` — so what it pinned was a shape
  // the shell never sends and the host would refuse to decode. A rename here is now a failing test
  // rather than two builds that quietly disagree.
  let running = tool_event(
    "/tmp/s.jsonl", "tool-1", "bash", "ls", false, "", false,
  )
  inspect(
    running.stringify(),
    content="{\"kind\":\"tool\",\"session\":\"/tmp/s.jsonl\",\"id\":\"tool-1\",\"name\":\"bash\",\"detail\":\"ls\",\"done\":false,\"output\":\"\",\"error\":false}",
  )
}

///|
test "counts are integers on the wire, not floats" {
  // The host decodes them as `Int`, and a float spelling would make every count a decoding
  // decision. `Json::number` with a `repr` is the only way to say that. Asked of the real ending
  // event rather than of a hand-built one, so the integer spelling is asserted where it is decided.
  let json = end_event("/tmp/s.jsonl", "", 19, 0, 0.0)
  let fields = match json {
    Object(fields) => fields
    _ => fail("end_event did not build an object")
  }
  // `fail` rather than `unwrap`: a missing key here is this test failing, not the test binary dying,
  // and a panic takes the other seventy-six tests down with it.
  match fields.get("calls") {
    Some(value) => inspect(value.stringify(), content="19")
    None => fail("the end event has no `calls` field")
  }
  match fields.get("tools") {
    Some(value) => inspect(value.stringify(), content="0")
    None => fail("the end event has no `tools` field")
  }
}

///|
/// The two events the shell sends without a session of their own to name.
///
/// Small, and here for one reason: they are the only two emitters with no test, so the field names
/// they carry were pinned nowhere — not by a producing-side test, and not by the host either, whose
/// `status` and `error` cases read `text` and would draw an empty line if it were renamed.
test "a status and an error carry one field, and name the session that sent them" {
  inspect(
    status_event("/tmp/s.jsonl", "thinking…").stringify(),
    content="{\"kind\":\"status\",\"session\":\"/tmp/s.jsonl\",\"text\":\"thinking…\"}",
  )
  inspect(
    error_event("", "a path that does not exist").stringify(),
    content="{\"kind\":\"error\",\"session\":\"\",\"text\":\"a path that does not exist\"}",
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
    last_request: [],
  }
  inspect(ending_text(result, false), content="")
  inspect(ending_text(result, true), content="stopped")
}

///|
/// A retry says so on the status line, and gives the line back when the call answers.
///
/// The pair is the point: this is the one kind of waiting in a turn that nothing else reports. The
/// model has not answered, no tool has run, and the counts have not moved — so without this the
/// line under the composer sits on `thinking…` for the whole idle timeout, three times over.
///
/// The `None` half is not a second sentence: it is the line the caller was showing, handed back — so
/// the two are checked together, and with a counts line as well as the plain one, because a retry
/// that could take the line back but not restore it would leave it saying `no answer` over a turn
/// that is working, and one that restored a thinner line would take the numbers away from the reader
/// who was watching them.
test "a retry is said on the status line and taken back" {
  inspect(
    retry_status(Some({ next: 2, total: 4, }), thinking_status),
    content="no answer — retrying (2 of 4)",
  )
  // The last attempt reads the same way: a reader watching the fourth of four is being told that
  // there is no fifth, which is what the `total` is in the sentence for.
  inspect(
    retry_status(Some({ next: 4, total: 4, }), thinking_status),
    content="no answer — retrying (4 of 4)",
  )
  inspect(
    retry_status(None, "working… 3 model call(s), 2 tool call(s)"),
    content="working… 3 model call(s), 2 tool call(s)",
  )
  inspect(retry_status(None, thinking_status), content="thinking…")
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
          1787466378656L, true, false, true,
        ),
      ],
    ),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"sessions\",\"workspaces\":[{\"cwd\":\"/home/me/project\",\"label\":\"project\",\"current\":true,\"sessions\":[{\"path\":\"/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl\",\"id\":\"01a02d4c\",\"label\":\"set up the project\",\"modified\":1787466378656,\"current\":true,\"running\":false,\"pinned\":true}]}]}",
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
    1787466378656L, false, true, false,
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
      1787466378656L, true, false, false,
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
    content="{\"kind\":\"user\",\"id\":\"h-1\",\"text\":\"list it\",\"complete\":true,\"blocks\":null,\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false,\"images\":[],\"skill\":null}\n{\"kind\":\"tool\",\"id\":\"h-2\",\"text\":\"\",\"complete\":true,\"blocks\":null,\"name\":\"bash\",\"detail\":\"ls\",\"output\":\"a.txt\",\"error\":false,\"images\":[],\"skill\":null}",
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
    "{\"kind\":\"user\",\"id\":\"h-1\",\"text\":\"what is this?\",\"complete\":true,\"blocks\":null,\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false,\"images\":[{\"mime\":\"image/png\",\"data\":\"AAA=\"}],\"skill\":null}",
  )
  // The picture-only one: no text, one picture, and it is still a row.
  assert_eq(
    rows[1].stringify(),
    "{\"kind\":\"user\",\"id\":\"h-2\",\"text\":\"\",\"complete\":true,\"blocks\":null,\"name\":\"\",\"detail\":\"\",\"output\":\"\",\"error\":false,\"images\":[{\"mime\":\"image/jpeg\",\"data\":\"BBB=\"}],\"skill\":null}",
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
/// is invisible from the outside: a session that works, in a store slice nobody will ever find again —
/// or, worse, a *workspace* nobody asked for, growing in a directory the reader never chose. The two
/// answers are asserted in their order, because the order is the whole of the rule: the store is asked
/// first, and the home directory is what a first run falls back to.
test "the root directory is read as no directory at all" {
  // No directory chosen, and the reader has worked somewhere before: that place, not home. This is
  // the case that used to open every Finder launch in `~`.
  inspect(
    start_dir("/", "/Users/me/projects/wei", "/Users/me"),
    content="/Users/me/projects/wei",
  )
  // No directory chosen and nothing in the store: a first run, which has nowhere else to go.
  inspect(start_dir("/", "", "/Users/me"), content="/Users/me")
  // A directory this process was actually given is never second-guessed — not even the one the
  // fallback would have named.
  inspect(
    start_dir("/Users/me/project", "/Users/me/projects/wei", "/Users/me"),
    content="/Users/me/project",
  )
  // A directory that happens to be `home` is still the directory it is.
  inspect(
    start_dir("/Users/me", "/Users/me/projects/wei", "/Users/me"),
    content="/Users/me",
  )
}

///|
/// A session that has not been written yet is listed **under a workspace that already exists**, and
/// never as one of its own.
///
/// The bug this pins is the difference between "the top row of my project" and "a project": the
/// version before this inserted a whole group when no group matched, so every Finder launch drew a
/// workspace named after the home directory (`workspace_name("/Users/me")` → `me`). It then vanished
/// on the reader's first click, because the session on screen had become a file the store lists — so
/// what they were looking at was a row that was not real, in a directory they never chose, which one
/// keystroke would have made real.
///
/// Both halves are here: the session is carried into its own group, and **no group is invented when
/// there is none** — an empty list stays empty, which is what a reader who has just installed the app
/// sees.
test "an unwritten session joins a workspace rather than inventing one" {
  let stored = [("/Users/me/project", "project", false, [])]
  carry_current(
    stored,
    "/Users/me/project",
    session_row("/store/new.jsonl", "new", 7L, true, false, false),
  )
  assert_eq(stored[0].3.length(), 1)
  // A workspace that is not in the list is not added to the list.
  let elsewhere = [("/Users/me/project", "project", false, [])]
  carry_current(
    elsewhere,
    "/Users/me/other",
    session_row("/store/new.jsonl", "new", 7L, true, false, false),
  )
  assert_eq(elsewhere.length(), 1)
  assert_eq(elsewhere[0].3.length(), 0)
  // And the empty store a first run has is left exactly as empty.
  let none : Array[(String, String, Bool, Array[Json])] = []
  carry_current(
    none,
    "/Users/me",
    session_row("/store/new.jsonl", "new", 7L, true, false, false),
  )
  assert_true(none.is_empty())
}

///|
/// A turn with no key is refused **here**, so it never becomes a request.
///
/// The thing this pins is what the reader saw instead: a prompt typed on a first run went to the
/// endpoint and came back as `HTTP 401: Authentication Fails (auth header format should be Bearer
/// sk-...)`. A round trip, a log entry, and a provider talking about its auth header — to learn
/// something this process could see in its own settings. The refusal is a sentence about the panel,
/// because the panel is where the reader can do something about it.
test "a turn with no key is refused before it is sent" {
  // The one word that means "there is nothing to send with".
  assert_true(
    turn_refusal("") is Some(reason) &&
    reason == "no API key — add one in Settings",
  )
  // A key that came from the environment or from the panel is the same fact here: this is not a
  // check on where it came from, which is `@core.choose_api_key`'s decision and nobody else's.
  assert_true(turn_refusal("sk-abc") is None)
}

///|
/// What a reader sees when something they did raised: the message, not the constructor.
///
/// `Failure(…)` is the name of the type a turn happened to be raised through, and it was arriving in
/// front of the reader in the two places that matter most — the first prompt of a new install, and
/// every failed turn. Both sentences were already written for a person; only the wrapper was not.
test "an error is shown as its message" {
  let caught : String = try {
    raise Failure::Failure("the model endpoint returned HTTP 401: why")
  } catch {
    err => @core.error_text(err)
  }
  inspect(caught, content="the model endpoint returned HTTP 401: why")
  // A suberror needs no unwrapping — it already renders as its own sentence — but it must not be
  // mangled into something else on its way out. `DecodeError` is the one that reaches a reader
  // (`session_name_of` is the only place it is caught, and this is the text it would carry).
  let decode : String = try {
    ignore(@core.parse_session_file("{ not json"))
    "no error"
  } catch {
    err => @core.error_text(err)
  }
  inspect(decode, content="line 1: invalid JSON")
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
  // The thinking level, and the two shapes it comes in: a word with an argument is a request, and the
  // word alone is a question. The bare form is listed rather than left to the final branch below, so
  // that a reader asking "what is it set to" does not send the word to the model as a prompt.
  assert_true(command_of("/think low") is Think(level) && level == "low")
  assert_true(command_of("/think off") is Think(level) && level == "off")
  assert_true(command_of("/think") is ReportThink)
  // The commands that were already there are not shadowed by the new prefixes.
  assert_true(
    command_of("/model deepseek-v4-flash") is Model(id) &&
    id == "deepseek-v4-flash",
  )
  assert_true(command_of("hello") is Prompt(text) && text == "hello")
}

///|
/// What the two sentences about thinking say.
///
/// The report names the level the next turn will be sent at and the ones this model has, because
/// those are the two things a reader asking the question wants — and because the sentence is the only
/// way to check the level from a terminal: the menu's tick is a host control.
test "thinking is reported with the level in force and this model's levels" {
  let flash = think_report(
    Open::new(
      "/tmp/s.jsonl",
      "/tmp",
      "deepseek-v4-flash",
      "low",
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
    ),
  )
  inspect(flash, content="thinking: low · available: off, low, high, max")
}

///|
/// The settings event as the host's decoder sees it, pinned from the producing side.
///
/// The same literal `WeiModelTests/SettingsTests.swift` decodes. `path` is the one field a reader acts
/// on when they would rather edit the file, so it is asserted rather than left to the schema.
test "settings carry the key source, the flags, the mode and the file" {
  // Through the real producer, and the **same literal** `WeiModelTests/SidebarTests.swift` decodes.
  //
  // This test used to build six of the ten fields by hand — no `skills`, no `instructions`, no
  // `limits` — so it pinned a shape with four of the host's fields missing, and the only place that
  // shape existed was here. Two literals that are transcriptions of each other catch nothing; the
  // event built by `settings_event` is what actually crosses.
  let json = settings_event(
    "environment",
    true,
    true,
    @core.ToolMode::Code,
    "/Users/me/.wei/settings.json",
    [],
    { text: "Run the tests with moon test.", source: @core.Saved, },
    {
      max_rounds: { value: 200.0, source: @core.Default, },
      max_cost: { value: 0.05, source: @core.Saved, },
      max_seconds: { value: 1800.0, source: @core.Flag, },
    },
  )
  inspect(
    json.stringify(),
    content="{\"kind\":\"settings\",\"key\":\"environment\",\"env\":true,\"saved\":true,\"mode\":\"code\",\"path\":\"/Users/me/.wei/settings.json\",\"skills\":[],\"instructions\":\"Run the tests with moon test.\",\"instructions_source\":\"saved\",\"limits\":{\"rounds\":{\"value\":\"200\",\"source\":\"default\"},\"cost\":{\"value\":\"0.05\",\"source\":\"saved\"},\"seconds\":{\"value\":\"1800\",\"source\":\"flag\"}}}",
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
  // Through the real producer, which parses the source rather than being handed a pre-built
  // `blocks_json` — the parse and the `from` come from the same place in `say_blocks`.
  let json = blocks_event(
    "/tmp/s.jsonl",
    "reply-2",
    0,
    @md.parse("## Heading\n\nwith `code`\n"),
  )
  inspect(
    json.stringify(),
    content="{\"kind\":\"blocks\",\"session\":\"/tmp/s.jsonl\",\"id\":\"reply-2\",\"from\":0,\"blocks\":[{\"t\":\"h\",\"level\":2,\"spans\":[{\"t\":\"text\",\"text\":\"Heading\"}]},{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"with \"},{\"t\":\"code\",\"text\":\"code\"}]}]}",
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
    blocks_frame_event("/tmp/s.jsonl", frame).stringify(),
    content="{\"kind\":\"blocks\",\"session\":\"/tmp/s.jsonl\",\"id\":\"reply-1-1\",\"from\":0,\"blocks\":[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"one\"}]}]}",
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
    blocks_frame_event("/tmp/s.jsonl", frame).stringify(),
    content="{\"kind\":\"blocks\",\"session\":\"/tmp/s.jsonl\",\"id\":\"reply-1-1\",\"from\":1,\"blocks\":[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"two\"}]}]}",
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
  inspect(
    user_event("/tmp/s.jsonl", "the question already in the log", true, []).stringify(),
    content="{\"kind\":\"user\",\"session\":\"/tmp/s.jsonl\",\"text\":\"the question already in the log\",\"continued\":true,\"images\":[]}",
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
  let json = user_event("/tmp/s.jsonl", "what is this?", false, [
    ("image/png", "AAA="),
    ("image/jpeg", "BBB="),
  ])
  inspect(
    json.stringify(),
    content="{\"kind\":\"user\",\"session\":\"/tmp/s.jsonl\",\"text\":\"what is this?\",\"continued\":false,\"images\":[{\"mime\":\"image/png\",\"data\":\"AAA=\"},{\"mime\":\"image/jpeg\",\"data\":\"BBB=\"}]}",
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
  // Through the real snapshot, and the reason is a mistake this test had been hiding: the literal it
  // used to carry named the file `path`, while the shell sends it as `session` — the key the host
  // actually routes on. A hand-written literal cannot disagree with a hand-written literal, so the
  // two builds agreed about a field no host would ever read.
  let open = Open::new(
    "/store/s.jsonl",
    "/tmp",
    "deepseek-v4-flash",
    "off",
    @core.Session::new(
      {
        id: "s",
        timestamp: @core.format_iso_utc(0L),
        cwd: "/tmp",
        parent_session: None,
        version: Some(3),
      },
      [@core.turn_start_entry("refactor the parser", None, 0L)],
    ),
  )
  inspect(
    session_snapshot(open).stringify(),
    content="{\"kind\":\"session\",\"session\":\"/store/s.jsonl\",\"cwd\":\"/tmp\",\"model\":\"DeepSeek V4 Flash (deepseek-v4-flash)\",\"interrupted\":true,\"interrupted_prompt\":\"refactor the parser\"}",
  )
}

///|
/// A turn that ends in a conversation nobody is looking at is **not** a `session` event.
///
/// That distinction is the whole fix for a window that used to jump: the host reads `session` as "this
/// is now on screen", and follows it — so a turn finishing in another conversation took the reader's
/// screen away from what they were reading. `turn_ended_event` is that decision as a pure function, so
/// it can be asserted without a shell, a window or an emit — the same reason `page_of` is one.
test "a turn ending elsewhere is its own event, not a switch" {
  let open = Open::new(
    "/store/s.jsonl",
    "/tmp",
    "m",
    "high",
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

  // On screen: the snapshot, which is what refreshes the notice above the transcript. Its session is
  // the one being drawn, so this moves nobody.
  let here = match turn_ended_event("/store/s.jsonl", open, "finished") {
    Object(fields) => fields
    _ => fail("not an object")
  }
  inspect(here.get("kind").unwrap().stringify(), content="\"session\"")
  inspect(
    here.get("session").unwrap().stringify(),
    content="\"/store/s.jsonl\"",
  )

  // Anywhere else: a fact about that session and nothing about the window.
  let away = match turn_ended_event("/store/other.jsonl", open, "finished") {
    Object(fields) => fields
    _ => fail("not an object")
  }
  inspect(away.get("kind").unwrap().stringify(), content="\"elsewhere\"")
  inspect(away.get("path").unwrap().stringify(), content="\"/store/s.jsonl\"")
  inspect(away.get("outcome").unwrap().stringify(), content="\"finished\"")
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
  inspect(
    note_event("/tmp/s.jsonl", "they asked for a parser", "context compacted").stringify(),
    content="{\"kind\":\"note\",\"session\":\"/tmp/s.jsonl\",\"text\":\"they asked for a parser\",\"name\":\"context compacted\"}",
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
/// `/fork` is a command about the session on screen, so it carries no argument — and the word alone is
/// what makes it a command.
///
/// The interesting half is the boundary: a command that takes no payload has to be **exactly** the word,
/// or a prompt that happens to contain it would become a fork of the reader's conversation. That is the
/// failure this pins, because it is the one that costs work rather than a sentence.
test "fork is a bare command, and prose keeps its meaning" {
  assert_true(command_of("/fork") is Fork)
  assert_true(
    command_of("explain /fork to me") is Prompt("explain /fork to me"),
  )
  // Not a prefix match: a word that merely starts with the command is not the command.
  assert_true(command_of("/forked") is Prompt("/forked"))
  // And a payload is not silently ignored, which would be a fork taken from the wrong conversation.
  assert_true(
    command_of("/fork /other/session.jsonl")
    is Prompt("/fork /other/session.jsonl"),
  )
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
    "high",
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
    "high",
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

// ── a `/skill:<name>` question, live and replayed ───────────────────────────

///|
/// The three parts of a skill question cross the wire as written — live and replayed alike.
///
/// This is the rule the transcript's fold hangs on. The prompt the shell writes is the skill's whole
/// document with the reader's own words after it, so both paths have to say where those words are; and
/// they have to say the *same* thing, which is why this compares the two rather than checking two
/// hand-written expectations. A live turn that draws correctly and a replayed one that draws the
/// document as the reader's sentence is the bug this catches.
test "a skill question crosses as its three parts" {
  let skill : @core.Skill = {
    name: "pdf-report",
    description: "Turn data into a PDF.",
    path: "/home/u/.wei/skills/pdf-report/SKILL.md",
  }
  let body = "# Report\n\nRead reference.md first.\n"
  let expanded = @core.skill_expansion(skill, body, "from data.csv")
  // Live: the `user` event's own fields.
  let live = field_of_fields(user_fields(expanded, false, []), "skill")
  // Replayed: the same prompt, as a session file on disk.
  let header =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
  let file = header + "\n" + user_line("m1", expanded)
  let rows = history_rows(@core.parse_session_file(file))
  let replayed = field_of_object(rows[0], "skill")
  assert_eq(live.stringify(), replayed.stringify(), msg=live.stringify())
  match live {
    Json::Object(fields) => {
      assert_eq(field_of_map(fields, "name").stringify(), "\"pdf-report\"")
      assert_eq(field_of_map(fields, "args").stringify(), "\"from data.csv\"")
      assert_eq(
        field_of_map(fields, "body").stringify(),
        Json::string(body).stringify(),
      )
    }
    _ => fail("the skill field is not an object")
  }
  // The text still crosses whole — the log and the host's `text` are what the model was asked, and
  // that is not the part being changed.
  assert_true(
    field_of_object(rows[0], "text").stringify().has_prefix("\"<skill name="),
  )
}

///|
/// A question the reader typed is told about no skill at all: the field is absent from the live event
/// (rather than false) and `null` in a row (rather than `{}`), so the host has one rule — a framing, or
/// the reader's own words.
test "an ordinary question carries no skill" {
  assert_eq(user_fields("just a question", false, []).length(), 3)
  let header =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
  let rows = history_rows(
    @core.parse_session_file(header + "\n" + user_line("m1", "just a question")),
  )
  assert_eq(field_of_object(rows[0], "skill").stringify(), "null")
}

///|
fn field_of_fields(fields : Array[(String, Json)], key : String) -> Json raise {
  for (name, value) in fields {
    if name == key {
      return value
    }
  }
  fail("\{key} is not in the event: \{fields.length()} fields")
}

///|
fn field_of_object(row : Json, key : String) -> Json raise {
  match row {
    Json::Object(fields) => field_of_map(fields, key)
    _ => fail("not an object")
  }
}

///|
fn field_of_map(fields : Map[String, Json], key : String) -> Json raise {
  match fields.get(key) {
    Some(value) => value
    None => fail("no \{key} in the object")
  }
}

///|
/// One user message, as a session file line.
///
/// Built with the encoder rather than written out, because the skill framing is full of quotes: a
/// hand-written literal would have to escape the very characters whose handling is part of what is
/// being tested.
fn user_line(id : String, text : String) -> String {
  Json::object(
    Map([
      ("type", Json::string("message")),
      ("id", Json::string(id)),
      ("parentId", Json::null()),
      ("timestamp", Json::string("2026-08-23T06:26:18.662Z")),
      (
        "message",
        Json::object(
          Map([
            ("role", Json::string("user")),
            (
              "content",
              Json::array([
                Json::object(
                  Map([
                    ("type", Json::string("text")),
                    ("text", Json::string(text)),
                  ]),
                ),
              ]),
            ),
            ("timestamp", Json::number(1.0)),
          ]),
        ),
      ),
    ]),
  ).stringify()
}

///|
/// The notice for an interrupted turn shows the question **the reader asked**, not the expansion.
///
/// A `/skill:<name>` turn's prompt in the log is the skill's document. Quoted in a three-line notice,
/// that is three lines of somebody else's instructions under the words "this turn was interrupted" —
/// and the one thing the notice is for is letting the reader check it against what they remember
/// asking. The command is what they remember.
///
/// Display only: Continue replays the prompt from the log, so this cannot change what is sent.
test "an interrupted skill turn quotes the command, not the document" {
  let skill : @core.Skill = {
    name: "pdf-report",
    description: "Turn data into a PDF.",
    path: "/home/u/.wei/skills/pdf-report/SKILL.md",
  }
  let body = "# Report\n\nRead reference.md, then run the pipeline.\n"
  assert_eq(
    prompt_as_asked(@core.skill_expansion(skill, body, "from data.csv")),
    "/skill:pdf-report from data.csv",
  )
  // Nothing after the command: the command is the whole of what was asked.
  assert_eq(
    prompt_as_asked(@core.skill_expansion(skill, body, "")),
    "/skill:pdf-report",
  )
  // An ordinary question is handed back untouched, byte for byte.
  assert_eq(prompt_as_asked("refactor the parser"), "refactor the parser")
}

// ── a shell, without a world ─────────────────────────────────────────────────
//
// The seam, exercised. Everything above this line asserts on a *value* an emitter produced, which
// leaves one thing untested and it is the expensive one: whether a command is allowed to happen at
// all, what it says when it is refused, and in what order those two things occur. Those decisions
// live in `Shell::` methods, and until `Shell::of` existed a `Shell` could only be built by
// launching the app — so the only way to reach one was to open the window and look.
//
// These tests build one from a literal `World` and an array to record into. No store, no socket, no
// environment, and the same seam the host crosses.

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

// ── decisions that name a wrong answer ───────────────────────────────────────
//
// Each of these pins a rule whose comment already says what the *mistake* looks like. That is the
// most valuable kind of test to write and the easiest to see the gap in: whoever wrote the comment
// knew the failure mode, and had no way to get a machine to watch for it.

///|
/// A log with one model and one level recorded, or neither.
fn log_of(model : String?, level : String?) -> @core.Session {
  let entries : Array[@core.Entry] = []
  let mut parent : String? = None
  if model is Some(id) {
    entries.push(@core.Entry::{
      id: "m",
      parent_id: parent,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.ModelChange(provider="deepseek", model_id=id),
    })
    parent = Some("m")
  }
  if level is Some(name) {
    entries.push(@core.Entry::{
      id: "l",
      parent_id: parent,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.ThinkingLevelChange(level=name),
    })
  }
  @core.Session::new(
    {
      id: "s",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    entries,
  )
}

///|
/// The model travels as the **two-part spelling**, and an id this build does not know travels as
/// itself.
///
/// The second half is the named mistake: `model_spec_for` answers with the *default's* spec for an
/// unknown id, so the old single-call version drew `DeepSeek V4 Flash` over a log that said
/// `deepseek-v9` — a window confidently naming a model the session is not running on. Which is worse
/// than showing an ugly id, because there is nothing on screen to suggest anything is wrong.
test "an unknown model id is shown as itself, not as the default's name" {
  let open = Open::new(
    "/tmp/s.jsonl",
    "/tmp",
    "deepseek-v4-pro",
    "high",
    log_of(None, None),
  )
  inspect(model_name(open), content="DeepSeek V4 Pro (deepseek-v4-pro)")
  open.model_id = "deepseek-v9"
  inspect(model_name(open), content="deepseek-v9")
}

///|
/// A resumed session runs on **what its log recorded**, not on the build's default.
///
/// The mistake is priced rather than cosmetic: a session last run on the pro model, reopened on the
/// default, silently answers its old questions at a different model's rates.
test "a resumed session's model is the one its log recorded" {
  inspect(
    session_model(log_of(Some("deepseek-v4-pro"), None)),
    content="deepseek-v4-pro",
  )
  // Nothing recorded: a session nobody has asked anything of yet is the one place the default is
  // the honest answer.
  inspect(session_model(log_of(None, None)), content=@core.default_model_id())
}

///|
/// A level the session's model does not have is settled to one it does — per model, not per
/// provider.
///
/// This is `model_catalog.mbt`'s own example, end to end: `deepseek-v4-pro` has no `low`, so a log
/// that recorded one is asking for an effort the API would reject. Answering with the level that
/// will really be used is what keeps a resumed session honest.
test "a recorded level is settled against the model that will run" {
  // `low` exists on flash and not on pro, so the same log means two different things.
  inspect(
    session_level(
      log_of(Some("deepseek-v4-flash"), Some("low")),
      "deepseek-v4-flash",
    ),
    content="low",
  )
  inspect(
    session_level(
      log_of(Some("deepseek-v4-flash"), Some("low")),
      "deepseek-v4-pro",
    ),
    content="high",
  )
  // The rule behind both literals: whatever comes out is a level this model offers, always.
  for model in ["deepseek-v4-flash", "deepseek-v4-pro"] {
    let levels = @core.model_spec_for(model).0.thinking_levels
    for wanted in ["off", "low", "high", "max", "bogus"] {
      let got = session_level(log_of(Some(model), Some(wanted)), model)
      assert_true(
        levels.offered().contains(got),
        msg="\{model} does not offer \{got}, which is what a session recording \{wanted} would run at",
      )
    }
  }
}

///|
/// Switching a session's model re-settles its level, and that is the whole reason it is a function.
///
/// The named mistake is the easy one to write: keep the level, and send `reasoning_effort: low` to a
/// model that has no `low`. Nothing writes to the log here — the driver records both at the top of
/// the next turn — so a reader who changes their mind twice leaves no trace of either decision.
test "retargeting a session clamps its level to the new model" {
  let open = Open::new(
    "/tmp/s.jsonl",
    "/tmp",
    "deepseek-v4-flash",
    "low",
    log_of(None, None),
  )
  retarget(open, "deepseek-v4-pro")
  inspect(open.model_id, content="deepseek-v4-pro")
  // Flash's `low` is not pro's, so it becomes pro's default rather than being carried over.
  inspect(open.think_level, content="high")
  // And a level the new model does have survives the move.
  retarget(open, "deepseek-v4-flash")
  inspect(open.think_level, content="high")
}

///|
/// "The reader may choose" is two facts, and the second one is the one that is easy to miss.
///
/// `turn_in_flight` alone is true for the whole time a turn *runs* — the opening entry is written
/// before any of the work happens — so a log-only answer describes a healthy turn as an interrupted
/// one, and offers to continue a conversation that is being continued, with two buttons that cannot
/// be pressed while it runs. It was found by switching away and coming back to watch the turn that
/// was left behind.
test "a turn that is running is not a turn that was interrupted" {
  inspect(interrupted_turn(open_with_turn(false)), content="true")
  inspect(interrupted_turn(open_with_turn(true)), content="false")
  // No turn open at all: nothing to offer.
  let plain = Open::new("/tmp/s.jsonl", "/tmp", "m", "high", log_of(None, None))
  inspect(interrupted_turn(plain), content="false")
}

///|
/// One open session with a turn that was started and never ended, busy or not.
fn open_with_turn(busy : Bool) -> Open {
  let session = log_of(None, None)
  let started = @core.turn_start_entry("build the thing", None, 0L)
  let open = Open::new(
    "/tmp/s.jsonl",
    "/tmp",
    "deepseek-v4-flash",
    "high",
    @core.Session::new(session.header, [started]),
  )
  open.busy = busy
  open
}

///|
/// A turn that ended in a conversation nobody is looking at is its own event.
///
/// Its own kind rather than a flag on `session`, **so that the window cannot follow it**: a turn
/// ending elsewhere used to arrive as a switch, and the window moved away from what the reader was
/// reading. The path is in the payload as well as in the routing because the host's "show me that
/// one" click hands the payload to `/open` — one is the envelope, the other is a command argument.
test "an elsewhere turn carries its path twice, on purpose" {
  inspect(
    elsewhere_event("/store/other.jsonl", "finished").stringify(),
    content="{\"kind\":\"elsewhere\",\"session\":\"/store/other.jsonl\",\"path\":\"/store/other.jsonl\",\"outcome\":\"finished\"}",
  )
}

// ── one line in, what came out ───────────────────────────────────────────────
//
// `Shell::handle` is the body of the command loop, so these cross the same seam a *keystroke* does.
// Everything above asserts on an event built from values; these assert on what a command **decided**,
// which is where the thirty-six arms and their guards live.
//
// What is deliberately not here: `Prompt`. That arm spawns a real turn, and `with_task_group` waits
// for everything it spawned — so testing it in-process would mean making a request to a provider. Its
// decision (which of the two things a prompt is) is covered where it lives, by `command_of` and
// `turn_refusal`.

///|
/// Send one command line through the loop, and read back everything the shell said.
///
/// The task group is real because the arm genuinely takes one — a command loop that could not answer
/// `abort` while a turn ran is the bug the spawned turns exist to avoid. Nothing is waited on.
async fn command(shell : Shell, line : String) -> Unit {
  ignore(@async.with_task_group(group => ignore(shell.handle(group, line))))
}

///|
/// `abort` does three things, and the second is the one that was measured.
///
/// The flag is read *between steps* and the step in progress is the tool — so with the flag alone, a
/// reader who pressed Stop during a two-minute test suite watched it run to the end while the status
/// line said "stopping…". `stop_running_tool` is what reaches the child process, and the sentence is
/// what tells the reader that the click landed.
async test "abort sets this session's flag, stops its command, and says so" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  let stopped : Ref[Int] = { val: 0, }
  open.running_tool = Some({
    name: "bash",
    detail: "sleep 60",
    arguments: Json::string("sleep 60"),
    stop: () => stopped.val = stopped.val + 1,
  })
  command(shell, "abort")
  assert_true(open.aborting.val)
  assert_eq(stopped.val, 1)
  // And exactly one sentence: the reader is told the click landed, once.
  let lines = seen()
  inspect(lines.length(), content="1")
  inspect(
    lines[0].stringify(),
    content="{\"kind\":\"status\",\"session\":\"/tmp/s.jsonl\",\"text\":\"stopping…\"}",
  )
}

///|
/// `quit` is the only thing a command can say to the loop, and it stops **every** session.
///
/// Not just the one on screen: this is the process shutting down, and a turn left running in a
/// conversation nobody was looking at would keep the runtime's event loop alive after the window
/// closed. The loop's own `quit` flag is what the returned `Keep` becomes — this asserts the decision,
/// and `serve` is left with one line of consequence.
async test "quit is the answer to the loop, and it stops every session" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  let mut keep = Going
  ignore(@async.with_task_group(group => keep = shell.handle(group, "quit")))
  assert_eq(keep, Quit)
  assert_true(open.aborting.val)
  // Nothing said: quitting is not a fact about a conversation.
  inspect(seen().length(), content="0")
}

///|
/// A model this build does not know is **refused**, and the refusal names what there was to pick.
///
/// The reason it is a branch at all is priced: an unknown id has no pricing and no context window, so
/// accepting one would bill the turn at the default's rates and silently send the wrong prompt. The
/// check is `is_known_model`'s, at the arm — which is exactly the kind of guard that lived only inside
/// a running loop.
async test "an unknown model is refused, and the sentence lists what is available" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  command(shell, "/model deepseek-v9")
  let lines = seen()
  inspect(lines.length(), content="1")
  match lines[0] {
    Object(fields) =>
      match fields.get("text") {
        Some(text) =>
          assert_true(
            text.stringify().contains("unknown model deepseek-v9"),
            msg="the refusal did not name the model that was asked for",
          )
        None => fail("the refusal carries no text")
      }
    _ => fail("the refusal is not an object")
  }
  // The session is left alone: a refused switch must not half-happen.
  inspect(open.model_id, content="deepseek-v4-flash")
}

///|
/// A model this build knows is switched, and **four** facts follow it.
///
/// The count is the rule, not padding. Each of the four is a control the host has already drawn from
/// the old model: the status line names it, the picker ticks it, the composer's picture warning was
/// judged against it, and the thinking menu lists *its* levels — so a tick left from the old model is
/// a level the new one does not have. Sending three of the four is how the window comes to describe a
/// model the session is not on.
async test "switching to a known model says four things, and the last is the level" {
  let (shell, seen) = test_shell()
  let open = shell.shown()
  command(shell, "/model deepseek-v4-pro")
  let lines = seen()
  inspect(lines.length(), content="4")
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
  assert_eq(kinds, ["status", "models", "images", "think"])
  // The session moved, and its level was settled against the new model in the same step.
  inspect(open.model_id, content="deepseek-v4-pro")
  inspect(open.think_level, content="high")
}

///|
/// `/think` with a level this model has not got answers **twice**, and the first one says no.
///
/// The refusal and the menu are two events because they are two facts: what was asked for is not
/// happening, and here is the level that is. The second is what keeps the tick from being left on the
/// level the reader typed.
async test "an unknown level is refused in words, then the menu is re-said" {
  let (shell, seen) = test_shell()
  command(shell, "/think bogus")
  let lines = seen()
  inspect(lines.length(), content="2")
  match lines[0] {
    Object(fields) =>
      match fields.get("text") {
        Some(text) =>
          assert_true(
            text.stringify().contains("has no bogus level"),
            msg="the refusal did not name the level that was asked for",
          )
        None => fail("the refusal carries no text")
      }
    _ => fail("the refusal is not an object")
  }
  match lines[1] {
    Object(fields) =>
      match fields.get("kind") {
        Some(String(kind)) => inspect(kind, content="think")
        _ => fail("the menu has no kind")
      }
    _ => fail("the menu is not an object")
  }
}

///|
/// Continuing a turn that is not open is **said**, not silently ignored.
///
/// The host offers this from a notice built on its own copy of the session, which can be out of date —
/// and an error that leaves what it is about on the screen reads as a click that did nothing. So the
/// sentence goes out with the refreshed snapshot: the stale notice cannot outlive the click.
async test "continuing nothing says so, and re-sends the snapshot with it" {
  let (shell, seen) = test_shell()
  command(shell, "continue")
  let lines = seen()
  inspect(lines.length(), content="2")
  match lines[0] {
    Object(fields) =>
      match fields.get("text") {
        Some(text) =>
          inspect(
            text.stringify(),
            content="\"nothing to continue: that turn has already ended\"",
          )
        None => fail("the error carries no text")
      }
    _ => fail("the error is not an object")
  }
  match lines[1] {
    Object(fields) =>
      match fields.get("kind") {
        Some(String(kind)) => inspect(kind, content="session")
        _ => fail("the snapshot has no kind")
      }
    _ => fail("the snapshot is not an object")
  }
}

///|
/// A busy session refuses `continue`, and refuses it **before** anything else happens.
///
/// This is the `handle` half of the `gate` test: the gate's *value* is asserted next to `gate`, and
/// what is asserted here is that the loop obeys it — a refused command leaves no trace but the
/// sentence, which is why the order (gate first, command second) is the rule rather than a style.
async test "a refused command leaves only the sentence saying why" {
  let (shell, seen) = test_shell(busy=true)
  command(shell, "continue")
  let lines = seen()
  inspect(lines.length(), content="1")
  inspect(
    lines[0].stringify(),
    content="{\"kind\":\"error\",\"session\":\"\",\"text\":\"a turn is running here — stop it first\"}",
  )
}

///|
/// The drift log is written when asked for, and says whether a turn's first request was a rewrite.
///
/// This is the whole point of carrying a request across the turn boundary: the seam between two turns
/// is where the trim boundary most often moves — the turn just appended the messages that released it
/// — so the first request of a turn is the one most likely to have rewritten the conversation, and it
/// used to be the one request per turn nothing compared. The log is the only place outside a test
/// that figure is visible, so what it records is what this checks.
///
/// Silent by default: a turn that wrote this unasked would be a file beside the app filling up with
/// ordinary turns. `debug_log` empty is the ordinary case and the first assertion.
async test "the drift log says what a turn's first request cost, when asked" {
  let path = "_build/app_test/drift-\{@core.new_entry_id()}.jsonl"
  @platform.make_dirs("_build/app_test")
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
  let shell = Shell::of(
    {
      home: "/tmp",
      settings: @core.decode_app_settings(""),
      root: "/tmp/sessions",
      start: "/tmp",
      base_url: "https://api.deepseek.com",
      jobs: @core.JobStore::new(),
      pins: [],
      session,
      path: "/tmp/s.jsonl",
      debug_log: path,
    },
    out=_json => (),
  )
  // A turn whose first request was measured against the previous turn's, and which rewrote 4,000
  // bytes of it — the shape a moved trim boundary has.
  let across : @core.RequestDrift = {
    messages: 40,
    bytes: 90_000,
    first_changed: 30,
    previous_messages: 39,
    changed_bytes: 4_000,
    within_turn: false,
    comparable: true,
  }
  let own : @core.RequestDrift = {
    messages: 42,
    bytes: 92_000,
    first_changed: 40,
    previous_messages: 40,
    changed_bytes: 2_000,
    within_turn: true,
    comparable: true,
  }
  let finished : @agent.TurnResult = {
    session,
    replies: [],
    model_calls: 2,
    tool_calls: 1,
    compactions: 0,
    usage: @core.Usage::zero(),
    settled: true,
    cost_limit_hit: false,
    time_limit_hit: false,
    truncated: false,
    request_drift: [across, own],
    last_request: [],
  }
  shell.log_drift("/tmp/s.jsonl", finished)
  let text = @platform.read_text(path)
  assert_true(text.has_suffix("\n"), msg="one JSON object per line")
  // The fields a reader of the log needs: which session, how many requests were comparable, the
  // worst rewrite of the turn, and the first request's own reading including its provenance.
  assert_true(text.contains("\"session\":\"/tmp/s.jsonl\""), msg=text)
  assert_true(text.contains("\"comparable\":2"), msg=text)
  assert_true(text.contains("\"worst_changed_bytes\":4000"), msg=text)
  assert_true(text.contains("\"within_turn\":false"), msg=text)
  assert_true(text.contains("\"changed_bytes\":4000"), msg=text)
  @platform.delete_file(path)
}

///|
/// A shell that was not asked for the log writes nothing, which is what keeps it off in the app.
async test "no debug log means no file" {
  let path = "_build/app_test/should-not-exist-\{@core.new_entry_id()}.jsonl"
  let (shell, _seen) = test_shell()
  let finished : @agent.TurnResult = {
    session: shell.shown().session,
    replies: [],
    model_calls: 1,
    tool_calls: 0,
    compactions: 0,
    usage: @core.Usage::zero(),
    settled: true,
    cost_limit_hit: false,
    time_limit_hit: false,
    truncated: false,
    request_drift: [],
    last_request: [],
  }
  shell.log_drift(path, finished)
  assert_false(@platform.path_exists(path))
}

// ── the refusal sentences ────────────────────────────────────────────────────
//
// Twenty-odd sentences in this package tell a reader why a command did not happen. They are the
// whole of what a failed command gives back — no error code, no state to inspect, just a line of
// prose — and until this section, almost none of them had a test. ADR-0003 names this exact failure
// mode and fixed it on the web side; it had quietly grown back on this one.
//
// They are pure once the facts are handed in, which is the only reason they can be checked at all.

///|
/// Every way a deletion can be refused, and the sentence for each.
///
/// One literal per sentence, deliberately unparameterised: what is being pinned is the *wording*, and
/// a test that built the string from the same constant the code uses would pass while the sentence a
/// reader sees drifted.
test "a deletion is refused in words, one sentence per reason" {
  let ok : Deletion = {
    path: "/store/s.jsonl",
    busy: false,
    live_jobs: 0,
    exists: true,
  }
  inspect(refuse_deletion(ok) is None, content="true")

  let no_path : Deletion = { ..ok, path: "", }
  inspect(refuse_deletion(no_path), content="Some(delete: no session path)")

  let running : Deletion = { ..ok, busy: true, }
  inspect(
    refuse_deletion(running),
    content="Some(cannot delete a session with a turn running — stop it first)",
  )

  let working : Deletion = { ..ok, live_jobs: 1, }
  inspect(
    refuse_deletion(working),
    content="Some(cannot delete a session with a background job still running)",
  )

  let gone : Deletion = { ..ok, exists: false, }
  inspect(refuse_deletion(gone), content="Some(that session is already gone)")
}

///|
/// The order of the four checks is load-bearing, and the case that shows it is a job whose file is
/// gone.
///
/// `npm run dev &` outlives the session that started it. If `exists` were asked first, that session
/// would be refused as "already gone" — a true sentence that sends the reader looking for a file,
/// while the process it should have been told about keeps running with no row on screen pointing at
/// it. `live_jobs` therefore comes first, and this is the only input that can tell the two orders
/// apart.
test "a job that outlived its file is refused for the job, not for the file" {
  let orphan : Deletion = {
    path: "/store/s.jsonl",
    busy: false,
    live_jobs: 2,
    exists: false,
  }
  inspect(
    refuse_deletion(orphan),
    content="Some(cannot delete a session with a background job still running)",
  )
  // And a turn beats a job, for the same shape of reason: stopping the turn is what the reader has to
  // do first, and the job is reachable afterwards.
  let both : Deletion = { ..orphan, busy: true, }
  inspect(
    refuse_deletion(both),
    content="Some(cannot delete a session with a turn running — stop it first)",
  )
  // Nothing named at all beats everything: there is nothing to have a turn or a job.
  let nothing : Deletion = { ..both, path: "", }
  inspect(refuse_deletion(nothing), content="Some(delete: no session path)")
}

///|
/// **No silent refusal.** Every combination of the four facts either allows the deletion or explains
/// itself — there is no input for which the command would do nothing and say nothing, which is the
/// failure a reader experiences as "the button is broken".
test "every refusal names a reason, and every allow is silent" {
  for path in ["", "/store/one.jsonl"] {
    for busy in [false, true] {
      for live_jobs in [0, 1] {
        for exists in [false, true] {
          let d : Deletion = { path, busy, live_jobs, exists, }
          match refuse_deletion(d) {
            Some(reason) =>
              assert_true(reason.length() > 0, msg="a refusal with no words")
            None =>
              // Allowed means all four facts were fine — and the empty path is the one that never is.
              assert_true(path != "" && !busy && live_jobs == 0 && exists)
          }
        }
      }
    }
  }
}

///|
/// Removing a project is refused in words, the same way a deletion is.
///
/// The two sentences here are the ones a reader sees when a project-row delete does not go through, and
/// like `refuse_deletion`'s four they lived inside a method that answered the question and wrote the
/// sentence in the same call — so neither could be asserted.
test "a project removal is refused in words, turn before job" {
  let idle : Array[ProjectLoad] = [{ busy: false, live_jobs: 0, }]
  inspect(refuse_project_removal("/tmp", idle) is None, content="true")
  // A project nobody has open at all is also removable: the loads list is empty, not "unknown".
  inspect(refuse_project_removal("/tmp", []) is None, content="true")

  inspect(
    refuse_project_removal("", idle),
    content="Some(remove: no project path)",
  )
  inspect(
    refuse_project_removal("/tmp", [{ busy: true, live_jobs: 0, }]),
    content="Some(a turn is running in this project — stop it first)",
  )
  inspect(
    refuse_project_removal("/tmp", [{ busy: false, live_jobs: 3, }]),
    content="Some(a background job is still running in this project)",
  )
  // **A turn is asked for before a job**, and the input that tells the two apart is a session with
  // both: stopping the turn is what the reader does next, and the job is reachable afterwards.
  inspect(
    refuse_project_removal("/tmp", [{ busy: true, live_jobs: 3, }]),
    content="Some(a turn is running in this project — stop it first)",
  )
  // One busy session anywhere in the project is enough — the row stands for all of them.
  inspect(
    refuse_project_removal("/tmp", [
      { busy: false, live_jobs: 0, },
      { busy: true, live_jobs: 0, },
      { busy: false, live_jobs: 0, },
    ]),
    content="Some(a turn is running in this project — stop it first)",
  )
  // And a job in any of them, likewise.
  inspect(
    refuse_project_removal("/tmp", [
      { busy: false, live_jobs: 0, },
      { busy: false, live_jobs: 1, },
    ]),
    content="Some(a background job is still running in this project)",
  )
}

///|
/// The same no-silent-refusal property as a deletion: every combination either allows it or explains.
test "every project refusal names a reason" {
  let named = ["", "/tmp"]
  let loads : Array[Array[ProjectLoad]] = [
    [],
    [{ busy: false, live_jobs: 0, }],
    [{ busy: true, live_jobs: 0, }],
    [{ busy: false, live_jobs: 2, }],
    [{ busy: true, live_jobs: 2, }],
  ]
  for path in named {
    for load in loads {
      match refuse_project_removal(path, load) {
        Some(reason) =>
          assert_true(reason.length() > 0, msg="a refusal with no words")
        None =>
          assert_true(
            path != "" && load.all(fn(l) { !l.busy && l.live_jobs == 0 }),
            msg="allowed with a turn or a job in it",
          )
      }
    }
  }
}

// ── the fork, and the file it produces ───────────────────────────────────────
//
// `fork` is the first operation in this program that *produces* a session file rather than extending
// one, which makes it the first that can leave a file looking complete and holding half a
// conversation. ADR-0010 wrote eleven acceptance criteria around it; these are the ones that are about
// the shell — the rest are `core`'s, and live in `core/session_fork_test.mbt`.

///|
/// A store directory of this test's own, so a fork can be looked for on disk afterwards.
async fn fork_root() -> String {
  let root = "_build/app_test/fork-\{@core.new_entry_id()}"
  @platform.make_dirs(root)
  root
}

///|
/// One session file with one question in it, and the session read back from it.
///
/// Written and re-read rather than built in memory, because what a fork copies is the parent's *label*
/// as well as its entries — and the label comes from the file (`label_of` → `Labels::facts`). A parent
/// built in memory would label as `New Session`, which is the one case that tells nothing about whether
/// the name was computed at all.
async fn parent_on_disk(root : String, question : String) -> @core.Session {
  let path = "\{root}/parent.jsonl"
  let header =
    #|{"type":"session","version":3,"id":"p1","timestamp":"2026-08-23T06:26:15.210Z","cwd":"/tmp"}
  inspect(
    @platform.write_session(path, header + "\n" + user_line("m1", question)),
    content="true",
  )
  @platform.load_session(path)
}

///|
/// A fork that cannot happen writes **nothing**, and says so.
///
/// A session nobody has asked anything in has nothing to fork: the copy would be an empty session with a
/// parent recorded, which is a row the reader has to delete. Refused rather than allowed quietly,
/// because a fork that produced an indistinguishable new session is a click that did not work.
async test "forking a session with nothing in it is refused, and writes nothing" {
  let root = fork_root()
  let empty = @core.Session::new(
    {
      id: "e",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [],
  )
  let seen : Array[Json] = []
  let shell = shell_in(root, "\{root}/parent.jsonl", empty, json => {
    seen.push(json)
  })
  shell.fork()
  inspect(kinds_of(seen), content="[error]")
  inspect(
    text_field(seen[0], "text"),
    content="nothing to fork: this session has no messages yet",
  )
  // **And nothing was produced.** Not a file, not a row: the refusal is the whole of what happened.
  inspect(@platform.list_sessions(root).length(), content="0")
}

///|
/// A fork copies the parent's history into a file of its own, and tells the host **afterwards**.
///
/// The order is the whole of the first half of ADR-0010's criterion 11 — "先写完再报" — and it is proved
/// by the test below rather than here: a write that fails leaves nothing told, which is only possible if
/// the write came first. What this asserts is that the file exists, that it says where it came from, and
/// that the host was told about the session that was actually written.
async test "a fork's file says where it came from, and names itself after the parent" {
  let root = fork_root()
  let parent_path = "\{root}/parent.jsonl"
  let parent = parent_on_disk(root, "refactor the parser")
  let seen : Array[Json] = []
  let shell = shell_in(root, parent_path, parent, json => seen.push(json))
  shell.fork()
  let lines = seen
  // What the host is told, in order: the new session's rows, then the snapshots that belong to it, then
  // the sentence about the fork, then the list. `history` first is the load-bearing one (the host swaps
  // transcript on the `session` event, and swapping before the rows arrive is a blank column).
  inspect(
    kinds_of(lines),
    content="[history, session, usage, models, think, images, status, sessions]",
  )
  // The session the host was told about is the one on disk, and `history` carries the routing it needs
  // to file those rows under it.
  let child = text_field(lines[0], "session")
  assert_true(child != parent_path, msg="the fork is the parent's path")
  assert_true(@platform.path_exists(child))
  let loaded = @platform.load_session(child)
  assert_eq(loaded.header.parent_session, Some(parent_path))
  // The parent's entries come first, **ids included**, because an entry is referred to by its id (a
  // child's `parent_id`, a tool result's `call_id`) and renumbering would break the chain and the tool
  // results at once. Then the two a fork adds, at the end: the marker that records where this came from
  // and where its own spending starts, and the name.
  assert_eq(loaded.entries.length(), parent.entries.length() + 2)
  for index in 0..<parent.entries.length() {
    assert_eq(loaded.entries[index].id, parent.entries[index].id)
  }
  // ADR-0010's criterion 4, end to end: the parent's *displayed* name is its first question, and the
  // child's is that with the literal prefix — the two rows have to be told apart in the list.
  assert_true(@platform.read_text(child).contains("(fork) refactor the parser"))
  // And the sentence says the one thing the label cannot: the two are now independent.
  inspect(
    text_field_contains(
      lines[6],
      "text",
      "forked from “refactor the parser” · independent from here",
    ),
    content="true",
  )
}

///|
/// **A fork whose file cannot be written says so, and switches nothing.**
///
/// This is the test that pins ADR-0010's criterion 11 — "*写不进去*: `say_error` + 不切走 + 不留半截行" —
/// and it was not possible before this change. `@platform.write_session` returned `Unit`, so a failed
/// write raised out of `fork`: no sentence for the reader, and a raise that would have taken the command
/// loop's task with it.
///
/// It also proves the *order*: exactly one event came out, and it is the error. Had anything been told to
/// the host before the write, there would be an `open` or a `sessions` in this list — and a list showing
/// a fork that is not on disk is the half-row this criterion exists to forbid.
async test "a fork that cannot be written says so, and leaves nothing half-done" {
  // A store that cannot be written: its parent path is a *file*, so no directory can be created under it.
  @platform.make_dirs("_build/app_test")
  let blocker = "_build/app_test/fork-blocked-\{@core.new_entry_id()}"
  @platform.write_text(blocker, "not a directory")
  let root = "\{blocker}/sessions"
  let parent = @core.Session::new(
    {
      id: "p",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    [
      @core.Entry::{
        id: "u1",
        parent_id: None,
        timestamp: @core.format_iso_utc(0L),
        kind: @core.Message(
          message=@core.Message::User({
            content: [@core.Text("hello")],
            timestamp: 0L,
          }),
        ),
      },
    ],
  )
  let seen : Array[Json] = []
  let shell = shell_in(root, "\{root}/parent.jsonl", parent, json => {
    seen.push(json)
  })
  shell.fork()
  let lines = seen
  // One event, and it is the sentence. No `open`, no `sessions`, nothing about a session that does not
  // exist.
  inspect(kinds_of(lines), content="[error]")
  assert_true(
    text_field(lines[0], "text").contains("could not write the fork"),
    msg="the failure did not say what could not be written",
  )
  // **And the window did not move.** A fork that failed must leave the reader where they were.
  inspect(shell.current, content="\{root}/parent.jsonl")
}
