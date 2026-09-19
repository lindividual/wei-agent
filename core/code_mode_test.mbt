///|
/// Code mode: the two tools, the prompt that describes them, and the answers `wait` gives.
///
/// The point of most of these is that the mode is a *pair* of decisions — which tools are declared
/// and what the prompt says about them — and that the pair cannot be changed one at a time.

///|
test "a mode names its tools, and code mode has exactly two" {
  let code = tools_for_mode(ToolMode::Code)
  assert_eq(code.length(), 2)
  assert_eq(code[0].name, "exec")
  assert_eq(code[1].name, "wait")
  // Everything code mode does goes through `exec`, so it has to be declared exclusive: two of them
  // in flight would interleave their writes into one workspace.
  assert_true(code[0].concurrency is Concurrency::Exclusive)
  assert_true(code[1].concurrency is Concurrency::Exclusive)
  // The eight, by name, so a tool added to `builtin_tools` cannot quietly arrive in code mode.
  let names : Array[String] = []
  for tool in tools_for_mode(ToolMode::Tools) {
    names.push(tool.name)
  }
  assert_eq(names, [
    "bash", "read", "write", "edit", "glob", "grep", "note", "script",
  ])
  // And code mode is not a subset of it: the names are different ones.
  assert_false(names.contains("exec"))
}

///|
test "a mode is parsed forgivingly from a file and strictly from a flag" {
  // The saved setting: an unknown word costs the reader a mode, not the server.
  assert_true(parse_tool_mode("code") is ToolMode::Code)
  assert_true(parse_tool_mode(" code\n") is ToolMode::Code)
  assert_true(parse_tool_mode("code-mode") is ToolMode::Code)
  assert_true(parse_tool_mode("tools") is ToolMode::Tools)
  assert_true(parse_tool_mode("") is ToolMode::Tools)
  assert_true(parse_tool_mode("cod") is ToolMode::Tools)
  assert_eq(ToolMode::Tools.to_string(), "tools")
  assert_eq(ToolMode::Code.to_string(), "code")
  // Every mode's name parses back to itself, which is what makes the name storable.
  for mode in [ToolMode::Tools, ToolMode::Code] {
    assert_eq(parse_tool_mode(mode.to_string()), mode)
  }
}

///|
test "the prompt follows the mode, and stops naming tools that are gone" {
  let code = build_system_prompt(
    "/work",
    tools_for_mode(ToolMode::Code),
    mode=ToolMode::Code,
  )
  // The tool list is generated from the declarations, so both modes list exactly what they send.
  assert_true(code.contains("- exec:"), msg=code)
  assert_true(code.contains("- wait:"), msg=code)
  assert_false(code.contains("- read:"), msg=code)
  // The instructions have to change with it. The tools-mode text says "for a single file, `read`
  // is cheaper"; that sentence in code mode is advice about a tool that is not in the request.
  assert_false(code.contains("For a single file, `read` is cheaper"), msg=code)
  assert_true(code.contains("reading is `cat`"), msg=code)
  let tools = build_system_prompt("/work", tools_for_mode(ToolMode::Tools))
  assert_true(tools.contains("- read:"), msg=tools)
  assert_true(tools.contains("For a single file, `read` is cheaper"), msg=tools)
  assert_false(tools.contains("reading is `cat`"), msg=tools)
}

///|
/// The `exec` description is where the model learns what code mode costs it.
///
/// It is the only place: there is no file tool to discover the absence of. So the things a model
/// gets wrong without being told — that only stdout reaches it, that the cap keeps the end, that a
/// `cd` does not carry, that an interactive command hangs the turn — are asserted here.
test "the exec description says how a call is used, not just what it does" {
  let description = exec_tool().description
  for
    phrase in [
      "bash", "moonbit", "@builtin/check", "async fn main", "Only what the command prints",
      "2000 lines or 50KB", "keeps the end", "starts fresh in the working directory",
      "waits for input waits forever", "`wait` on that id",
    ] {
    assert_true(description.contains(phrase), msg="missing: \{phrase}")
  }
  // The examples in the shared program help are the ones a model copies, so they have to be real
  // programs: a `main`, and a call to the prelude.
  assert_true(description.contains("write(path, edit_text(read(path),"))
}

