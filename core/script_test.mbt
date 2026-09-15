///|
/// The `script` tool's declaration: the text the model reads, the bundled
/// programs it can call, and the prelude they are written against.
///
/// All of this is data — strings and schemas — so it is checked here, where no
/// compiler or filesystem is involved. Whether the bundled programs *run* is a
/// different question with a different answer: `scriptcheck/` compiles and runs
/// each of them, because they are MoonBit source inside string literals and no
/// type checker sees them.
///
/// The declarations are worth asserting on because they are the whole of the
/// tool's discoverability. A tool that exists and is described badly is a tool
/// that goes unused — measured: over one 604-call session the tool was in the
/// prompt, worked when called, and was called zero times while 507 calls went to
/// the `bash` forms it exists to replace.

///|
/// A bundled script is only reachable if the tool names it, so the two lists must
/// be the same list.
test "the advertised scripts are exactly the runnable ones" {
  let advertised : Array[String] = []
  for info in builtin_scripts() {
    advertised.push(info.name)
    assert_true(
      builtin_script_source(info.name) is Some(_),
      msg="\{info.name} is advertised but has no source",
    )
    assert_true(
      script_tool().description.contains("@builtin/\{info.name}"),
      msg="the description omits \{info.name}",
    )
    assert_true(
      script_tool().description.contains(info.about),
      msg="the description omits what \{info.name} is for",
    )
  }
  assert_eq(advertised, ["check", "test", "search", "read"])
  // And a name nobody bundled has no source to run.
  assert_true(builtin_script_source("nope") is None)
}

///|
/// Every bundled script has to say which command it replaces.
///
/// This is the load-bearing half of the copy, not decoration. The four scripts
/// exist because four command shapes are both common and verbose — and the
/// measurement above is what happens when the description says what the script
/// *does* without saying what it is *instead of*. The reader was not choosing
/// between two ways to do the same thing; they did not know they were choosing.
///
/// So the check is on the pattern, not on the wording: each `about` has to name
/// a command the reader would otherwise have typed.
test "each bundled script names the command it replaces" {
  for info in builtin_scripts() {
    assert_true(
      info.about.contains("instead of"),
      msg="\{info.name} does not say what it replaces: \{info.about}",
    )
  }
}

///|
/// The description has to show both ways in, with a program to copy.
///
/// A list of prelude function names is not an example: it says what exists, not
/// how to use it. The measured failure was a reader who knew `search` and
/// `edit_text` existed and still reached for `grep -rn` and a Python heredoc,
/// because writing the call meant inventing it. So both forms are asserted —
/// `name` with `args`, and `source` with a program — and the `source` example has
/// to contain an actual call from the prelude.
test "the description shows both ways in, with an example of each" {
  let description = script_tool().description
  assert_true(
    description.contains("@builtin/check"),
    msg="no bundled-script example",
  )
  // The inline example has to be a program that would run: a main, and a real
  // call. A skeleton with `...` in it is the thing that does not get copied.
  assert_true(
    description.contains("async fn main"),
    msg="the inline example has no main",
  )
  let mut calls = 0
  for name in ["search(", "edit_text(", "read(", "write(", "list("] {
    if description.contains(name) {
      calls += 1
    }
  }
  assert_true(
    calls >= 2,
    msg="the inline example calls nothing from the prelude",
  )
  // Both parameters are named, because a reader who does not know the field name
  // cannot pass `source` at all.
  assert_true(
    description.contains("`name`") && description.contains("`source`"),
  )
}

///|
/// The prelude is the API both the bundled programs and the model's own programs
/// are written against, so a function that disappears from it has to break a test
/// rather than a turn — and the description has to keep naming them.
test "the prelude provides the documented functions" {
  let prelude = script_prelude()
  for
    name in [
      "list", "read", "read_lines", "search", "read_json", "edit_text", "fail",
    ] {
    assert_true(
      prelude.contains("\{name}("),
      msg="the prelude does not define \{name}",
    )
    assert_true(
      script_tool().description.contains(name),
      msg="the description does not mention \{name}",
    )
  }
  // No `main`: a program supplies its own, and one here would collide with every
  // script that defines one.
  assert_false(prelude.contains("fn main("))
  // Public, because a private function used by a script is an unused-function
  // warning, and warnings from the staged program land in the digest.
  assert_true(prelude.contains("pub fn"))
}

