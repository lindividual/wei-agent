///|
/// The workspace's own `AGENTS.md`.
///
/// The decisions — which of the two instruction sources wins, and what the prompt does with the
/// result — are in `core/settings.mbt`. This file only knows where to look and how to read, which
/// is the same split as skills: pure rules in `core`, the filesystem here.
///
/// One file, at the root of the workspace, and no walk upward. A walk would make the answer depend
/// on where the checkout happens to sit — `/Users/me/AGENTS.md` is somebody's notes about their
/// machine, not instructions for this repository — and it would make the size of the prompt depend
/// on a directory the reader is not looking at.

///|
/// How much of the file to read.
///
/// A cap rather than a whole-file read, for the same reason the settings file has one: this is a
/// hand-editable file in a user-controlled directory, and the prompt is not the place a stray
/// multi-megabyte file should be discovered. Larger than the settings cap because this is prose
/// written for a model, and a real one runs to a few kilobytes of conventions and commands.
fn agents_md_max_bytes() -> Int {
  262144
}

///|
/// The workspace's instructions, or empty when it has none.
///
/// Missing, unreadable and not-actually-a-file are all the empty string, because each of them means
/// the same thing to a turn: there is nothing here, use the fallback. The read is bounded and lossy
/// as well, so this cannot raise.
///
/// Not cached. It is read once per turn, and the file is exactly the thing a reader edits while
/// looking at the agent — a cache would be a way to make their edit not take effect, which is the
/// one failure this feature would be blamed for.
pub async fn workspace_agents_md(cwd : String) -> String {
  if cwd == "" {
    return ""
  }
  let path = "\{cwd}/AGENTS.md"
  if !is_file(path) {
    return ""
  }
  read_prefix(path, agents_md_max_bytes())
}
