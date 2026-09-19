///|
/// The built-in tools.
///
/// A tool is a declaration: a name, a description the model reads, a JSON Schema
/// for its arguments, and how it may be scheduled. The bodies live in `platform/`
/// because they touch the filesystem and spawn processes.
///
/// The descriptions, parameter names, and required lists are copied from upstream's
/// definitions verbatim. They are prompt text that upstream has tuned, and matching them
/// means a model sees the same tool it would see there — as well as making the two
/// directly comparable.
///
/// Deliberately absent, unlike dsh: a mandatory output schema and a per-argument
/// concurrency callback. Both serve a plugin ecosystem — output schemas decouple
/// execution from rendering, per-argument safety lets a general `bash` be
/// parallelized when its command is read-only. With six fixed tools whose
/// read-only ones are read-only unconditionally, neither earns its keep.

///|
/// Whether a tool only reads, so that two calls to it could be in flight together.
///
/// **Declared but not consulted.** There is no scheduler: `run_tools` runs every call in the order the
/// model asked for, and this classification is not part of that decision (see `core/tool_test.mbt`).
/// It is here because it is a true fact about each tool — `read`, `glob` and `note` touch nothing
/// outside the session, and `bash`, `write`, `edit` and `script` do — and because whoever writes a
/// concurrent executor will want it. What is *not* here is a module that claims to schedule on it.
pub(all) enum Concurrency {
  /// May run alongside other safe calls.
  Safe
  /// Runs alone; anything before it must finish and anything after it must wait.
  Exclusive
} derive(Eq, Debug)

///|
pub(all) struct ToolDef {
  name : String
  description : String
  /// JSON Schema for the arguments, as sent to the model.
  parameters : Json
  concurrency : Concurrency
  /// Cooperative timeout in milliseconds; `None` means no limit.
  timeout_ms : Int?
  /// One-line summary for the system prompt.
  snippet : String
} derive(Eq, Debug)

// ── Schema helpers ─────────────────────────────────────────────────────────

///|
fn json_obj(pairs : Array[(String, Json)]) -> Json {
  Json::object(Map(pairs))
}

///|
fn str_prop(description : String) -> Json {
  json_obj([
    ("type", Json::string("string")),
    ("description", Json::string(description)),
  ])
}

///|
fn num_prop(description : String) -> Json {
  json_obj([
    ("type", Json::string("number")),
    ("description", Json::string(description)),
  ])
}

///|
fn bool_prop(description : String) -> Json {
  json_obj([
    ("type", Json::string("boolean")),
    ("description", Json::string(description)),
  ])
}

///|
fn array_prop(items : Json, description : String) -> Json {
  json_obj([
    ("type", Json::string("array")),
    ("items", items),
    ("description", Json::string(description)),
  ])
}

///|
/// An object schema.
///
/// No `additionalProperties: false`: upstream does not set it either, and rejecting a
/// parameter the model was never told about produces a confusing error rather
/// than a correction.
fn object_schema(
  properties : Array[(String, Json)],
  required : Array[String],
) -> Json {
  json_obj([
    ("type", Json::string("object")),
    ("required", Json::array(required.map(name => Json::string(name)))),
    ("properties", Json::object(Map(properties))),
  ])
}

///|
/// Output limits, matching upstream's so truncation behaves identically.
pub fn default_max_lines() -> Int {
  2000
}

///|
pub fn default_max_bytes() -> Int {
  50 * 1024
}

///|
pub fn grep_max_line_length() -> Int {
  500
}

// ── Tool definitions ───────────────────────────────────────────────────────

///|
fn bash_tool() -> ToolDef {
  {
    name: "bash",
    description: "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
    parameters: object_schema(
      [
        ("command", str_prop("Shell command to execute")),
        (
          "timeout",
          num_prop("Timeout in seconds (optional, no default timeout)"),
        ),
      ],
      ["command"],
    ),
    // A command can do anything, so it never overlaps another call.
    concurrency: Exclusive,
    timeout_ms: None,
    snippet: "Run a shell command",
  }
}

///|
fn read_tool() -> ToolDef {
  {
    name: "read",
    description: "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
    parameters: object_schema(
      [
        ("path", str_prop("Path to the file to read (relative or absolute)")),
        ("offset", num_prop("Line number to start reading from (1-indexed)")),
        ("limit", num_prop("Maximum number of lines to read")),
      ],
      ["path"],
    ),
    concurrency: Safe,
    timeout_ms: None,
    snippet: "Read a file",
  }
}

