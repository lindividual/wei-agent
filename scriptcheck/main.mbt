///|
/// Compile and run every bundled `script` program against this repository.
///
/// The bundled scripts are MoonBit source inside string literals, so no type
/// checker sees them: a typo compiles the project and fails only when a model
/// calls that script. This is the check that catches it.
///
/// It is an executable rather than a test because running it means running
/// `moon`, and `moon run` from inside `moon test` deadlocks on the build lock.
/// Run it with `moon run scriptcheck`; the pre-commit hook does.
///
/// Each script is given arguments that make it report something on this
/// repository, and the assertion is on the shape of the digest rather than on
/// its contents — the contents change with the code, the shape is the promise.

///|
/// What a script is run with, and what its output must look like.
struct Probe {
  name : String
  args : Array[String]
  /// A substring the digest must contain.
  expect : String
  /// The most bytes a passing digest may be. The scripts exist to be small.
  max_bytes : Int
} derive(Debug)

///|
fn probes() -> Array[Probe] {
  [
    // A clean tree is one line.
    {
      name: "check",
      args: ["core"],
      expect: "moon check: clean",
      max_bytes: 200,
    },
    // A search that matches things it cannot miss.
    {
      name: "search",
      args: ["pub fn", "core", "5"],
      expect: "hit(s)",
      max_bytes: 4000,
    },
    // The test digest has to work on a tree that passes, which is the common
    // case and the one where it must be one line.
    { name: "test", args: ["core"], expect: "Total tests:", max_bytes: 4000, },
    // A range read reports what it showed and what it did not.
    {
      name: "read",
      args: ["moon.mod:1:5"],
      expect: "lines 1-5 of",
      max_bytes: 4000,
    },
  ]
}

///|
/// Stage one script and run it, returning (exit code, output).
async fn run_script(probe : Probe, cwd : String) -> (Int, String) {
  let body = match @core.builtin_script_source(probe.name) {
    Some(text) => text
    None => abort("no such script: \{probe.name}")
  }
  let dir = @fs.tmpdir(prefix="wei-scriptcheck")
  let path = "\{dir}/script.mbtx"
  @fs.write_file(
    path,
    @utf8.encode(
      "\{@core.script_imports()}\n\{@core.script_prelude()}\n\{body}\n",
    ),
  )
  let argv : Array[String] = [
    "run", "--target", "native", path, "--target-dir", dir,
  ]
  for arg in probe.args {
    argv.push(arg)
  }
  let (code, out) = @process.collect_output_merged("moon", argv, cwd~)
  (code, out.text())
}

///|
async fn main {
  let cwd = match @env.current_dir() {
    Some(d) => d
    None => abort("no working directory")
  }
  let mut failures = 0
  for probe in probes() {
    let (code, raw) = run_script(probe, cwd)
    // The compiler's own warnings about dependencies are not this script's
    // output; keep the check about the digest.
    let lines : Array[String] = []
    for line in raw.split("\n") {
      if line.has_prefix("Warning:") || line.has_prefix("   ") {
        continue
      }
      lines.push(line.to_owned())
    }
    let out = lines.join("\n")
    let problem = if code != 0 {
      Some("exited \{code}")
    } else if !out.contains(probe.expect) {
      Some("expected \{probe.expect}")
    } else if out.length() > probe.max_bytes {
      Some("\{out.length()} bytes, over the \{probe.max_bytes} limit")
    } else {
      None
    }
    match problem {
      None =>
        println(
          "@builtin/\{probe.name}: ok (\{out.length()} bytes, \{out.split("\n").length()} lines)",
        )
      Some(why) => {
        failures += 1
        println("@builtin/\{probe.name}: FAILED — \{why}")
        println("--- raw output ---")
        println(raw)
      }
    }
  }
  if failures > 0 {
    abort("\{failures} bundled script(s) failed")
  }
  println("all bundled scripts run")
}
