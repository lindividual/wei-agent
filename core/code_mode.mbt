///|
/// Code mode: a turn with two tools instead of eight.
///
/// The usual shape of a coding agent is one verb per tool, chosen by the model and executed by the
/// host. Code mode keeps a single verb — *run something* — and lets the command orchestrate: a
/// shell pipeline is a loop, a pipeline and a filter in one call, and a MoonBit program is the same
/// loop written where it can hand back a digest instead of its raw output.
///
/// What it buys is a different ratio of tokens to work. It is also a real constraint, so it is a
/// mode the reader chooses rather than a replacement: the tools it drops are the only way to read a
/// file, so every read becomes a command, and the model has to know that before it is handed the
/// job. The system prompt says so.
///
/// Two tools, and they are not peers. `exec` runs something and `wait` collects what a thing that
/// outlived its call printed — which is the one piece of the tool set that a shell cannot express,
/// because a backgrounded process in a non-interactive shell has no way to report itself.

///|
/// Which tools a turn is given.
///
/// Read once at the top of a turn and used for both halves of the request — the schema and the
/// prompt that names the tools — because a mode that changed between the two reads would describe a
/// tool the request does not carry. Changing it takes effect on the next turn for the same reason:
/// the tool set is part of the request, and a request already sent is what the model is answering.
pub(all) enum ToolMode {
  /// The eight built-in tools, one verb each.
  Tools
  /// `exec` and `wait`: everything a turn does, it does by running something.
  Code
} derive(Eq, Debug)

///|
pub fn ToolMode::to_string(self : ToolMode) -> String {
  match self {
    Tools => "tools"
    Code => "code"
  }
}

///|
/// Parse the command-line and settings spelling. An unknown word is the default mode rather than
/// an error: a settings file with a typo should cost the reader a mode, not the server.
pub fn parse_tool_mode(text : String) -> ToolMode {
  match text.trim() {
    "code" | "code-mode" => Code
    _ => Tools
  }
}

///|
/// The tools a mode runs with.
///
/// One function rather than an array built at each call site, so the prompt, the schema list sent
/// to the model, and the tool executed cannot disagree about which mode is in force.
pub fn tools_for_mode(mode : ToolMode) -> Array[ToolDef] {
  match mode {
    Tools => builtin_tools()
    Code => [exec_tool(), wait_tool()]
  }
}

// ── exec ───────────────────────────────────────────────────────────────────

///|
/// What an `exec` call asks for.
///
/// Two dialects and two ways of being wrong, decided in one place because two callers need the
/// same answer: the tool that runs the call, and the driver, which has to know whether this call
/// could leave a process behind — which is exactly the calls that run a command. A rule stated in
/// two places is a rule two things can disagree about.
pub(all) enum ExecDialect {
  /// A shell command.
  Command(text~ : String)
  /// A MoonBit program: a bundled script's name, or a program of the caller's own.
  Program(text~ : String)
  /// Both fields were filled. One call runs one thing.
  Both
  /// Neither was.
  Neither
} derive(Eq, Debug)

///|
/// Which dialect a call is in, with surrounding whitespace ignored: a field holding only a newline
/// is a field that was not filled.
pub fn exec_dialect(arguments : Json) -> ExecDialect {
  let command = arg_string(arguments, "bash").unwrap_or("").trim().to_owned()
  let program = arg_string(arguments, "moonbit").unwrap_or("").trim().to_owned()
  match (command != "", program != "") {
    (true, true) => Both
    (false, false) => Neither
    (true, false) => Command(text=command)
    (false, true) => Program(text=program)
  }
}

///|
/// Whether a `moonbit` field names a bundled script rather than holding a program.
///
/// Forgiving about the prefix, because the field is one string rather than the `script` tool's two:
/// `check` and `@builtin/check` both mean that bundle. There is no ambiguity to be careful about —
/// a program has to define `async fn main`, so a single word with no whitespace is never one — and
/// the alternative is compiling `check` as a program, which fails with an unbound-identifier error
/// that is a puzzle rather than a correction.
///
/// An unknown `@builtin/name` is a name as well, so that the runner can answer with the ones that
/// exist. Compiling it as a program would produce a syntax error instead of a list of what it
/// probably meant.
pub fn program_is_bundled(text : String) -> Bool {
  if text.has_prefix("@builtin/") {
    return true
  }
  text != "" &&
  !text.contains(" ") &&
  !text.contains("\n") &&
  builtin_script_source(text) is Some(_)
}

///|
/// Whether a call could leave something running after it returns.
///
/// Only a command can: a program is compiled and run inside the call, and a call that is refused
/// runs nothing at all. The driver asks this so that a job record exists for exactly the calls that
/// might need one — a record for a program that finished would be a lie about the process table,
/// and it would occupy one of the session's ten background slots.
pub fn leaves_a_process(name : String, arguments : Json) -> Bool {
  if name == "bash" {
    true
  } else if name == "exec" {
    exec_dialect(arguments) is Command(_)
  } else {
    false
  }
}