///|
/// Every parameter of `exec` is described, and the one-of rule is in the text.
///
/// A schema cannot say "exactly one of these" in the subset this project validates, so the rule
/// lives in the description and is enforced when the call runs. A model that reads only the schema
/// would have no way to know.
test "exec has two dialects and says they are exclusive" {
  let parameters = exec_tool().parameters
  assert_eq(schema_property_names(parameters), [
    "args", "bash", "label", "moonbit",
  ])
  // Neither is required: `exec` with neither is a readable refusal, and requiring one in the schema
  // would let the provider reject the call before the model could be told which mistake it made.
  assert_eq(required_names(parameters), [])
  let description = exec_tool().description
  assert_true(
    description.contains("Exactly one of `bash` and `moonbit` per call"),
  )
}

///|
test "wait has a bound, and says so" {
  assert_true(default_wait_seconds() > 0)
  assert_eq(wait_tool().parameters.stringify().contains("\"timeout\""), true)
  assert_eq(required_names(wait_tool().parameters), ["id"])
}

// ── what wait says ─────────────────────────────────────────────────────────

///|
fn job(status : JobStatus, detail? : String = "") -> Job {
  {
    id: "exec-3",
    kind: "exec",
    label: "npm run dev",
    session: "/sessions/x.jsonl",
    status,
    started_at: 0L,
    finished_at: None,
    detail,
    pids: [1234],
    tail: "",
    output: None,
    call_open: false,
  }
}

///|
test "a finished job leads with its status, then its output" {
  let text = format_wait_result(
    job(JobStatus::Completed, detail="exited on its own"),
    "listening on 3000\n",
    "",
    false,
    2500L,
  )
  assert_false(text.is_error)
  let body = match text.content {
    [Text(body)] => body
    _ => ""
  }
  assert_true(body.has_prefix("exec-3 finished after 2.5s"), msg=body)
  assert_true(body.contains("listening on 3000"), msg=body)
}

///|
test "a job that failed is an error the model can act on" {
  let failed = format_wait_result(
    job(JobStatus::Failed, detail="exited 1"),
    "boom",
    "",
    false,
    1000L,
  )
  assert_true(failed.is_error)
  // A killed job too: both are states the caller has to look at rather than read past.
  assert_true(
    format_wait_result(job(JobStatus::Killed), "", "", false, 1000L).is_error,
  )
  // A job that is merely still running is not an error: there is nothing wrong with it.
  assert_false(
    format_wait_result(job(JobStatus::Running), "", "", false, 1000L).is_error,
  )
}

///|
test "stderr is labelled, and silence is said rather than left blank" {
  let text = format_wait_result(
    job(JobStatus::Completed),
    "",
    "warning",
    false,
    100L,
  )
  let body = match text.content {
    [Text(body)] => body
    _ => ""
  }
  assert_true(body.contains("stderr:\nwarning"), msg=body)
  let silent = format_wait_result(
    job(JobStatus::Completed),
    "",
    "",
    false,
    100L,
  )
  assert_true(
    match silent.content {
      [Text(body)] => body.contains("(no output)")
      _ => false
    },
  )
}

///|
/// The two things a caller has to be able to tell apart: more output is waiting, and nothing more
/// is coming. The marker has to say what to do about it as well as that it happened.
test "truncation says there is more, and how to get it" {
  let text = format_wait_result(
    job(JobStatus::Completed),
    "…",
    "",
    true,
    100L,
  )
  let body = match text.content {
    [Text(body)] => body
    _ => ""
  }
  assert_true(body.contains("call wait again"), msg=body)
  assert_true(body.contains("32KB"), msg=body)
}

