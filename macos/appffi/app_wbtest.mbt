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
