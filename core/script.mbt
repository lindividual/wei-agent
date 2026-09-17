///|
/// The `script` tool: run a MoonBit single-file program against the workspace.
///
/// The model's two other ways of doing a lot in one step are `bash` and a long
/// run of `read`/`grep` calls. Both are bounded by the same thing — every step
/// comes back through the conversation. A script puts the loop in the program
/// instead: search, filter, aggregate, and edit inside one call, and hand back a
/// digest rather than the raw output it had to read to produce it.
///
/// The bodies live in `platform/` because they touch the filesystem. What lives
/// here is the declaration, the prelude the scripts are written against, and the
/// script sources themselves — text, so `core` stays free of IO.

///|
/// The output ceiling for a script, in bytes.
///
/// A script exists to *avoid* handing the conversation a large output, so the
/// ceiling is the point rather than a safety net. openseek stops its equivalent
/// at 48KB; taking the round number below that leaves room for the marker that
/// says truncation happened without the marker itself becoming the bulk of it.
pub fn script_max_output_bytes() -> Int {
  32 * 1024
}

// ── The prelude ────────────────────────────────────────────────────────────

///|
/// The library every script is compiled against, prepended at staging time.
///
/// Prepended rather than imported so that a script cannot be broken by editing
/// it, and so that the prewritten scripts and the model's own programs are
/// written against exactly the same API — one implementation, not two.
///
/// Deliberately six functions and no `main`: a script provides its own, and a
/// prelude that defined one would collide with it.
pub fn script_prelude() -> String {
  (
    #|// ── prelude ──────────────────────────────────────────────────────────────
    #|// Provided by wei. Do not redefine these; call them.
    #|
    #|/// Names of files under `dir`, skipping build output and VCS metadata.
    #|pub async fn list(dir : String) -> Array[String] {
    #|  let out : Array[String] = []
    #|  @fs.walk(dir, max_concurrency=1, exclude=skip_path, (d, names) => {
    #|    for name in names {
    #|      let path = "\{d}/\{name}"
    #|      if @fs.kind(path, follow_symlink=false) is Regular {
    #|        out.push(path)
    #|      }
    #|    }
    #|  })
    #|  out
    #|}
    #|
    #|/// Whether a path is build output, VCS metadata, or a dependency cache.
    #|pub fn skip_path(path : String) -> Bool {
    #|  path.contains("_build") ||
    #|  path.contains("/.git") ||
    #|  path.contains(".mooncakes") ||
    #|  path.contains("/target")
    #|}
    #|
    #|/// The whole file as text. Fails on a file that is not UTF-8.
    #|pub async fn read(path : String) -> String {
    #|  @fs.read_file(path).text()
    #|}
    #|
    #|/// Lines `from` to `to`, 1-based and inclusive. Clamped to the file.
    #|pub async fn read_lines(path : String, from : Int, to : Int) -> Array[String] {
    #|  let all : Array[String] = []
    #|  let mut n = 0
    #|  for raw in (@fs.read_file(path).text()).split("\n") {
    #|    n += 1
    #|    if n >= from && n <= to {
    #|      all.push(raw.to_owned())
    #|    }
    #|  }
    #|  all
    #|}
    #|
    #|/// Lines matching a regular expression, as "path:line: text".
    #|///
    #|/// Skips files that are not text: a search that dies on the first PNG is
    #|/// useless. The engine is `moonbitlang/regexp`, which is a VM rather than a
    #|/// backtracker, so a pattern the model gets wrong cannot hang the turn.
    #|pub async fn search(pattern : String, dir : String, max : Int) -> Array[String] {
    #|  let re = @regexp.compile(pattern)
    #|  let hits : Array[String] = []
    #|  for path in list(dir) {
    #|    let text = try @fs.read_file(path).text() catch {
    #|      _ => continue
    #|    } noraise {
    #|      t => t
    #|    }
    #|    let mut n = 0
    #|    for raw in text.split("\n") {
    #|      n += 1
    #|      if re.execute(raw).matched() {
    #|        hits.push("\{path}:\{n}: \{raw}")
    #|        if max > 0 && hits.length() >= max {
    #|          return hits
    #|        }
    #|      }
    #|    }
    #|  }
    #|  hits
    #|}
    #|
    #|/// Parse a JSON file.
    #|pub async fn read_json(path : String) -> Json {
    #|  @json.parse(@fs.read_file(path).text())
    #|}
    #|
    #|/// Replace `old` with `new` in `text`, requiring exactly one occurrence.
    #|///
    #|/// One occurrence rather than first-match: an ambiguous edit is a sign the
    #|/// caller is guessing, and a silent wrong-file edit costs more than the error.
    #|pub fn edit_text(text : String, old : String, new : String) -> String raise {
    #|  let at = text.find(old)
    #|  match at {
    #|    None => fail("edit_text: the text to replace was not found")
    #|    Some(i) => {
    #|      let after = i + old.length()
    #|      if text[after:].find(old) is Some(_) {
    #|        fail("edit_text: the text to replace occurs more than once")
    #|      }
    #|      "\{text[:i]}\{new}\{text[after:]}"
    #|    }
    #|  }
    #|}
    #|
    #|/// An integer argument, or `fallback` when it is not one.
    #|///
    #|/// A malformed number is not worth failing the call over: the ranges and limits
    #|/// these scripts take all have sensible defaults.
    #|pub fn parse_int_or(text : StringView, fallback : Int) -> Int {
    #|  try @string.parse_int(text) catch {
    #|    _ => fallback
    #|  } noraise {
    #|    v => v
    #|  }
    #|}
    #|
    #|/// Stop with an error, which becomes a failed tool result. For assertions a
    #|/// script wants to make about its own work.
    #|pub fn[T] fail(message : String) -> T raise {
    #|  raise Failure::Failure(message)
    #|}
  )
}