///|
test "a wait that timed out says the job is fine, not that it failed" {
  let message = format_wait_pending(job(JobStatus::Running), 120000L)
  assert_true(
    message.contains("exec-3 is still running after 120s"),
    msg=message,
  )
  assert_true(message.contains("pid 1234"), msg=message)
  assert_true(message.contains("Call wait again"), msg=message)
  assert_true(message.contains("sidebar"), msg=message)
}

///|
test "an unknown id lists the ids that would work" {
  let known = [
    job(JobStatus::Running),
    { ..job(JobStatus::Completed), id: "exec-1", pids: [9], },
  ]
  let message = format_wait_unknown("exec-9", known)
  assert_true(message.contains("No job \"exec-9\""), msg=message)
  // Only the live ones, because only those can be waited on.
  assert_true(message.contains("Running: exec-3."), msg=message)
  assert_false(message.contains("exec-1,"), msg=message)
  assert_true(message.contains("cannot be waited on"), msg=message)
  // With nothing live there is no list to give, and the sentence has to survive that.
  let none = format_wait_unknown("bash-2", [])
  assert_true(none.contains("No job is running"), msg=none)
}

///|
fn schema_property_names(schema : Json) -> Array[String] {
  let out : Array[String] = []
  match schema {
    Object(fields) =>
      match fields.get("properties") {
        Some(Object(properties)) =>
          for key, _ in properties {
            out.push(key)
          }
        _ => ()
      }
    _ => ()
  }
  out.sort()
  out
}

///|
fn required_names(schema : Json) -> Array[String] {
  match schema {
    Object(fields) =>
      match fields.get("required") {
        Some(Array(items)) => {
          let out : Array[String] = []
          for item in items {
            match item {
              String(name) => out.push(name)
              _ => ()
            }
          }
          out
        }
        _ => []
      }
    _ => []
  }
}

///|
/// Which calls get a background record, and which do not.
///
/// The two callers of the dialect rule are the tool that runs the call and the driver that decides
/// whether a record is needed, and a disagreement between them is a job row for a program that
/// finished, or a backgrounded command that nothing can wait on.
test "only a command can leave a process behind" {
  assert_true(leaves_a_process("bash", @json.parse("{\"command\":\"ls\"}")))
  assert_true(
    leaves_a_process("exec", @json.parse("{\"bash\":\"npm run dev &\"}")),
  )
  // A program is compiled and run inside the call, so it is never in the process table afterwards.
  assert_false(
    leaves_a_process("exec", @json.parse("{\"moonbit\":\"async fn main {}\"}")),
  )
  assert_false(
    leaves_a_process("exec", @json.parse("{\"moonbit\":\"@builtin/check\"}")),
  )
  // A call that is refused runs nothing, so a record for it would be noise. The refusal itself is
  // covered by the platform test, which is where the two messages live.
  assert_false(
    leaves_a_process(
      "exec",
      @json.parse("{\"bash\":\"ls\",\"moonbit\":\"async fn main {}\"}"),
    ),
  )
  assert_false(leaves_a_process("exec", @json.parse("{}")))
  assert_false(leaves_a_process("read", @json.parse("{}")))
  assert_false(leaves_a_process("script", @json.parse("{\"source\":\"x\"}")))
  // A field holding only whitespace was not filled: a model that emits an empty `bash` alongside a
  // program means the program.
  assert_eq(
    exec_dialect(
      @json.parse("{\"bash\":\"  \\n\",\"moonbit\":\"async fn main {}\"}"),
    ),
    ExecDialect::Program(text="async fn main {}"),
  )
  // And the dialect is normalized on the way out, so the command that runs is the one meant.
  assert_eq(
    exec_dialect(@json.parse("{\"bash\":\"  ls -la  \"}")),
    ExecDialect::Command(text="ls -la"),
  )
}