///|
/// The one tool a code-mode turn does its work with.
///
/// Two dialects rather than two tools, because the choice between them is the model's and one call
/// runs exactly one of them — which is why `bash` and `moonbit` are two properties of one schema
/// and not one free-form string. The rule is enforced when the call runs, not here: a refusal the
/// model can read and correct is worth more than a call the provider never accepts.
pub fn exec_tool() -> ToolDef {
  let dialect_bash =
    #|`bash`: a shell command, run with `bash -c` in the working directory. This is the only way
    #|to run a program, a build, a test, or a git command.
  let dialect_moonbit =
    #|`moonbit`: a MoonBit program, compiled and run against the workspace, for a step that would
    #|otherwise be several commands, a loop or an aggregation over files, or a command whose raw
    #|output is much larger than the part you need. The work happens inside the call, so what comes
    #|back is the digest rather than everything the program had to read to produce it.
  let pragmatics =
    #|How to use it:
    #|- Only what the command prints reaches you. Nothing is implicit: reading a file is `cat`, or
    #|  `sed -n '10,40p'` for a slice; searching is `grep -rn`; listing is `ls`.
    #|- The output is capped at the last 2000 lines or 50KB, whichever comes first, and the cap
    #|  keeps the end. If a command could print more than you need, narrow it in the command
    #|  (`| tail -30`, `--stat`) rather than reading the cap and trying again.
    #|- Each call starts fresh in the working directory. `cd` inside one call does not carry into
    #|  the next one; use `cd x && y` in a single command, or pass a path.
    #|- A command that waits for input waits forever, and the turn waits with it. Pass the flags
    #|  that fail instead of prompting (`-y`, `--no-pager`, `-batch`, `</dev/null`), and a timeout
    #|  to anything that might not return on its own.
    #|- `&` leaves the process running after the call returns. The result names the job id, and a
    #|  `wait` on that id collects what it printed.
    #|- Report what you did and what you found. If a command fails, read the error before repeating
    #|  it unchanged.
  {
    name: "exec",
    description: "Execute a bash command or a MoonBit program in the current working directory and " +
    "return what it printed.\n\nExactly one of `bash` and `moonbit` per call.\n\n" +
    dialect_bash +
    "\n\n" +
    dialect_moonbit +
    "\n\n" +
    moonbit_program_help(
      bundled="Bundled scripts — pass `@builtin/NAME` as `moonbit`, and `args` for it:",
      own="Or pass a program of your own in `moonbit`.",
    ) +
    "\n" +
    pragmatics,
    parameters: object_schema(
      [
        (
          "bash",
          str_prop(
            "Shell command to execute. Pass this or `moonbit`, not both.",
          ),
        ),
        (
          "moonbit",
          str_prop(
            "A MoonBit program to run instead of a shell command: `@builtin/NAME` for a bundled one, or a program that defines `async fn main`. Pass this or `bash`, not both.",
          ),
        ),
        (
          "args",
          array_prop(
            str_prop("One argument"),
            "Arguments for a `@builtin/` program",
          ),
        ),
        ("label", str_prop("Short label shown in the transcript")),
      ],
      [],
    ),
    // A shell command can do anything, so it never overlaps another call — and a program compiled
    // and run against the workspace is the same kind of thing.
    concurrency: Exclusive,
    // The turn's stop reaches a running command through the same process-group path it always
    // used. A per-call default would cut off a build that is simply slow.
    timeout_ms: None,
    snippet: "Run a shell command or a MoonBit program; only what it prints comes back",
  }
}

// ── wait ───────────────────────────────────────────────────────────────────

///|
/// How long `wait` holds on when the caller does not say.
///
/// A bound rather than an infinity on purpose: the case this tool must not turn into is a server
/// that never exits holding the turn open until the turn's own time limit fires. Two minutes is
/// long enough for the work worth waiting on and short enough that being wrong costs one call.
pub fn default_wait_seconds() -> Int {
  120
}

///|
/// The ceiling on what one `wait` hands back, in bytes.
///
/// A job's output is whatever the command printed, which for a backgrounded server is a log that
/// grows without bound. The call returns the part since the last one and says there is more, so
/// the model can keep up with a running process without the conversation paying for its whole log.
pub fn wait_max_output_bytes() -> Int {
  32 * 1024
}

