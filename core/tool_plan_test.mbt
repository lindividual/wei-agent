///|
/// Tool-call scheduling: splitting a batch into exclusive barriers and
/// parallel runs.

///|
fn call(name : String, safe : Bool) -> ToolCallPlan {
  { name, is_concurrency_safe: safe, }
}

///|
test "an empty batch has no segments" {
  assert_eq(plan_segments([]).length(), 0)
  assert_eq(plan_shape([]), "")
}

///|
/// One call is its own segment either way, so a single-call turn — the
/// overwhelming majority — behaves identically under any scheme.
test "a single call plans identically" {
  assert_eq(plan_shape([call("bash", false)]), "E")
  assert_eq(plan_shape([call("read", true)]), "P")
}

///|
test "a run of safe calls forms one segment" {
  let calls = [call("read", true), call("glob", true), call("grep", true)]
  let segments = plan_segments(calls)
  assert_eq(segments.length(), 1)
  assert_true(segments[0] is Parallel(indices=[0, 1, 2]))
}

///|
test "exclusive calls each get their own segment" {
  let calls = [call("bash", false), call("write", false)]
  let segments = plan_segments(calls)
  assert_eq(segments.length(), 2)
  assert_true(segments[0] is Exclusive(index=0))
  assert_true(segments[1] is Exclusive(index=1))
}

///|
/// The case upstream handles badly: a safe call on either side of an exclusive one.
/// Here the two reads overlap and only the command runs alone.
test "safe calls are not serialized by a neighbouring exclusive call" {
  let calls = [call("read", true), call("bash", false), call("read", true)]
  assert_eq(plan_shape(calls), "PEP")
  let segments = plan_segments(calls)
  assert_eq(segments.length(), 3)
  assert_true(segments[0] is Parallel(indices=[0]))
  assert_true(segments[1] is Exclusive(index=1))
  assert_true(segments[2] is Parallel(indices=[2]))
}

///|
test "a mixed batch keeps every call exactly once, in order" {
  let calls = [
    call("read", true),
    call("read", true),
    call("bash", false),
    call("grep", true),
    call("edit", false),
    call("read", true),
  ]
  let segments = plan_segments(calls)
  assert_eq(plan_shape(calls), "PPEPEP")
  // Flatten and confirm coverage.
  let seen : Array[Int] = []
  for segment in segments {
    match segment {
      Exclusive(index~) => seen.push(index)
      Parallel(indices~) =>
        for i in indices {
          seen.push(i)
        }
    }
  }
  assert_eq(seen.length(), calls.length())
  for i in 0..<calls.length() {
    assert_eq(seen[i], i, msg="position \{i}")
  }
}

///|
/// A batch that starts exclusive ends with a barrier and nothing after it.
test "trailing exclusive calls close cleanly" {
  let calls = [call("read", true), call("bash", false)]
  assert_eq(plan_shape(calls), "PE")
}
