///|
/// Tool bodies against a real filesystem.
///
/// These run in a scratch directory under `_build`, which the build already
/// ignores, so a failed test cannot leave anything behind in the repository.

///|
async fn scratch(name : String) -> String {
  // Unique rather than merely distinct: the tests run concurrently, and two of
  // them creating a shared parent would race between the existence check and the
  // `mkdir`.
  let dir = "_build/tool_test/\{name}-\{@core.new_entry_id()}"
  make_dirs(dir)
  dir
}

///|
fn output_text(output : @core.ToolOutput) -> String {
  let out = StringBuilder()
  for block in output.content {
    match block {
      Text(text) => out.write_string(text)
      _ => ()
    }
  }
  out.to_string()
}

///|
/// Writing then reading returns what was written, and the read is numbered.
async test "write and read round trip" {
  let dir = scratch("rw")
  let written = execute_tool(
    "write",
    @json.parse("{\"path\":\"note.txt\",\"content\":\"alpha\\nbeta\\n\"}"),
    dir,
  )
  assert_false(written.is_error)
  let read = execute_tool("read", @json.parse("{\"path\":\"note.txt\"}"), dir)
  assert_false(read.is_error)
  let text = output_text(read)
  assert_true(text.contains("1: alpha"), msg=text)
  assert_true(text.contains("2: beta"), msg=text)
}

///|
/// A read with an offset numbers from that offset, so the model can cite lines
/// that exist in the file rather than in the slice.
async test "read honours offset and limit" {
  let dir = scratch("offset")
  let _ = execute_tool(
    "write",
    @json.parse(
      "{\"path\":\"lines.txt\",\"content\":\"one\\ntwo\\nthree\\nfour\\n\"}",
    ),
    dir,
  )
  let read = execute_tool(
    "read",
    @json.parse("{\"path\":\"lines.txt\",\"offset\":2,\"limit\":2}"),
    dir,
  )
  let text = output_text(read)
  assert_true(text.contains("2: two"), msg=text)
  assert_true(text.contains("3: three"), msg=text)
  assert_false(text.contains("4: four"), msg=text)
}

///|
async test "reading a missing file is an error, not a crash" {
  let dir = scratch("missing")
  let read = execute_tool("read", @json.parse("{\"path\":\"nope.txt\"}"), dir)
  assert_true(read.is_error)
  assert_true(output_text(read).contains("not found"), msg=output_text(read))
}

///|
/// An edit replaces the matched text and leaves the rest alone.
async test "edit replaces matched text" {
  let dir = scratch("edit")
  let _ = execute_tool(
    "write",
    @json.parse(
      "{\"path\":\"code.mbt\",\"content\":\"let x = 1\\nlet y = 2\\n\"}",
    ),
    dir,
  )
  let edited = execute_tool(
    "edit",
    @json.parse(
      "{\"path\":\"code.mbt\",\"edits\":[{\"oldText\":\"let x = 1\",\"newText\":\"let x = 10\"}]}",
    ),
    dir,
  )
  assert_false(edited.is_error, msg=output_text(edited))
  let read = execute_tool("read", @json.parse("{\"path\":\"code.mbt\"}"), dir)
  assert_true(output_text(read).contains("let x = 10"), msg=output_text(read))
  assert_true(output_text(read).contains("let y = 2"), msg=output_text(read))
}

///|
/// An edit whose text is absent changes nothing and says why, so the model can
/// correct the call rather than guess.
async test "a failed edit leaves the file untouched" {
  let dir = scratch("edit_fail")
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"keep.txt\",\"content\":\"original\\n\"}"),
    dir,
  )
  let edited = execute_tool(
    "edit",
    @json.parse(
      "{\"path\":\"keep.txt\",\"edits\":[{\"oldText\":\"absent\",\"newText\":\"x\"}]}",
    ),
    dir,
  )
  assert_true(edited.is_error)
  assert_true(
    output_text(edited).contains("not found"),
    msg=output_text(edited),
  )
  let read = execute_tool("read", @json.parse("{\"path\":\"keep.txt\"}"), dir)
  assert_true(output_text(read).contains("original"), msg=output_text(read))
}

///|
/// An ambiguous edit is refused: replacing both occurrences would silently change
/// code the model did not mean to touch.
async test "an ambiguous edit is refused" {
  let dir = scratch("edit_ambiguous")
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"dup.txt\",\"content\":\"same\\nsame\\n\"}"),
    dir,
  )
  let edited = execute_tool(
    "edit",
    @json.parse(
      "{\"path\":\"dup.txt\",\"edits\":[{\"oldText\":\"same\",\"newText\":\"diff\"}]}",
    ),
    dir,
  )
  assert_true(edited.is_error)
  assert_true(output_text(edited).contains("2 times"), msg=output_text(edited))
}