///|
/// The tool that collects what a backgrounded command printed.
pub fn wait_tool() -> ToolDef {
  {
    name: "wait",
    description: (
      #|Wait for a job that `exec` left running, and return what it has printed.
      #|
      #|`id` is the name in the result that started it, such as `bash-3`. The call returns as soon
      #|as the job exits, or when `timeout` seconds have passed, whichever comes first — so waiting
      #|on a server that never exits costs one timeout rather than the turn. A job that finished
      #|while nothing was waiting has kept its output, and this call returns it afterwards.
      #|
      #|What comes back is the output printed since the job's output was last handed back, so
      #|waiting twice on a running process returns each line once. A command that is not tracked as
      #|a job — one that returned inside its own `exec` call — has already been read and cannot be
      #|waited on.
    ),
    parameters: object_schema(
      [
        ("id", str_prop("Job id from an `exec` result, e.g. \"bash-3\"")),
        (
          "timeout",
          num_prop(
            "Seconds to wait before returning with whatever there is. Default 120; 0 returns what the job has so far without waiting.",
          ),
        ),
      ],
      ["id"],
    ),
    // Everything before it in a batch has to have run first for the answer to mean anything.
    concurrency: Exclusive,
    timeout_ms: None,
    snippet: "Collect what a command `exec` left running has printed",
  }
}

// ── what `wait` says ───────────────────────────────────────────────────────
//
// The three answers are decided here rather than in the platform layer, so what the model reads is
// written and tested in one place instead of three branches of a poll loop.

///|
/// A job that ended, with the output it produced since the last call.
///
/// The status line leads because it is the part that changes what the model does next: a job that
/// finished is an answer, and a job that is still running is a "there is nothing yet, try again".
pub fn format_wait_result(
  job : Job,
  stdout : String,
  stderr : String,
  more : Bool,
  now : Int64,
) -> ToolOutput {
  let out = StringBuilder()
  out.write_string(wait_headline(job, now))
  let body = StringBuilder()
  if stdout != "" {
    body.write_string(stdout)
  }
  if stderr != "" {
    if body.to_string() != "" {
      body.write_string("\n")
    }
    body.write_string("stderr:\n\{stderr}")
  }
  if body.to_string() == "" {
    if job.detail != "" && job.detail != "exited on its own" {
      body.write_string("(no output; \{job.detail})")
    } else {
      body.write_string("(no output)")
    }
  }
  out.write_string("\n\n\{body.to_string()}")
  if more {
    out.write_string(
      "\n\n… output stopped at \{wait_max_output_bytes() / 1024}KB; call wait again for the rest.",
    )
  }
  let text = out.to_string()
  match job.status {
    Failed | Killed => ToolOutput::error(text)
    _ => ToolOutput::text(text)
  }
}

///|
/// A job that is still running when the wait's timeout ran out.
pub fn format_wait_pending(job : Job, waited_ms : Int64) -> String {
  let pids = job.pids.length()
  let processes = if pids == 1 {
    "pid \{job.pids[0]}"
  } else {
    "\{pids} processes"
  }
  "\{job.id} is still running after \{seconds_text(waited_ms)} (\{processes}). " +
  "Call wait again for its output, or stop it in the sidebar if it should not be running."
}

///|
/// An id that names no job this process knows about.
///
/// The known ids are listed because the usual mistake is a typo in the id, and the answer to that
/// is the set of correct ones — not an invitation to guess again.
pub fn format_wait_unknown(id : String, known : Array[Job]) -> String {
  let live : Array[String] = []
  for job in known {
    if job.is_live() {
      live.push(job.id)
    }
  }
  let suffix = if live.is_empty() {
    "No job is running."
  } else {
    "Running: \{live.join(", ")}."
  }
  "No job \"\{id}\". \{suffix} A job that returned inside its own `exec` call was already read and cannot be waited on."
}

///|
fn wait_headline(job : Job, now : Int64) -> String {
  let age = seconds_text(job.age_ms(now))
  let detail = if job.detail == "" { "" } else { " (\{job.detail})" }
  match job.status {
    Completed => "\{job.id} finished after \{age}\{detail}."
    Failed => "\{job.id} failed after \{age}\{detail}."
    Killed => "\{job.id} was stopped after \{age}\{detail}."
    // A job whose stop was asked for and whose processes are not gone yet. `wait` returns rather
    // than holding on, because the thing being waited for may never agree to stop.
    Stopping =>
      "\{job.id} is stopping; its processes are still there after \{age}."
    Running => "\{job.id} is still running after \{age}."
  }
}

///|
/// A duration as something a reader can compare with the timeout they asked for.
fn seconds_text(ms : Int64) -> String {
  let tenths = ms / 100
  if ms < 1000L {
    "\{ms}ms"
  } else if tenths % 10L == 0L {
    "\{ms / 1000L}s"
  } else {
    let whole = tenths / 10L
    let fraction = tenths % 10L
    "\{whole}.\{fraction}s"
  }
}