///|
/// Every import the prelude needs is in the fixed block.
///
/// The block is fixed rather than derived from the program's own text, which is
/// only safe if it covers what the prelude uses — otherwise the prelude compiles
/// in a project because *this* package imports those, and fails the moment it is
/// staged into a scratch file alone. That is exactly how `@strconv` was missed:
/// it compiled here and broke in every staged script.
test "the fixed imports cover what the prelude uses" {
  let imports = script_imports()
  for
    module_path in [
      "moonbitlang/async/fs", "moonbitlang/async/process", "moonbitlang/core/json",
      "moonbitlang/core/string", "moonbitlang/regexp",
    ] {
    assert_true(
      imports.contains(module_path),
      msg="the import block omits \{module_path}",
    )
  }
}

///|
/// The output ceiling is a ceiling, and hitting it says what to do about it.
///
/// A script exists to keep a large output out of the conversation, so this is not
/// a safety net: a script that reached it asked for the wrong thing, and the
/// marker has to say so rather than just stopping.
test "a long output is cut at the ceiling and says so" {
  let short = "ok\n"
  assert_eq(truncate_script_output(short), short)

  let long = StringBuilder()
  // Over the ceiling, not at it: `<=` is the comparison, so a string of exactly
  // the cap is not truncated — which is what this test asserted the first time
  // and why it failed.
  for _ in 0..<(script_max_output_bytes() + 64) {
    long.write_string("x")
  }
  let original = long.to_string()
  let cut = truncate_script_output(original)
  assert_true(cut != original, msg="not truncated")
  assert_true(cut.contains("truncated"), msg=cut)
  assert_true(
    cut.contains("Print less"),
    msg="the marker does not say what to do",
  )
  // The marker is *appended*, so the result is longer than the original rather
  // than shorter — the assertion this test started with, and why it failed. What
  // is bounded is the kept part: everything before the marker.
  let marker = cut.find("\n\n… output truncated")
  match marker {
    None => fail("the marker is not where it should be")
    Some(at) =>
      assert_true(
        at <= script_max_output_bytes(),
        msg="kept \{at} bytes, over the ceiling",
      )
  }
}

///|
/// A non-zero exit is reported as a failed call, and an uncaught `fail` loses the
/// runtime's wrapper on the way through.
///
/// `async fn main raise` reports an uncaught error as `Failure(message)`; the
/// constructor is the runtime's, not the program's, and a reader should get the
/// author's sentence and not the wrapper around it.
test "a failed script is a failed call, with the wrapper removed" {
  let ok = format_script_result("printed\n", "", 0)
  assert_false(ok.is_error)
  let bad = format_script_result("", "not found\n", 1)
  assert_true(bad.is_error)
  // An uncaught `fail` is the common failure, and it arrives on stderr — so this
  // is the case the unwrapping exists for, not the one where the whole output is
  // the wrapper.
  let raised = format_script_result("", "Failure(usage: read path)\n", 1)
  match raised.content {
    [Text(t), ..] => {
      assert_true(t.contains("usage: read path"), msg=t)
      assert_false(t.contains("Failure("), msg=t)
    }
    _ => fail("no content")
  }
}

///|
/// The tool is declared the way the driver needs it: exclusive, because a program
/// can write files and run commands.
test "the script tool is declared exclusively and takes three optional fields" {
  let tool = script_tool()
  assert_eq(tool.name, "script")
  // The four fields are optional in the schema because the two ways in are
  // mutually exclusive: requiring all of them would make every call invalid.
  let required = match tool.parameters {
    Object(fields) =>
      match fields.get("required") {
        Some(Array(items)) => items.length()
        _ => -1
      }
    _ => -1
  }
  assert_eq(required, 0)
  for field in ["name", "args", "source", "label"] {
    assert_true(tool.parameters.stringify().contains(field), msg=field)
  }
  // A program can do anything, so it never overlaps another call.
  assert_true(tool.concurrency is Exclusive)
}
