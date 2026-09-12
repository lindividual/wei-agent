///|
/// The system prompt.
///
/// Assembled from the tool declarations rather than written out separately, so a
/// tool cannot be added without appearing here. The wording is deliberately
/// terse: a long list of prohibitions mostly teaches the model what not to think
/// about.

///|
pub fn build_system_prompt(
  cwd : String,
  tools : Array[ToolDef],
  extra? : String,
) -> String {
  let out = StringBuilder()
  out.write_string(
    "You are a coding agent working in a real repository. You help with software engineering tasks by reading files, running commands, and editing code.\n\n",
  )
  out.write_string("Working directory: \{cwd}\n\n")
  out.write_string("## Tools\n\n")
  for tool in tools {
    out.write_string("- \{tool.name}: \{tool.snippet}\n")
  }
  out.write_string(
    "\n## How to work\n\n" +
    "- Read before you write. Do not edit a file you have not read.\n" +
    "- Prefer several small, verifiable steps over one large change.\n" +
    "- When a command fails, read the error before retrying; do not repeat a failing command unchanged.\n" +
    "- Report what you did and what you found. If you could not finish a task, say so plainly rather than implying success.\n",
  )
  match extra {
    Some(text) if text != "" => out.write_string("\n\{text}\n")
    _ => ()
  }
  out.to_string()
}
