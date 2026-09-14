///|
/// Running a `script` call: stage a MoonBit program, compile and run it, digest
/// the result.
///
/// The staging directory is what makes this cheap. `moon` reuses compiled
/// packages per target directory, so keeping one directory per workspace turns a
/// second call from a cold build into a warm one — measured on this repository,
/// 0.27s cold against 0.03s warm. Nothing else is needed to get that; there is
/// no cache to invalidate and no key to compute.
///
/// It lives outside the workspace because a script must not leave `_build`
/// artifacts, temp files, or a stray `.mbtx` in the project it is working on.

///|
/// How long a script may run before it is killed, in milliseconds.
///
/// A script compiles a program and then runs it, so the budget is larger than a
/// command's. Long enough for a cold build plus a `moon check`, and short enough
/// that a script stuck on something cannot hold the turn.
let script_timeout_ms : Int = 120000

///|
/// Where a workspace's staged scripts live.
///
/// Keyed by the workspace path so the build cache is per project, and under the
/// system temporary directory so nothing lands in the project.
fn script_dir(cwd : String) -> String {
  let root = match @env.get_env_var("TMPDIR") {
    Some(dir) if dir != "" => "\{dir}/pi-web-shell/scripts"
    _ => "/tmp/pi-web-shell/scripts"
  }
  "\{root}/\{@core.session_dir_name(cwd)}"
}

///|
/// The program to run: the fixed imports, the prelude, then the body.
///
/// Concatenated rather than assembled by parsing the body. A model that wants an
/// import the prelude already provides is not a case worth a parser, and a fixed
/// prefix cannot disagree with what the prelude needs.
fn staged_source(body : String) -> String {
  "\{@core.script_imports()}\n\{@core.script_prelude()}\n\{body}\n"
}

///|
/// Resolve which program this call runs.
///
/// A bundled script takes `name` and `args`; a program of the caller's own takes
/// `source`. Exactly one, because a call that supplied both would have to pick,
/// and the caller would not be able to tell which from the result.
fn script_body(arguments : Json) -> Result[String, String] {
  let name = @core.arg_string(arguments, "name")
  let source = @core.arg_string(arguments, "source")
  match (name, source) {
    (Some(n), _) if n != "" => {
      let plain = match n.strip_prefix("@builtin/") {
        Some(rest) => rest.to_owned()
        None => n
      }
      match @core.builtin_script_source(plain) {
        Some(text) =>
          Ok(
            // The script's own name is its first argument, so a script can tell
            // how it was called without the caller passing anything.
            text,
          )
        None => {
          let known = StringBuilder()
          for info in @core.builtin_scripts() {
            known.write_string("\n  @builtin/\{info.name} \{info.args}")
          }
          Err("Unknown script \"\{n}\". Available:" + known.to_string())
        }
      }
    }
    (_, Some(s)) if s != "" => Ok(s)
    _ =>
      Err(
        "Pass either `name` (a bundled script) or `source` (a MoonBit program defining `async fn main`).",
      )
  }
}

///|
/// Run a `script` call.
pub async fn run_script(arguments : Json, cwd : String) -> @core.ToolOutput {
  let body = match script_body(arguments) {
    Ok(text) => text
    Err(message) => return @core.ToolOutput::error(message)
  }
  let dir = script_dir(cwd)
  // One file name per workspace: the body changes between calls, the path does
  // not, which is what keeps the compiled packages warm.
  let path = "\{dir}/script.mbtx"
  try @fs.mkdir(dir, recursive=true) catch {
    e => return @core.ToolOutput::error("Could not create \{dir}: \{e}")
  } noraise {
    _ => ()
  }
  try @fs.write_file(path, @utf8.encode(staged_source(body))) catch {
    e => return @core.ToolOutput::error("Could not stage the script: \{e}")
  } noraise {
    _ => ()
  }
  // The bundle's args come from this tool's own `args` array; a script sees them
  // as argv after its own name.
  let argv : Array[String] = [
    "run", "--target", "native", path, "--target-dir", dir,
  ]
  for arg in @core.arg_strings(arguments, "args") {
    argv.push(arg)
  }
  let running = () => @process.collect_output_merged("moon", argv, cwd~)
  let outcome = try @async.with_timeout_opt(script_timeout_ms, running) catch {
    e =>
      return @core.ToolOutput::error(
        "Could not run moon (is the toolchain installed and on PATH?): \{e}",
      )
  } noraise {
    result => result
  }
  match outcome {
    None =>
      @core.ToolOutput::error(
        "The script did not finish within \{script_timeout_ms / 1000}s and was stopped.",
      )
    Some((code, out)) => @core.format_script_result(out.text(), "", code)
  }
}