///|
/// The imports every staged program gets.
///
/// Fixed rather than derived from the script's own text: a model that wants
/// `@fs` twice is not a case worth a parser for, and a fixed block means the
/// prelude's own imports can never be missing.
pub fn script_imports() -> String {
  let source =
    #|import {
    #|  "moonbitlang/async",
    #|  "moonbitlang/async/fs",
    #|  "moonbitlang/async/process",
    #|  "moonbitlang/core/env",
    #|  "moonbitlang/core/json",
    #|  "moonbitlang/core/string",
    #|  "moonbitlang/regexp",
    #|}
    #|
  source
}

// ── The prewritten scripts ─────────────────────────────────────────────────

///|
/// One bundled script: what it is called, what it takes, what it does.
pub(all) struct ScriptInfo {
  /// The name after `@builtin/`.
  name : String
  /// Argument hint, shown in the tool description.
  args : String
  /// One line for the tool description and the system prompt.
  about : String
} derive(Eq, Debug)

///|
/// The bundled scripts.
///
/// Chosen from what real turns actually do, measured over 3,810 tool calls:
/// exploration was 39%, running commands 20%, and the `read`/`glob`/`grep` tools
/// another 10%. `check` and `test` take the bulk of the command half, `search`
/// and `read` the other — and those four are the ones where the raw output is
/// far larger than what the caller can use.
///
/// Each `about` names the command it replaces. That is not decoration: measured
/// over one 604-call session, 507 calls went to `bash` forms these four exist to
/// replace — 266 `grep -rn`, 99 `python3 - <<'PY'` file rewrites, 66 `moon test`,
/// 52 `moon check` — and none of them was made through this tool. The tool was in
/// the prompt and worked; what it lacked was a reason to be reached for. Saying
/// "instead of `moon check 2>&1 | tail -30`" is that reason, in the smallest form
/// it has.
pub fn builtin_scripts() -> Array[ScriptInfo] {
  [
    {
      name: "check",
      args: "[package]",
      about: "moon check, errors grouped by file, without the source dump — instead of `moon check 2>&1 | tail -30`",
    },
    {
      name: "test",
      args: "[package-or-file]",
      about: "moon test, failures only, long values elided — instead of `moon test 2>&1 | tail -40`",
    },
    {
      name: "search",
      args: "pattern [dir]",
      about: "regex search the workspace, skipping build output — instead of `grep -rn`",
    },
    {
      name: "read",
      args: "path[:from:to] ...",
      about: "several files or line ranges in one call — instead of one `read` per file",
    },
  ]
}

///|
/// The source of a bundled script, or `None` if there is no such script.
///
/// Written against the prelude, so there is one library rather than one per
/// script. Each provides its own `async fn main`.
pub fn builtin_script_source(name : String) -> String? {
  match name {
    "check" => Some(check_script())
    "test" => Some(test_script())
    "search" => Some(search_script())
    "read" => Some(read_script())
    _ => None
  }
}