///|
test "output on both streams is labelled and separated, and a detail is reported" {
  let both = format_wait_result(
    job(JobStatus::Completed),
    "out",
    "err",
    false,
    100L,
  )
  let body = match both.content {
    [Text(body)] => body
    _ => ""
  }
  assert_true(body.contains("out\nstderr:\nerr"), msg=body)
  // A job that ended for a reason other than exiting on its own says so where the output would be:
  // an empty answer and an answer with no output are different things, and only the detail
  // distinguishes them.
  let failed = format_wait_result(
    job(JobStatus::Failed, detail="exited 137"),
    "",
    "",
    false,
    100L,
  )
  let text = match failed.content {
    [Text(text)] => text
    _ => ""
  }
  assert_true(text.contains("(no output; exited 137)"), msg=text)
}

///|
/// A bundled script is named with or without the prefix, and a program is anything else.
///
/// The field is one string, so this is the decision that says which of the two it is. Getting it
/// wrong on the forgiving side costs a compile of a name; getting it wrong the other way costs a
/// syntax error where the list of scripts was wanted.
test "a program field is read as a bundle or as source" {
  assert_true(program_is_bundled("@builtin/check"))
  // Unknown, and still a name: the runner is what knows which ones exist, and it answers with them.
  assert_true(program_is_bundled("@builtin/nope"))
  // The bare spelling of a bundled script, which is what the `script` tool also accepts.
  assert_true(program_is_bundled("check"))
  assert_true(program_is_bundled("read"))
  // Everything else is source, including a single word that is not a script.
  assert_false(program_is_bundled("nope"))
  assert_false(program_is_bundled(""))
  assert_false(program_is_bundled("async fn main {\n  println(\"hi\")\n}"))
  assert_false(program_is_bundled("async fn main { println(\"check\") }"))
}

///|
/// Every ending has its own sentence, and a job being stopped is not the same as one that failed.
///
/// The list is exhaustive on purpose: the headline is what the model reads first, and a `Stopping`
/// job reported as "failed" would send it looking for a bug in a command that is doing exactly what
/// it was told. The unknown status is impossible today and would be reported as such rather than
/// silently matching something.
test "a job's ending is named, each one its own" {
  for
    status in [
      JobStatus::Completed,
      JobStatus::Failed,
      JobStatus::Killed,
      JobStatus::Stopping,
      JobStatus::Running,
    ] {
    let text = match
      format_wait_result(job(status), "", "", false, 100L).content {
      [Text(text)] => text
      _ => ""
    }
    assert_true(text.has_prefix("exec-3 "), msg=text)
    assert_true(text.contains("after 100ms"), msg=text)
  }
  let stopping = match
    format_wait_result(job(JobStatus::Stopping), "", "", false, 100L).content {
    [Text(text)] => text
    _ => ""
  }
  assert_true(stopping.contains("is stopping"), msg=stopping)
}

// ── the tool set this turn was given ───────────────────────────────────────

///|
/// A conversation whose earlier calls are the ones worth warning about.
///
/// Built from the same shape the model sees, because that is what the notice is derived from: a
/// message the model cannot see — a call behind a compaction — must not be able to make a turn warn
/// about a tool that is no longer anywhere in the conversation.
fn conversation_with_calls(names : Array[String]) -> SessionContext {
  let blocks : Array[Content] = []
  for name in names {
    blocks.push(
      ToolCall(id="c-\{name}", name~, arguments=Json::object(Map([]))),
    )
  }
  {
    messages: [
      ContextMessage::Assistant({
        content: blocks,
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: Usage::zero(),
        stop_reason: ToolUse,
        timestamp: 0L,
        response_id: (None : String?),
        response_model: (None : String?),
        raw_stop_reason: (None : String?),
        error_message: (None : String?),
      }),
    ],
    thinking_level: Some("high"),
    model: None,
  }
}

