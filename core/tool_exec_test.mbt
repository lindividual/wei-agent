///|
/// Tool execution logic: argument reading, output formatting, and the edit
/// algorithm.

///|
fn repl(old_text : String, new_text : String) -> Replacement {
  { old_text, new_text, }
}

///|
fn applied(content : String, edits : Array[Replacement]) -> String raise {
  match apply_edits(content, edits) {
    Ok(result) => result
    Err(error) => fail("expected success, got \{error}")
  }
}

///|
fn edit_error(content : String, edits : Array[Replacement]) -> EditError raise {
  match apply_edits(content, edits) {
    Ok(_) => fail("expected a failure")
    Err(error) => error
  }
}

// ── Editing ────────────────────────────────────────────────────────────────

///|
test "a single replacement" {
  assert_eq(applied("hello world", [repl("world", "there")]), "hello there")
}

///|
test "several replacements" {
  let content = "a = 1\nb = 2\nc = 3\n"
  assert_eq(
    applied(content, [repl("a = 1", "a = 10"), repl("c = 3", "c = 30")]),
    "a = 10\nb = 2\nc = 30\n",
  )
}

///|
/// Replacements are located in the original text, so an edit may refer to a region
/// a later one also touches. This is the contract the tool description makes.
test "edits are matched against the original text" {
  let content = "aaa\nbbb\nccc\n"
  // Both match positions in the original; neither shifts the other.
  assert_eq(
    applied(content, [repl("aaa", "AAA"), repl("bbb", "BBB")]),
    "AAA\nBBB\nccc\n",
  )
}

///|
/// Applying back to front is what keeps earlier offsets valid; this would corrupt
/// the output if the order were naive.
test "replacements of different lengths do not shift each other" {
  let content = "short INSERTHERE tail"
  assert_eq(
    applied(content, [
      repl("INSERTHERE", "a much longer replacement"),
      repl("tail", "t"),
    ]),
    "short a much longer replacement t",
  )
}

///|
test "text that is not present is reported with its index" {
  let error = edit_error("hello", [repl("absent", "x")])
  assert_true(error is NotFound(index=0, ..), msg="\{error}")
}

///|
/// An ambiguous edit is refused rather than guessed: the model is told to add
/// context, which is a correction it can act on.
test "ambiguous text is refused with the count" {
  let error = edit_error("x\nx\n", [repl("x", "y")])
  assert_true(error is Ambiguous(index=0, count=2, ..), msg="\{error}")
  assert_true(error.to_string().contains("2 times"), msg=error.to_string())
}

///|
test "overlapping edits are refused" {
  let error = edit_error("abcdef", [repl("abc", "X"), repl("bcd", "Y")])
  assert_true(error is Overlapping(first=0, second=1), msg="\{error}")
}

///|
/// Adjacent but not overlapping is allowed: `ab` and `cd` in `abcd` touch without
/// sharing a character.
test "adjacent edits are allowed" {
  assert_eq(applied("abcd", [repl("ab", "X"), repl("cd", "Y")]), "XY")
}

///|
/// A rejected set changes nothing, so a partially applied edit cannot be left
/// behind.
test "a rejected edit set changes nothing" {
  let content = "keep me"
  let _ = apply_edits(content, [repl("keep", "drop"), repl("missing", "x")])
  assert_eq(content, "keep me")
}

///|
/// Replacement text that itself contains the search text must not be rescanned —
/// that is the classic way this kind of function loops.
test "replacement text is not rescanned" {
  assert_eq(applied("a", [repl("a", "aa")]), "aa")
}

///|
/// Multi-byte characters are matched and replaced without being split.
test "edits work on multi-byte text" {
  assert_eq(
    applied("这是中文内容", [repl("中文", "汉字")]),
    "这是汉字内容",
  )
}

///|
test "an empty edit list is the identity" {
  assert_eq(applied("unchanged", []), "unchanged")
}

// ── Arguments ──────────────────────────────────────────────────────────────

///|
test "arguments are read by type" {
  let args = @json.parse(
    "{\"s\":\"text\",\"n\":7,\"b\":true,\"a\":[1,2],\"missing\":null}",
  )
  assert_eq(arg_string(args, "s"), Some("text"))
  assert_eq(arg_int(args, "n"), Some(7))
  assert_eq(arg_bool(args, "b"), Some(true))
  assert_eq(arg_array(args, "a").length(), 2)
  assert_eq(arg_string(args, "nope"), None)
  // A required accessor degrades to empty rather than throwing, so the tool can
  // report the problem to the model.
  assert_eq(arg_required_string(args, "nope"), "")
}

// ── Formatting ─────────────────────────────────────────────────────────────

///|
/// stdout and stderr are labelled so a silent failure is distinguishable from a
/// noisy success.
test "stderr is labelled" {
  let output = format_exec_result(
    { stdout: "out\n", stderr: "warn\n", exit_code: 0, timed_out: false, },
    "/tmp",
  )
  assert_false(output.is_error)
  match output.content {
    [Text(t)] => {
      assert_true(t.contains("out"), msg=t)
      assert_true(t.contains("stderr:"), msg=t)
      assert_true(t.contains("warn"), msg=t)
    }
    _ => fail("expected one text block")
  }
}

