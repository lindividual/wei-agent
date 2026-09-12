///|
/// JSON Schema validation for tool arguments.
///
/// The schemas under test are the real ones from `tools.mbt`, so a schema change
/// that breaks validation shows up here.

///|
fn schema_of(text : String) -> Json raise {
  @json.parse(text)
}

///|
fn errors_for(schema : Json, value : Json) -> Array[String] {
  validate_schema(schema, value, "")
}

///|
test "a well-formed call passes" {
  let tool = builtin_tool("read").unwrap()
  let errors = errors_for(
    tool.parameters,
    @json.parse("{\"path\":\"src/a.ts\",\"limit\":10}"),
  )
  assert_eq(errors.length(), 0)
}

///|
/// Optional properties are exactly that: omitting them is not a fault.
test "omitted optional properties are fine" {
  let tool = builtin_tool("grep").unwrap()
  assert_eq(
    errors_for(tool.parameters, @json.parse("{\"pattern\":\"foo\"}")).length(),
    0,
  )
}

///|
test "a missing required property is reported with its path" {
  let tool = builtin_tool("read").unwrap()
  let errors = errors_for(tool.parameters, @json.parse("{}"))
  assert_eq(errors.length(), 1)
  assert_true(errors[0].contains("path"), msg=errors[0])
  assert_true(errors[0].contains("required"), msg=errors[0])
}

///|
test "a wrongly typed property names both types" {
  let tool = builtin_tool("read").unwrap()
  let errors = errors_for(tool.parameters, @json.parse("{\"path\":42}"))
  assert_eq(errors.length(), 1)
  assert_true(errors[0].contains("string"), msg=errors[0])
  assert_true(errors[0].contains("number"), msg=errors[0])
}

///|
/// Errors inside an array element carry an index, so the model can tell which
/// edit was wrong rather than being told one of them is.
test "nested errors carry an index path" {
  let tool = builtin_tool("edit").unwrap()
  let errors = errors_for(
    tool.parameters,
    @json.parse(
      "{\"path\":\"a.ts\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"},{\"oldText\":\"c\"}]}",
    ),
  )
  assert_eq(errors.length(), 1)
  assert_true(errors[0].contains("edits[1]"), msg=errors[0])
  assert_true(errors[0].contains("newText"), msg=errors[0])
}

///|
test "a non-object argument list is rejected" {
  let tool = builtin_tool("bash").unwrap()
  let errors = errors_for(tool.parameters, Json::string("rm -rf /"))
  assert_eq(errors.length(), 1)
  assert_true(errors[0].contains("object"), msg=errors[0])
}

///|
/// Several faults are all reported, not just the first, so one round trip can
/// correct everything.
test "multiple faults are collected" {
  let tool = builtin_tool("read").unwrap()
  let errors = errors_for(tool.parameters, @json.parse("{\"limit\":\"lots\"}"))
  // missing path, and limit is a string rather than a number
  assert_eq(errors.length(), 2)
}

// ── The schema rules themselves ────────────────────────────────────────────

///|
test "integer rejects a fractional number" {
  let schema = schema_of("{\"type\":\"integer\"}")
  assert_eq(errors_for(schema, @json.parse("3")).length(), 0)
  assert_eq(errors_for(schema, @json.parse("3.5")).length(), 1)
}

///|
/// JSON has one number type, so `3.0` is an integer by value even though it was
/// written with a decimal point.
test "integer accepts a whole-valued float" {
  let schema = schema_of("{\"type\":\"integer\"}")
  assert_eq(errors_for(schema, @json.parse("3.0")).length(), 0)
}

///|
test "the union type form is supported" {
  let schema = schema_of("{\"type\":[\"string\",\"null\"]}")
  assert_eq(errors_for(schema, @json.parse("\"x\"")).length(), 0)
  assert_eq(errors_for(schema, @json.parse("null")).length(), 0)
  assert_eq(errors_for(schema, @json.parse("1")).length(), 1)
}

///|
test "enum constrains the value" {
  let schema = schema_of("{\"enum\":[\"low\",\"high\"]}")
  assert_eq(errors_for(schema, @json.parse("\"low\"")).length(), 0)
  let errors = errors_for(schema, @json.parse("\"medium\""))
  assert_eq(errors.length(), 1)
  assert_true(errors[0].contains("allowed"), msg=errors[0])
}

///|
test "array items are validated" {
  let schema = schema_of("{\"type\":\"array\",\"items\":{\"type\":\"number\"}}")
  assert_eq(errors_for(schema, @json.parse("[1,2,3]")).length(), 0)
  let errors = errors_for(schema, @json.parse("[1,\"two\"]"))
  assert_eq(errors.length(), 1)
  assert_true(errors[0].contains("[1]"), msg=errors[0])
}

///|
/// `additionalProperties: false` is honoured when present, but absent means
/// permissive — which is how pi's own tool schemas are written.
test "additional properties are only rejected when the schema says so" {
  let strict = schema_of(
    "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"additionalProperties\":false}",
  )
  let errors = errors_for(strict, @json.parse("{\"a\":\"x\",\"b\":1}"))
  assert_eq(errors.length(), 1)
  assert_true(errors[0].contains("unknown"), msg=errors[0])

  let permissive = schema_of(
    "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}}}",
  )
  assert_eq(
    errors_for(permissive, @json.parse("{\"a\":\"x\",\"b\":1}")).length(),
    0,
  )
}