///|
/// `moon check --output-json`, digested.
///
/// The compiler emits one JSON object per line, with the source excerpt in a
/// `context` field. That excerpt is what makes raw output expensive: for forty
/// errors it is 21KB, of which the caller needs the file, the position, and the
/// first line of each message. Measured on this repository, forty errors come
/// out at 2KB (10x smaller) and two errors at 211 bytes.
fn check_script() -> String {
  (
    #|async fn main raise {
    #|  let args = @env.args()
    #|  let cmd : Array[String] = if args.length() > 1 {
    #|    ["check", "--output-json", "-p", args[1]]
    #|  } else {
    #|    ["check", "--output-json"]
    #|  }
    #|  let (code, out) = @process.collect_output_merged("moon", cmd)
    #|  let errors : Map[String, Array[String]] = Map([])
    #|  let mut warnings = 0
    #|  for line in out.text().split("\n") {
    #|    let raw = line.to_owned()
    #|    if !raw.has_prefix("{") {
    #|      continue
    #|    }
    #|    let j = try @json.parse(raw) catch {
    #|      _ => continue
    #|    } noraise {
    #|      v => v
    #|    }
    #|    if json_string(j, "level") != "error" {
    #|      if json_string(j, "$message_type") == "diagnostic" {
    #|        warnings += 1
    #|      }
    #|      continue
    #|    }
    #|    let path = json_string(j, "path")
    #|    let head = match json_string(j, "message").split("\n").head() {
    #|      Some(h) => h.to_owned()
    #|      None => ""
    #|    }
    #|    bucket(errors, path).push(
    #|      "\{short_name(path)}:\{json_string(j, "loc")} \{head}",
    #|    )
    #|  }
    #|  if code == 0 && errors.is_empty() {
    #|    println("moon check: clean (\{warnings} warnings)")
    #|  } else {
    #|    for path, items in errors {
    #|      println("\{path}")
    #|      for item in items {
    #|        println("  \{item}")
    #|      }
    #|    }
    #|    println(
    #|      "moon check: exit \{code}, \{errors.length()} file(s) with errors, \{warnings} other diagnostics",
    #|    )
    #|  }
    #|}
    #|
    #|/// A string field of a JSON object, or "" when it is absent or another type.
    #|fn json_string(j : Json, key : String) -> String {
    #|  match j {
    #|    Object(m) =>
    #|      match m.get(key) {
    #|        Some(String(s)) => s
    #|        _ => ""
    #|      }
    #|    _ => ""
    #|  }
    #|}
    #|
    #|fn short_name(path : String) -> String {
    #|  match path.split("/").last() {
    #|    Some(n) => n.to_owned()
    #|    None => path
    #|  }
    #|}
    #|
    #|fn bucket(errors : Map[String, Array[String]], path : String) -> Array[String] {
    #|  match errors.get(path) {
    #|    Some(list) => list
    #|    None => {
    #|      let fresh : Array[String] = []
    #|      errors[path] = fresh
    #|      fresh
    #|    }
    #|  }
    #|}
  )
}

///|
/// `moon test`, failures only, with the values elided.
///
/// A failing assertion prints the same long value three times — once in the
/// assertion, once as the `-` side of the diff, once as the `+`. The caller
/// needs the location and enough of the values to see how they differ, so the
/// digest keeps the location and clips each value.
fn test_script() -> String {
  (
    #|async fn main raise {
    #|  let args = @env.args()
    #|  let cmd : Array[String] = if args.length() > 1 {
    #|    ["test", args[1]]
    #|  } else {
    #|    ["test"]
    #|  }
    #|  let (code, out) = @process.collect_output_merged("moon", cmd)
    #|  let mut failures = 0
    #|  let mut total = ""
    #|  for line in out.text().split("\n") {
    #|    let raw = line.to_owned()
    #|    if raw.contains(" FAILED: ") {
    #|      failures += 1
    #|      println(clip(raw, 400))
    #|    } else if raw.has_prefix("Total tests:") {
    #|      total = raw
    #|    } else if raw.strip_prefix("-") is Some(_) ||
    #|      raw.has_prefix("+") ||
    #|      raw == "diff:" {
    #|      // The diff repeats what the failure line already showed, clipped.
    #|      if raw.length() > 200 {
    #|        println(clip(raw, 200))
    #|      } else {
    #|        println(raw)
    #|      }
    #|    }
    #|  }
    #|  if total != "" {
    #|    println(total)
    #|  } else if failures == 0 && code == 0 {
    #|    println("moon test: passed")
    #|  } else {
    #|    println("moon test: exit \{code}, \{failures} failure(s)")
    #|  }
    #|}
    #|
    #|/// A line shortened to `max` characters, with a marker that it happened.
    #|fn clip(line : String, max : Int) -> String {
    #|  if line.length() <= max {
    #|    return line
    #|  }
    #|  "\{line[:max]} … (+\{line.length() - max} chars)"
    #|}
  )
}

