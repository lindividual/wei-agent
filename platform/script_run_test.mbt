///|
/// The `script` tool's behaviour that does not need to run a script.
///
/// The bundled programs are MoonBit source embedded in a string, which no type
/// checker sees. Compiling them needs `moon run` from inside `moon test`, and
/// nesting those two deadlocks on the build lock — measured, twice. So running
/// them lives in `scriptcheck/` (`moon run scriptcheck`), which the pre-commit
/// hook calls, and what stays here is everything that can be checked without
/// spawning a compiler.

///|
/// A call with neither `name` nor `source` is a usage error, not a crash.
///
/// No `moon` runs for this one, so it is safe in the default suite.
async test "a script call with no program is refused" {
  let out = @platform.execute_tool("script", Json::empty_object(), ".")
  assert_true(out.is_error)
  let text = match out.content {
    [Text(t), ..] => t
    _ => ""
  }
  assert_true(text.contains("either `name`"), msg=text)
}

///|
/// An unknown bundled name lists the ones that exist.
///
/// The model that mistypes a name should be able to correct itself from the
/// result rather than by guessing again.
async test "an unknown bundled script lists the available ones" {
  let arguments : Json = @json.parse("{\"name\":\"@builtin/nope\"}")
  let out = @platform.execute_tool("script", arguments, ".")
  assert_true(out.is_error)
  let text = match out.content {
    [Text(t), ..] => t
    _ => ""
  }
  assert_true(text.contains("@builtin/check"), msg=text)
  assert_true(text.contains("@builtin/search"), msg=text)
}