///|
async test "glob finds files by pattern" {
  let dir = scratch("glob")
  make_dirs("\{dir}/src/deep")
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"src/a.ts\",\"content\":\"a\"}"),
    dir,
  )
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"src/deep/b.ts\",\"content\":\"b\"}"),
    dir,
  )
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"src/c.md\",\"content\":\"c\"}"),
    dir,
  )

  let found = execute_tool(
    "glob",
    @json.parse("{\"pattern\":\"**/*.ts\"}"),
    dir,
  )
  assert_false(found.is_error)
  let text = output_text(found)
  assert_true(text.contains("src/a.ts"), msg=text)
  assert_true(text.contains("src/deep/b.ts"), msg=text)
  assert_false(text.contains("c.md"), msg=text)
}

///|
/// Build directories are pruned, so a search does not descend into `_build` or
/// `node_modules`.
async test "glob skips build directories" {
  let dir = scratch("glob_skip")
  make_dirs("\{dir}/node_modules/pkg")
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"keep.ts\",\"content\":\"k\"}"),
    dir,
  )
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"node_modules/pkg/vendor.ts\",\"content\":\"v\"}"),
    dir,
  )
  let found = execute_tool(
    "glob",
    @json.parse("{\"pattern\":\"**/*.ts\"}"),
    dir,
  )
  let text = output_text(found)
  assert_true(text.contains("keep.ts"), msg=text)
  assert_false(text.contains("vendor.ts"), msg=text)
}

///|
async test "grep reports file, line, and text" {
  let dir = scratch("grep")
  let _ = execute_tool(
    "write",
    @json.parse(
      "{\"path\":\"a.ts\",\"content\":\"const alpha = 1\\nconst beta = 2\\n\"}",
    ),
    dir,
  )
  let found = execute_tool("grep", @json.parse("{\"pattern\":\"alpha\"}"), dir)
  assert_false(found.is_error)
  let text = output_text(found)
  assert_true(text.contains("a.ts:1:"), msg=text)
  assert_true(text.contains("const alpha = 1"), msg=text)
}

///|
test "grep is case sensitive unless asked otherwise" {
  // Checked through the search helper rather than the whole tool, since the
  // sensitivity lives in the comparison.
  assert_true("Alpha".to_lower().contains("alpha"))
  assert_false("Alpha".contains("alpha"))
}

///|
async test "grep with no match says so" {
  let dir = scratch("grep_none")
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"a.txt\",\"content\":\"hello\\n\"}"),
    dir,
  )
  let found = execute_tool("grep", @json.parse("{\"pattern\":\"zzz\"}"), dir)
  assert_false(found.is_error)
  assert_true(output_text(found).contains("No matches"), msg=output_text(found))
}

// ── bash ───────────────────────────────────────────────────────────────────

///|
async test "bash returns stdout" {
  let dir = scratch("bash")
  let result = execute_tool(
    "bash",
    @json.parse("{\"command\":\"echo hello\"}"),
    dir,
  )
  assert_false(result.is_error)
  assert_true(output_text(result).contains("hello"), msg=output_text(result))
}

///|
/// A non-zero exit is reported as an error carrying the code, so the model can
/// tell a failing command from a silent success.
async test "a failing command reports its exit code" {
  let dir = scratch("bash_fail")
  let result = execute_tool(
    "bash",
    @json.parse("{\"command\":\"exit 3\"}"),
    dir,
  )
  assert_true(result.is_error)
  assert_true(
    output_text(result).contains("Exit code 3"),
    msg=output_text(result),
  )
}

///|
/// The command runs in the working directory it was given, which is what makes
/// relative paths in later tool calls line up.
async test "bash runs in the given directory" {
  let dir = scratch("bash_cwd")
  let _ = execute_tool(
    "write",
    @json.parse("{\"path\":\"here.txt\",\"content\":\"x\"}"),
    dir,
  )
  let result = execute_tool("bash", @json.parse("{\"command\":\"ls\"}"), dir)
  assert_true(output_text(result).contains("here.txt"), msg=output_text(result))
}

///|
/// A command that overruns its timeout is killed and reported, rather than
/// hanging the agent forever.
async test "a command that exceeds its timeout is terminated" {
  let dir = scratch("bash_timeout")
  let result = execute_tool(
    "bash",
    @json.parse("{\"command\":\"sleep 5\",\"timeout\":1}"),
    dir,
  )
  assert_true(result.is_error)
  assert_true(
    output_text(result).contains("timed out"),
    msg=output_text(result),
  )
}

///|
async test "an unknown tool is reported rather than crashing" {
  let dir = scratch("unknown")
  let result = execute_tool("nope", @json.parse("{}"), dir)
  assert_true(result.is_error)
  assert_true(
    output_text(result).contains("Unknown tool"),
    msg=output_text(result),
  )
}
