///|
/// Tool declarations checked against upstream's.
///
/// Descriptions and schemas are prompt text, so a drift here changes how the
/// model behaves rather than merely failing a build.

///|
test "tool declarations match the recorded ones" {
  for entry in upstream_tool_fixtures {
    let (name, upstream_name, description, parameters_text) = entry
    let tool = match builtin_tool(name) {
      Some(t) => t
      None => fail("missing tool: \{name}")
    }
    assert_eq(
      tool.description,
      description,
      msg="description of \{name} (upstream: \{upstream_name})",
    )
    assert_eq(
      tool.parameters,
      @json.parse(parameters_text),
      msg="parameters of \{name} (upstream: \{upstream_name})",
    )
  }
}

///|
/// Every tool upstream has must exist here with the same declaration. The reverse is
/// not required: `note` is this project's addition.
test "every upstream tool has a counterpart here" {
  let names : Array[String] = builtin_tools().map(t => t.name)
  for entry in upstream_tool_fixtures {
    let (name, _, _, _) = entry
    assert_true(names.contains(name), msg="missing tool: \{name}")
  }
  // `script` is this project's addition as well, alongside `note`.
  assert_eq(names.join(","), "bash,read,write,edit,glob,grep,note,script")
}

// ── Which tools are read-only ──────────────────────────────────────────────

///|
/// The read-only tools may overlap; the ones that touch the world may not.
///
/// Kept as a fact about each tool rather than as a scheduler's input: nothing consults it today (there
/// is no scheduler — see `run_tools`), and a classification that is *true* is worth declaring even
/// while nothing reads it. What was not worth keeping is the module that claimed to schedule on it.
test "only read-only tools are concurrency safe" {
  for tool in builtin_tools() {
    let expected = match tool.name {
      // Recording a note touches nothing outside the session.
      "read" | "glob" | "grep" | "note" => Concurrency::Safe
      _ => Concurrency::Exclusive
    }
    assert_eq(tool.concurrency, expected, msg="concurrency of \{tool.name}")
  }
}