///|
/// Regex search over the workspace.
fn search_script() -> String {
  let source =
    #|async fn main raise {
    #|  let args = @env.args()
    #|  if args.length() < 2 {
    #|    fail("usage: search <pattern> [dir] [max]")
    #|  }
    #|  let dir = if args.length() > 2 { args[2] } else { "." }
    #|  let max = if args.length() > 3 {
    #|    parse_int_or(args[3], 200)
    #|  } else {
    #|    200
    #|  }
    #|  let hits = search(args[1], dir, max)
    #|  for hit in hits {
    #|    println(hit)
    #|  }
    #|  println("\{hits.length()} hit(s) in \{dir}")
    #|}
  source
}

///|
/// Batch read, keeping the line-range and truncation reporting the `read` tool
/// has so a caller can tell "this is the whole file" from "this is a window".
fn read_script() -> String {
  let source =
    #|async fn main raise {
    #|  let args = @env.args()
    #|  if args.length() < 2 {
    #|    fail("usage: read path[:from:to] ...")
    #|  }
    #|  let mut i = 1
    #|  while i < args.length() {
    #|    let spec = args[i]
    #|    i += 1
    #|    let parts : Array[StringView] = spec.split(":").collect()
    #|    let path = parts[0].to_owned()
    #|    let from = if parts.length() > 1 {
    #|      parse_int_or(parts[1], 1)
    #|    } else {
    #|      1
    #|    }
    #|    let to = if parts.length() > 2 {
    #|      parse_int_or(parts[2], 1000000000)
    #|    } else {
    #|      1000000000
    #|    }
    #|    let all = try read(path) catch {
    #|      e => {
    #|        println("=== \{path} === not readable: \{e}")
    #|        continue
    #|      }
    #|    } noraise {
    #|      t => t
    #|    }
    #|    // Collected, not an iterator: taking the length of an `Iter` consumes it,
    #|    // and the loop below would then run zero times.
    #|    let lines : Array[StringView] = all.split("\n").collect()
    #|    let total = lines.length()
    #|    let last = if to < total { to } else { total }
    #|    println("=== \{path} === lines \{from}-\{last} of \{total}")
    #|    let mut n = 0
    #|    for raw in lines {
    #|      n += 1
    #|      if n >= from && n <= last {
    #|        println("\{n}\t\{raw}")
    #|      }
    #|    }
    #|    if last < total {
    #|      println("… \{total - last} more line(s); read again with a range")
    #|    }
    #|  }
    #|}
  source
}

// ── The tool ───────────────────────────────────────────────────────────────

///|
/// What a caller needs to know to write a MoonBit program here: the bundled
/// scripts, the prelude's API, and two examples.
///
/// Shared by the `script` tool and by code mode's `exec`, which run the same
/// programs through the same prelude and therefore have to describe them the
/// same way. Only the sentence that says how to hand the program over differs,
/// and that one stays with each tool.
///
/// Written as prose plus a generated list rather than one literal: `#|` takes
/// quotes and backslashes literally, which is what makes the examples readable,
/// but it does not interpolate — so the list is concatenated in.
///
/// `bundled` and `own` are the two sentences that name how the program is handed over, which is
/// the one thing the two tools spell differently — `script` takes `source` or `name`, `exec` takes
/// one `moonbit` field that is either.
pub fn moonbit_program_help(bundled~ : String, own~ : String) -> String {
  let scripts = StringBuilder()
  for info in builtin_scripts() {
    scripts.write_string(
      "\n  - @builtin/\{info.name} \{info.args}: \{info.about}",
    )
  }
  let tail =
    #|
    #|It must define `async fn main`, and the prelude provides `list`, `read`, `read_lines`,
    #|`search`, `read_json`, `edit_text` and `fail`:
    #|
    #|  search the repository:
    #|    async fn main {
    #|      for hit in search("fn trim_", "core", 10) { println(hit) }
    #|    }
    #|
    #|  change a file (edit_text replaces a string that must occur exactly once):
    #|    async fn main {
    #|      let path = "core/trim.mbt"
    #|      write(path, edit_text(read(path), "recent_window: 20", "recent_window: 40"))
    #|    }
    #|
    #|A program can read, write and run commands in the workspace. stdout is the result, truncated
    #|at 32KB — print the part you need, not everything you found.
  bundled + scripts.to_string() + "\n\n" + own + tail
}