///|
test "a failing exit code marks the result as an error" {
  let output = format_exec_result(
    { stdout: "", stderr: "boom", exit_code: 2, timed_out: false, },
    "/tmp",
  )
  assert_true(output.is_error)
  match output.content {
    [Text(t)] => assert_true(t.contains("Exit code 2"), msg=t)
    _ => fail("expected one text block")
  }
}

///|
test "a timed out command is reported as such" {
  let output = format_exec_result(
    { stdout: "partial", stderr: "", exit_code: -1, timed_out: true, },
    "/tmp",
  )
  assert_true(output.is_error)
  match output.content {
    [Text(t)] => {
      assert_true(t.contains("timed out"), msg=t)
      assert_true(t.contains("partial"), msg=t)
    }
    _ => fail("expected one text block")
  }
}

///|
/// Line numbers are included because the model cites them when editing, and
/// counting lines itself is the kind of arithmetic it gets wrong.
test "a read result is numbered from one" {
  let output = format_read_result("a.ts", "first\nsecond\n", None)
  assert_false(output.is_error)
  match output.content {
    [Text(t)] => {
      assert_true(t.contains("1: first"), msg=t)
      assert_true(t.contains("2: second"), msg=t)
    }
    _ => fail("expected one text block")
  }
}

///|
/// The numbers are absolute: the slice starts at the file's line 50, so the first
/// line returned is numbered 50 rather than 1.
test "an offset shifts the numbering" {
  let output = format_read_result("a.ts", "mid\nlast\n", Some(50))
  assert_false(output.is_error)
  match output.content {
    [Text(t)] => {
      assert_true(t.contains("a.ts from line 50"), msg=t)
      assert_true(t.contains("50: mid"), msg=t)
      assert_true(t.contains("51: last"), msg=t)
    }
    _ => fail("expected one text block")
  }
}

///|
/// An offset beyond the slice yields no body; range checking belongs to the caller,
/// the only layer that knows the file's length.
test "an offset past the slice yields an empty body" {
  let output = format_read_result("a.ts", "", Some(99))
  assert_false(output.is_error)
  match output.content {
    [Text(t)] => assert_true(t.contains("from line 99"), msg=t)
    _ => fail("expected one text block")
  }
}

///|
/// A tool call summarised for a reader watching it happen.
test "tool_summary names the interesting argument" {
  assert_eq(
    tool_summary(@json.parse("{\"command\":\"sleep 300\",\"cwd\":\"/tmp\"}")),
    "sleep 300",
  )
  assert_eq(
    tool_summary(@json.parse("{\"path\":\"core/tool_exec.mbt\"}")),
    "core/tool_exec.mbt",
  )
  assert_eq(tool_summary(@json.parse("{\"pattern\":\"TODO\"}")), "TODO")
  // Unknown shapes still say something rather than nothing.
  assert_true(tool_summary(@json.parse("{\"weird\":1}")).contains("weird"))
  // Nothing to say must not read as an empty command.
  assert_eq(tool_summary(@json.parse("{}")), "")
}

///|
test "tool_summary collapses whitespace and clips" {
  let long = "{\"command\":\"" + "x".repeat(200) + "\"}"
  let summary = tool_summary(@json.parse(long))
  assert_eq(summary.length(), 121)
  assert_true(summary.has_suffix("…"), msg=summary)
  assert_eq(tool_summary(@json.parse("{\"command\":\"a\\n\\n  b\"}")), "a b")
}

///|
/// Characters outside the BMP — emoji, and most CJK extensions — are two code
/// units wide, so a search window can begin or end between the halves of one.
/// That used to abort the process; such a window must simply not count as a match.
test "edits work on non-BMP text" {
  assert_eq(applied("a😀b", [repl("b", "c")]), "a😀c")
  assert_eq(applied("say 😀 now", [repl("😀", "🙂")]), "say 🙂 now")
  // The character after a pair is still found at its own offset.
  assert_eq(applied("😀x", [repl("x", "y")]), "😀y")
}

///|
/// A miss in text containing a pair is reported, not crashed on: every window in
/// the scan has to be rejected before the result is known.
test "a miss in non-BMP text is not found rather than fatal" {
  let error = edit_error("😀", [repl("nope", "x")])
  assert_true(error is NotFound(index=0, ..), msg="\{error}")
}

///|
/// An error message summarising a line of emoji clips at a character boundary:
/// the fixed offset of 60 lands inside a pair, and slicing there would abort
/// while reporting a failure.
test "summarizing a non-BMP line does not split a character" {
  let error = edit_error("x", [repl("a" + "😀".repeat(40) + "absent", "y")])
  let message = error.to_string()
  assert_true(message.contains("😀…"), msg=message)
}