///|
test "a call to a tool this turn does not have is refused, and says what there is" {
  let code = tools_for_mode(ToolMode::Code)
  let text = undeclared_tool_message("bash", code)
  // The refusal has to start by saying nothing ran: a model that reads it as "this partially
  // happened" will build on work that does not exist.
  assert_true(
    text.has_prefix(
      "Refused: this turn has no tool named `bash`, so nothing ran.",
    ),
    msg=text,
  )
  assert_true(text.contains("`exec`, `wait`"), msg=text)
  // And then the way to do it, because the mistake is nearly always the other mode's spelling.
  assert_true(text.contains("`exec`'s `bash` field"), msg=text)
  // The rest of the mapping, which is the part a model cannot derive: `read` has one replacement
  // per use, not one replacement.
  for
    pair in [
      ("script", "`moonbit` field"),
      ("read", "sed -n '10,40p'"),
      ("grep", "grep -rn"),
      ("glob", "list with `ls`"),
      ("write", "shell redirect"),
      ("edit", "edit_text"),
    ] {
    let (name, phrase) = pair
    let hint = undeclared_tool_message(name, code)
    assert_true(hint.contains(phrase), msg="\{name}: \{hint}")
  }
  // `note` has no replacement in code mode, and the refusal says that rather than inventing one.
  assert_true(
    undeclared_tool_message("note", code).contains("no way to record a note"),
  )
  // A tool set with neither dialect — nothing here has a mapping for it — says what there is and
  // stops, rather than guessing at advice for a mode it does not know.
  let bare = undeclared_tool_message("bash", [])
  assert_true(bare.contains("so nothing ran"), msg=bare)
  assert_false(bare.contains("field"), msg=bare)
  // A name that is nobody's spelling still gets the list, and no invented advice.
  let invented = undeclared_tool_message("frobnicate", code)
  assert_true(invented.contains("`exec`, `wait`"), msg=invented)
  assert_false(invented.contains("A shell command goes"), msg=invented)
}

///|
/// The reverse direction: a turn in tools mode is told what became of code mode's two.
///
/// `wait` is the interesting one, because there is no replacement for it — a tools-mode turn has no
/// record of what a backgrounded command wrote — and saying so is better than letting the model
/// discover it by calling a tool that is not there.
test "the hints are per mode, and say when there is no replacement" {
  let tools = tools_for_mode(ToolMode::Tools)
  let exec = undeclared_tool_message("exec", tools)
  assert_true(exec.contains("is `bash` here"), msg=exec)
  assert_true(exec.contains("`script`"), msg=exec)
  let wait = undeclared_tool_message("wait", tools)
  assert_true(
    wait.contains("Nothing keeps a backgrounded command's output in this mode"),
    msg=wait,
  )
  assert_true(wait.contains("redirect it to a file"), msg=wait)
  // A name neither mode knows gets the list and nothing else — the fallback that keeps this from
  // inventing advice about a tool that never existed.
  let invented = undeclared_tool_message("frobnicate", tools)
  assert_true(invented.contains("`bash`"), msg=invented)
  assert_false(invented.contains("here"), msg=invented)
}

///|
test "the tools a turn has are looked up by name, and nothing else counts" {
  let code = tools_for_mode(ToolMode::Code)
  assert_true(has_tool(code, "exec"))
  assert_true(has_tool(code, "wait"))
  assert_false(has_tool(code, "bash"))
  assert_false(has_tool(code, "Exec"))
  assert_false(has_tool(code, ""))
  assert_true(tool_named(code, "exec") is Some(_))
  assert_true(tool_named(code, "bash") is None)
}

///|
/// The stale names are the ones the conversation used and this turn cannot: exactly that, no more.
test "a conversation's used tools are read back against this turn's set" {
  let code = tools_for_mode(ToolMode::Code)
  let tools = tools_for_mode(ToolMode::Tools)
  // A session that ran in tools mode, now in code mode.
  let stale = stale_tool_names(
    conversation_with_calls(["bash", "read", "bash", "exec"]),
    code,
  )
  // In the order first used, each once. `exec` is dropped because this turn has it.
  assert_eq(stale, ["bash", "read"])
  // The same conversation in tools mode is stale in the mirror direction, and `read` is not.
  assert_eq(
    stale_tool_names(conversation_with_calls(["exec", "wait"]), tools),
    ["exec", "wait"],
  )
  // A conversation that used only what this turn has produces nothing, which is the ordinary case
  // and the reason the section is empty.
  assert_eq(stale_tool_names(conversation_with_calls(["bash"]), tools), [])
  assert_eq(stale_tool_names(conversation_with_calls([]), code), [])
}

