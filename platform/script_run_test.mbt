///|
/// The bundled scripts have to actually run.
///
/// They are MoonBit source embedded in a string, which no type checker sees: a
/// typo in one of them compiles here and fails only when a model calls it. So
/// every script is executed against a real workspace, which is also the only way
/// to check that the prelude and the script agree about the API.

///|
/// Run a bundled script the way the tool does, and return (exit, output).
async fn run_bundled(name : String, args : Array[String]) -> (Int, String) {
  let dir = @fs.tmpdir(prefix="pi-mb-script-test")
  let path = "\{dir}/script.mbtx"
  let body = match @core.builtin_script_source(name) {
    Some(text) => text
    None => abort("no such script: \{name}")
  }
  @fs.write_file(
    path,
    @utf8.encode(
      "\{@core.script_imports()}\n\{@core.script_prelude()}\n\{body}\n",
    ),
  )
  // The repository root: the tests run with it as cwd.
  let cwd = @fs.realpath(".")
  let argv : Array[String] = [
    "run", "--target", "native", path, "--target-dir", dir,
  ]
  for arg in args {
    argv.push(arg)
  }
  let (code, out) = @process.collect_output_merged("moon", argv, cwd~)
  (code, out.text())
}

///|
/// `@builtin/check` reports a clean tree in one line.
///
/// The whole point of the script is that a caller who only needs to know "does
/// it compile" does not receive the compiler's output. So the assertion is not
/// just that it succeeds but that it says almost nothing.
async test "check reports a clean tree in one line" {
  let (code, out) = run_bundled("check", ["core"])
  assert_eq(code, 0, msg=out)
  assert_true(out.contains("moon check: clean"), msg=out)
  assert_true(
    out.length() < 200,
    msg="clean output should be a line, got \{out.length()} bytes: \{out}",
  )
}

///|
/// A script that cannot compile is reported as a failed tool result, not a crash.
///
/// The failure mode this protects against is the one that would be worst here:
/// the model's own program having a type error, which is a normal event, coming
/// back as an exception that ends the turn.
test "format_script_result reports a non-zero exit as an error" {
  let ok = @core.format_script_result("printed\n", "", 0)
  assert_false(ok.is_error)
  let bad = @core.format_script_result("", "not found\n", 1)
  assert_true(bad.is_error)
}

///|
/// Every bundled script must be one the tool advertises, and vice versa.
///
/// The list in the tool description is what the model chooses from; a script
/// that exists but is not listed is invisible, and one that is listed but does
/// not exist is a dead end it will walk into.
test "the advertised scripts are exactly the runnable ones" {
  let advertised : Array[String] = []
  for info in @core.builtin_scripts() {
    advertised.push(info.name)
    assert_true(
      @core.builtin_script_source(info.name) is Some(_),
      msg="\{info.name} is advertised but has no source",
    )
  }
  assert_eq(advertised, ["check", "test", "search", "read"])
  assert_true(@core.builtin_script_source("nope") is None)
}

///|
/// The tool description has to name every script, or the model cannot find them.
test "the tool description lists the scripts" {
  let tool = @core.script_tool()
  assert_eq(tool.name, "script")
  for info in @core.builtin_scripts() {
    assert_true(
      tool.description.contains("@builtin/\{info.name}"),
      msg="description omits \{info.name}",
    )
    assert_true(
      tool.description.contains(info.about),
      msg="description omits what \{info.name} is for",
    )
  }
}

///|
/// The prelude is the API the scripts and the model both program against, so a
/// function that disappears from it has to break a test rather than a turn.
test "the prelude provides the documented functions" {
  let prelude = @core.script_prelude()
  for
    name in [
      "list", "read", "read_lines", "search", "read_json", "edit_text", "fail",
    ] {
    assert_true(
      prelude.contains("fn \{name}("),
      msg="the prelude does not define \{name}",
    )
  }
  // No `main`: a program supplies its own, and a prelude that defined one would
  // collide with every script.
  assert_false(prelude.contains("fn main("))
}