///|
fn write_tool() -> ToolDef {
  {
    name: "write",
    description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
    parameters: object_schema(
      [
        ("path", str_prop("Path to the file to write (relative or absolute)")),
        ("content", str_prop("Content to write to the file")),
      ],
      ["path", "content"],
    ),
    concurrency: Exclusive,
    timeout_ms: None,
    snippet: "Write a file",
  }
}

///|
fn edit_tool() -> ToolDef {
  let replace_edit = json_obj([
    ("type", Json::string("object")),
    (
      "required",
      Json::array([Json::string("oldText"), Json::string("newText")]),
    ),
    (
      "properties",
      json_obj([
        (
          "oldText",
          str_prop(
            "Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call.",
          ),
        ),
        ("newText", str_prop("Replacement text for this targeted edit.")),
      ]),
    ),
  ])
  {
    name: "edit",
    description: "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
    parameters: object_schema(
      [
        ("path", str_prop("Path to the file to edit (relative or absolute)")),
        (
          "edits",
          array_prop(
            replace_edit, "One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.",
          ),
        ),
      ],
      ["path", "edits"],
    ),
    concurrency: Exclusive,
    timeout_ms: None,
    snippet: "Edit a file by exact text replacement",
  }
}

///|
/// Named `glob` rather than upstream's `find`; the parameter schema is upstream's.
fn glob_tool() -> ToolDef {
  {
    name: "glob",
    description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or 50KB (whichever is hit first).",
    parameters: object_schema(
      [
        (
          "pattern",
          str_prop(
            "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'",
          ),
        ),
        (
          "path",
          str_prop("Directory to search in (default: current directory)"),
        ),
        ("limit", num_prop("Maximum number of results (default: 1000)")),
      ],
      ["pattern"],
    ),
    concurrency: Safe,
    timeout_ms: None,
    snippet: "Find files by glob pattern",
  }
}

///|
fn grep_tool() -> ToolDef {
  {
    name: "grep",
    description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects .gitignore. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars.",
    parameters: object_schema(
      [
        ("pattern", str_prop("Search pattern (regex or literal string)")),
        (
          "path",
          str_prop("Directory or file to search (default: current directory)"),
        ),
        (
          "glob",
          str_prop(
            "Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'",
          ),
        ),
        ("ignoreCase", bool_prop("Case-insensitive search (default: false)")),
        (
          "literal",
          bool_prop(
            "Treat pattern as literal string instead of regex (default: false)",
          ),
        ),
        (
          "context",
          num_prop(
            "Number of lines to show before and after each match (default: 0)",
          ),
        ),
        (
          "limit",
          num_prop("Maximum number of matches to return (default: 100)"),
        ),
      ],
      ["pattern"],
    ),
    concurrency: Safe,
    timeout_ms: None,
    snippet: "Search file contents",
  }
}

///|
/// Record a fact the agent wants kept verbatim across compaction.
///
/// This one has no counterpart in upstream, which relies on the summarization prompt
/// asking the model to preserve paths and decisions. That is a request; a note is
/// the model choosing to make something durable, and `facts.mbt` appends notes to
/// every summary without passing them through the model again.
fn note_tool() -> ToolDef {
  {
    name: "note",
    description: "Record a fact that must survive context compaction: a file path, a constraint the user stated, a decision and its reason, or anything expensive to rediscover. Notes are kept verbatim when older history is summarized, so record durable facts rather than narration.",
    parameters: object_schema(
      [
        (
          "text",
          str_prop(
            "The fact to record, stated so it stands on its own without the surrounding conversation.",
          ),
        ),
      ],
      ["text"],
    ),
    // It records a thought; it does not touch the world.
    concurrency: Safe,
    timeout_ms: None,
    snippet: "Record a fact that survives compaction",
  }
}

///|
/// Every built-in tool, in the order they are presented.
pub fn builtin_tools() -> Array[ToolDef] {
  [
    bash_tool(),
    read_tool(),
    write_tool(),
    edit_tool(),
    glob_tool(),
    grep_tool(),
    note_tool(),
    script_tool(),
  ]
}

///|
/// Look up a tool by the name the model used.
pub fn builtin_tool(name : String) -> ToolDef? {
  for tool in builtin_tools() {
    if tool.name == name {
      return Some(tool)
    }
  }
  None
}
