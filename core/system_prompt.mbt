///|
/// The system prompt.
///
/// Assembled from the tool declarations rather than written out separately, so a
/// tool cannot be added without appearing here. The wording is deliberately
/// terse: a long list of prohibitions mostly teaches the model what not to think
/// about.
///
/// The three conversation-derived sections are **parameters, not a list a caller assembles**.
/// That is a correction: this used to take `sections : Array[String]`, and the four front ends
/// each built their own array. Three of them added the skill catalog and the tool-change notice;
/// the native macOS shell — the main front end — added neither, while its own comment said the
/// catalog was in the prompt. Nothing failed, because a missing section is not an error: the
/// model simply never learned that skills exist. Taking the inputs instead of the result makes
/// that omission unrepresentable, and fixes the section order in one place rather than in four.
///
/// An empty input contributes no bytes at all, which is what keeps a workspace with no
/// `AGENTS.md`, no skills and no mode change sending exactly the prompt it sent before these
/// sections existed — a section that rendered its own empty heading would invalidate the prefix
/// cache of every existing session.

///|
pub fn build_system_prompt(
  cwd : String,
  tools : Array[ToolDef],
  mode? : ToolMode = Tools,
  /// The workspace's own instructions (`AGENTS.md`, or the fallback from settings).
  instructions? : String = "",
  /// Every skill this turn may use. Empty renders no catalog, not an empty one.
  skills? : Array[Skill] = [],
  /// Tools that earlier calls in this conversation used and this turn does not carry.
  stale_tools? : Array[String] = [],
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
  out.write_string(how_to_work(mode))
  // The order is deliberate and belongs here rather than to each caller. What the workspace says
  // goes first because it is the most specific authority on how to work; the catalog next because
  // it is the model's map of what it can read; the change notice last because it is the one thing
  // in the prompt that became true mid-conversation, and a reader comparing the prompt to the
  // request should find the two tool sets named where the change happened rather than buried.
  for
    text in [
      instructions,
      skill_catalog_prompt(skills),
      tool_change_prompt(stale_tools, tools),
    ] {
    if text != "" {
      out.write_string("\n\{text}\n")
    }
  }
  out.to_string()
}

///|
/// The half of the prompt that is not the tool list, and the half that has to follow the mode.
///
/// The tool list already says which tools exist, so the bullets below are not a second list — they
/// are what the model has to know that the declarations cannot say. In code mode that is the whole
/// of the difficulty: eight tools become two, and the file operations every other instruction
/// assumes have to be written as commands. A prompt that still said "for a single file, `read` is
/// cheaper" would be describing a tool that is not in the request, and the model would spend a call
/// learning that from an error.
fn how_to_work(mode : ToolMode) -> String {
  match mode {
    Tools =>
      "\n## How to work\n\n" +
      "- Read before you write. Do not edit a file you have not read.\n" +
      "- Prefer several small, verifiable steps over one large change.\n" +
      "- When a command fails, read the error before retrying; do not repeat a failing command unchanged.\n" +
      "- Reach for `script` when a step would otherwise be several reads, a grep across the repo, a\n" +
      "  loop or an aggregation over files, a command whose raw output is much larger than the part\n" +
      "  you need, or a program you would write just to change files: it runs a program and returns\n" +
      "  a digest instead of the raw output. Bundled scripts cover `moon check`, `moon test`, repo\n" +
      "  search and range reads. For a single file, `read` is cheaper.\n" +
      "- Report what you did and what you found. If you could not finish a task, say so plainly rather than implying success.\n"
    Code =>
      "\n## How to work\n\n" +
      "Everything you do, you do by writing a command. There is no file tool: reading is `cat` or\n" +
      "`sed -n`, searching is `grep -rn`, listing is `ls`, editing is `ed`-style or a `moonbit`\n" +
      "program that writes the file. Plan the command, not the step.\n\n" +
      "- Read before you write. Do not edit a file you have not read.\n" +
      "- Prefer one command that answers the question over several that each need another call: a\n" +
      "  pipeline, a loop, or a `moonbit` program that filters and aggregates. Only what a command\n" +
      "  prints reaches you, and the conversation pays for every byte of it.\n" +
      "- Narrow output in the command (`| tail -30`, `--stat`, `-q`) instead of printing a lot and\n" +
      "  reading it. The cap keeps the end of what was printed, so an un-narrowed dump loses the part\n" +
      "  you were looking for.\n" +
      "- Nothing is interactive. Pass the flags that fail instead of prompting (`-y`, `--no-pager`,\n" +
      "  `-batch`, `</dev/null`) and a timeout to anything that might not return.\n" +
      "- When a command fails, read the error before retrying; do not repeat a failing command unchanged.\n" +
      "- Report what you did and what you found. If you could not finish a task, say so plainly rather than implying success.\n"
  }
}
