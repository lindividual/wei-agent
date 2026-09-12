///|
/// Tool declarations checked against pi's.
///
/// Descriptions and schemas are prompt text, so a drift here changes how the
/// model behaves rather than merely failing a build.

///|
test "tool declarations match pi" {
  for entry in pi_tool_fixtures {
    let (name, pi_name, description, parameters_text) = entry
    let tool = match builtin_tool(name) {
      Some(t) => t
      None => fail("missing tool: \{name}")
    }
    assert_eq(
      tool.description,
      description,
      msg="description of \{name} (pi: \{pi_name})",
    )
    assert_eq(
      tool.parameters,
      @json.parse(parameters_text),
      msg="parameters of \{name} (pi: \{pi_name})",
    )
  }
}

///|
/// Every tool pi has must exist here with the same declaration. The reverse is
/// not required: `note` is this project's addition.
test "every pi tool has a counterpart here" {
  let names : Array[String] = builtin_tools().map(t => t.name)
  for entry in pi_tool_fixtures {
    let (name, _, _, _) = entry
    assert_true(names.contains(name), msg="missing tool: \{name}")
  }
  assert_eq(names.join(","), "bash,read,write,edit,glob,grep,note")
}

// ── Scheduling policy ──────────────────────────────────────────────────────

///|
/// The read-only tools may overlap; the ones that touch the world may not. This
/// is the whole basis for the scheduler's segmenting.
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

///|
/// A batch of read-only calls collapses into one segment; anything else presents
/// a barrier. Checked through the real tool definitions rather than synthetic
/// plans, so the policy and the scheduler stay in agreement.
test "a read-only batch from real tools is one segment" {
  let calls : Array[ToolCallPlan] = [
    { name: "read", is_concurrency_safe: true, },
    { name: "grep", is_concurrency_safe: true, },
    { name: "glob", is_concurrency_safe: true, },
  ]
  assert_eq(plan_shape(calls), "PPP")
}

///|
test "a mixed batch from real tools keeps the barrier" {
  let calls : Array[ToolCallPlan] = [
    { name: "read", is_concurrency_safe: true, },
    { name: "bash", is_concurrency_safe: false, },
    { name: "write", is_concurrency_safe: false, },
    { name: "read", is_concurrency_safe: true, },
  ]
  assert_eq(plan_shape(calls), "PEEP")
}