///|
/// The `script` tool.
///
/// `Exclusive` because a script can write files and run commands, which is the
/// same reason `bash` is.
pub fn script_tool() -> ToolDef {
  let head =
    #|Run a MoonBit program against the workspace and get back only what it prints.
    #|
    #|Reach for this instead of a `bash` command when a step would otherwise be several reads,
    #|a grep across the repo, a loop or an aggregation over files, a command whose raw output is
    #|much larger than the part you need, or a program you would write just to change files. The
    #|work happens inside the call, so the conversation receives the result rather than everything
    #|the program had to read to produce it. For a single file, `read` is cheaper.
    #|
  {
    name: "script",
    description: head +
    moonbit_program_help(
      bundled="Bundled scripts — pass `name` and `args`:",
      own="Or pass `source` with a program of your own.",
    ),
    parameters: object_schema(
      [
        (
          "name",
          str_prop(
            "A bundled script to run, e.g. \"@builtin/check\". Pass args for it.",
          ),
        ),
        (
          "args",
          array_prop(
            str_prop("One argument"),
            "Arguments for the bundled script",
          ),
        ),
        (
          "source",
          str_prop(
            "A MoonBit program to run instead of a bundled script. Must define `async fn main`.",
          ),
        ),
        ("label", str_prop("Short label shown in the transcript")),
      ],
      [],
    ),
    concurrency: Exclusive,
    // A script runs its own command (a `moon check` is seconds); the turn's
    // stop reaches it through the same process-group path `bash` uses.
    timeout_ms: None,
    snippet: "Run a program instead of a long chain of reads, greps or edits",
  }
}

// ── Output ─────────────────────────────────────────────────────────────────

///|
/// Render a script's outcome, with the output ceiling applied.
///
/// Separate from `format_exec_result` because the ceiling is smaller and the
/// marker has to say what to do about it: a script that hit the ceiling is
/// usually asking for the wrong thing, and the fix is to print less, not to
/// raise the limit.
pub fn format_script_result(
  stdout : String,
  stderr : String,
  exit_code : Int,
) -> ToolOutput {
  let out = StringBuilder()
  // Unwrapped per stream, before the `stderr:` label is added. Unwrapping the
  // assembled text instead never fires in the case it exists for: an uncaught
  // `fail` arrives on stderr, so the whole text begins `stderr:` and not
  // `Failure(` — measured by the test below failing while the code looked right.
  let head = truncate_script_output(unwrap_raise(stdout))
  if head != "" {
    out.write_string(head)
  }
  let tail = truncate_script_output(unwrap_raise(stderr))
  if tail != "" {
    if out.to_string() != "" {
      out.write_string("\n")
    }
    out.write_string("stderr:\n\{tail}")
  }
  if out.to_string() == "" {
    out.write_string(
      if exit_code == 0 {
        "(the script printed nothing)"
      } else {
        "(no output)"
      },
    )
  }
  let text = out.to_string()
  if exit_code != 0 {
    return ToolOutput::error("\{text}\n\nScript exited \{exit_code}")
  }
  ToolOutput::text(text)
}

///|
/// Strip the runtime's wrapper from an uncaught `fail`.
///
/// `async fn main raise` reports an uncaught error as `Failure(message)` on stderr
/// and exits 1 — clean, but the constructor is noise the caller did not write.
fn unwrap_raise(text : String) -> String {
  let trimmed = text.trim()
  if trimmed.has_prefix("Failure(") && trimmed.has_suffix(")") {
    return trimmed[8:trimmed.length() - 1].to_owned()
  }
  text
}

///|
/// Keep the head of a script's output, up to the ceiling.
pub fn truncate_script_output(text : String) -> String {
  let bytes = @utf8.encode(text).length()
  if bytes <= script_max_output_bytes() {
    return text
  }
  // Cut on a character boundary by taking characters until the budget is spent,
  // so the marker can never be preceded by half a character.
  let budget = script_max_output_bytes()
  let kept = StringBuilder()
  let mut used = 0
  for ch in text {
    let width = @utf8.encode(ch.to_string()).length()
    if used + width > budget {
      break
    }
    kept.write_char(ch)
    used += width
  }
  "\{kept.to_string()}\n\n… output truncated at \{budget / 1024}KB (\{bytes} bytes total). Print less: select the part you need inside the script instead of printing everything."
}
