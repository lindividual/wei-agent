///|
/// JSON Schema validation for tool arguments.
///
/// A subset, covering what tool parameters actually use: `type` (including the
/// `["string","null"]` union form), `properties`, `required`, `items`, `enum`,
/// and `additionalProperties: false`. `$ref`, `allOf`, and conditionals are not
/// implemented because tools declare their own parameters and never need them.
///
/// Errors are collected rather than raised: a bad argument list should come back
/// to the model as a readable correction, not abort the turn.

///|
fn schema_type_name(value : Json) -> String {
  match value {
    Null => "null"
    True | False => "boolean"
    Number(_, ..) => "number"
    String(_) => "string"
    Array(_) => "array"
    Object(_) => "object"
  }
}

///|
fn matches_type(expected : String, value : Json) -> Bool {
  match expected {
    "object" => value is Object(_)
    "array" => value is Array(_)
    "string" => value is String(_)
    "boolean" => value is True || value is False
    "number" => value is Number(_, ..)
    // An integer is a number with no fractional part. JSON does not distinguish
    // the two, so the check has to look at the value.
    "integer" =>
      match value {
        Number(n, ..) => n == n.floor()
        _ => false
      }
    "null" => value is Null
    _ => true
  }
}

///|
/// Validate `value` against `schema`, appending a message per violation.
///
/// `path` is the location used in messages, e.g. `command` or `edits[2].newText`.
pub fn validate_schema(
  schema : Json,
  value : Json,
  path : String,
) -> Array[String] {
  let errors : Array[String] = []
  validate_into(schema, value, path, errors)
  errors
}

///|
fn validate_into(
  schema : Json,
  value : Json,
  path : String,
  errors : Array[String],
) -> Unit {
  let location = if path == "" { "(root)" } else { path }

  match opt(schema, "type") {
    Some(String(expected)) =>
      if !matches_type(expected, value) {
        errors.push(
          "\{location}: expected \{expected}, got \{schema_type_name(value)}",
        )
        return
      }
    Some(Array(alternatives)) => {
      let matched = alternatives.any(alt => {
        match alt {
          String(name) => matches_type(name, value)
          _ => true
        }
      })
      if !matched {
        let names : Array[String] = []
        for alt in alternatives {
          match alt {
            String(name) => names.push(name)
            _ => ()
          }
        }
        errors.push(
          "\{location}: expected one of [\{names.join(", ")}], got \{schema_type_name(value)}",
        )
        return
      }
    }
    _ => ()
  }

  match opt(schema, "enum") {
    Some(Array(allowed)) =>
      if !allowed.any(candidate => candidate == value) {
        errors.push("\{location}: value is not one of the allowed options")
      }
    _ => ()
  }

  match value {
    Object(fields) => {
      match opt(schema, "properties") {
        Some(Object(properties)) =>
          for entry in properties {
            let (name, property_schema) = entry
            let child = if path == "" { name } else { "\{path}.\{name}" }
            match fields.get(name) {
              Some(child_value) =>
                validate_into(property_schema, child_value, child, errors)
              None => ()
            }
          }
        _ => ()
      }
      for entry in fields {
        let (name, _) = entry
        let child = if path == "" { name } else { "\{path}.\{name}" }
        if child_should_reject(schema, name, fields) {
          errors.push("\{child}: unknown property")
        }
      }
      match opt(schema, "required") {
        Some(Array(names)) =>
          for name_json in names {
            match name_json {
              String(name) =>
                if fields.get(name) is None {
                  let child = if path == "" { name } else { "\{path}.\{name}" }
                  errors.push("\{child}: required property is missing")
                }
              _ => ()
            }
          }
        _ => ()
      }
    }
    Array(items) =>
      match opt(schema, "items") {
        Some(item_schema) =>
          for i in 0..<items.length() {
            validate_into(item_schema, items[i], "\{path}[\{i}]", errors)
          }
        _ => ()
      }
    _ => ()
  }
}

///|
/// Whether an unlisted property should be reported. Only `additionalProperties:
/// false` forbids extras; the default is permissive.
fn child_should_reject(
  schema : Json,
  name : String,
  fields : Map[String, Json],
) -> Bool {
  ignore(fields)
  if opt(schema, "additionalProperties") is Some(False) {
    match opt(schema, "properties") {
      Some(Object(properties)) => properties.get(name) is None
      _ => true
    }
  } else {
    false
  }
}