///|
/// The section is empty when nothing has changed, and that is load-bearing.
///
/// The prompt is the cache prefix. A section that said "this turn's tools are …" unconditionally
/// would be correct and would also rewrite the prefix of every session on upgrade, so the test pins
/// the empty case first and the content second.
test "the tool-change section is empty unless the tool set actually changed" {
  let code = tools_for_mode(ToolMode::Code)
  assert_eq(tool_change_prompt([], code), "")
  let section = tool_change_prompt(["bash"], code)
  assert_true(section.has_prefix("## Tools changed"), msg=section)
  assert_true(
    section.contains("Earlier calls in this conversation used `bash`"),
    msg=section,
  )
  assert_true(section.contains("is refused and nothing runs"), msg=section)
  assert_true(section.contains("`exec`, `wait`"), msg=section)
  assert_true(section.contains("`exec`'s `bash` field"), msg=section)
  // Two names read as one sentence rather than two sections.
  let two = tool_change_prompt(["bash", "read"], code)
  assert_true(two.contains("used `bash`, `read`"), msg=two)
}

///|
/// The section rides at the end of the prompt, after the instructions and the catalog.
///
/// It is the one thing in the prompt that becomes true mid-conversation, and a reader comparing the
/// prompt to the request should find the two tool sets named last rather than buried.
test "the change section is the last thing in the prompt" {
  let code = tools_for_mode(ToolMode::Code)
  let prompt = build_system_prompt(
    "/work",
    code,
    mode=ToolMode::Code,
    instructions="## Workspace\n\nSomething.",
    stale_tools=["bash"],
  )
  let at = prompt.find("## Tools changed").unwrap()
  assert_true(prompt.find("## Workspace").unwrap() < at)
  assert_true(prompt.find("- exec:").unwrap() < at)
  assert_eq(prompt[at:].contains("## Workspace"), false)
}

///|
/// `command` names the same dialect as `bash`, and `bash` wins if both are given.
///
/// The acceptance is a correction to the tool rather than a widening of it: the rule the schema
/// states is "name the dialect with the field", and `command` names it unambiguously — it can only
/// be a shell command. The refusals it prevents were a model carrying the tools-mode `bash` tool in
/// its history, which no instruction can make it unlearn.
test "command is another way to say the shell dialect" {
  assert_eq(
    exec_dialect(@json.parse("{\"command\":\"  ls -la  \"}")),
    ExecDialect::Command(text="ls -la"),
  )
  // A call that fills both has misunderstood which field means what; the one the tool is named for
  // is the safer reading, and it is still a command rather than a refusal.
  assert_eq(
    exec_dialect(@json.parse("{\"bash\":\"echo a\",\"command\":\"echo b\"}")),
    ExecDialect::Command(text="echo a"),
  )
  // A program with a stray `command` beside it is still the program: only one of the two fields can
  // be a program, and the pair is not ambiguous the way `bash` and `moonbit` are.
  assert_eq(
    exec_dialect(
      @json.parse("{\"command\":\"\",\"moonbit\":\"async fn main {}\"}"),
    ),
    ExecDialect::Program(text="async fn main {}"),
  )
  // `command` names a command, so a call that uses it can leave a process behind.
  assert_true(
    leaves_a_process("exec", @json.parse("{\"command\":\"sleep 5 &\"}")),
  )
}

///|
/// The keys of a call, for a refusal that can name what the model actually sent.
test "argument keys are listed, sorted, and empty for a call with none" {
  assert_eq(argument_keys(@json.parse("{\"timeout\":5,\"cmd\":\"ls\"}")), [
    "cmd", "timeout",
  ])
  assert_eq(argument_keys(@json.parse("{}")), [])
  assert_eq(argument_keys(Json::string("not an object")), [])
}
