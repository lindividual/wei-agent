///|
/// The workspace's `AGENTS.md` against a real filesystem.
///
/// What the pure tests cannot check is the part that only exists on disk: that the file is found
/// at the workspace root and nowhere else, and that every way of not having one — missing, a
/// directory, a name that is a symlink to nothing — reads as the same empty answer rather than
/// raising. Scratch directories live under `_build`, which the repository already ignores.

///|
async fn agents_scratch() -> String {
  // Unique rather than merely distinct: tests run concurrently, and two creating a shared parent
  // would race between the existence check and the `mkdir`.
  let dir = "_build/agents_test/\{@core.new_entry_id()}"
  make_dirs(dir)
  dir
}

///|
async test "the file at the workspace root is read as it is on disk" {
  let cwd = agents_scratch()
  write_text("\{cwd}/AGENTS.md", "# House rules\n\nRun moon test.\n")
  assert_eq(workspace_agents_md(cwd), "# House rules\n\nRun moon test.\n")
}

///|
async test "a workspace without the file reads as empty rather than failing" {
  let cwd = agents_scratch()
  assert_eq(workspace_agents_md(cwd), "")
  // A name that exists but is not a file is not instructions either. `open` on a directory can
  // succeed, which is why the check is not merely `exists`.
  make_dirs("\{cwd}/AGENTS.md")
  assert_eq(workspace_agents_md(cwd), "")
  // And a path that is not there at all, which is what an empty cwd would become.
  assert_eq(workspace_agents_md(""), "")
  assert_eq(workspace_agents_md("\{cwd}/no-such-dir"), "")
}

///|
/// Only the root of the workspace, and deliberately not the directories above it: a file in a home
/// directory is somebody's notes about their machine, and reading it would make a prompt depend on
/// where a checkout happens to sit.
async test "a file in a parent directory does not apply" {
  let outer = agents_scratch()
  let cwd = "\{outer}/project/sub"
  make_dirs(cwd)
  write_text("\{outer}/AGENTS.md", "outer instructions")
  assert_eq(workspace_agents_md(cwd), "")
  // The subdirectory's own file is the one that counts, and only for that directory.
  write_text("\{cwd}/AGENTS.md", "inner instructions")
  assert_eq(workspace_agents_md(cwd), "inner instructions")
  assert_eq(workspace_agents_md(outer), "outer instructions")
}

///|
/// A file larger than the cap is truncated rather than read whole, so a stray multi-megabyte file
/// cannot become a prompt. The read is lossy as well as bounded, so this cannot raise.
async test "an oversized file is cut off at the cap" {
  let cwd = agents_scratch()
  let big = StringBuilder()
  // Comfortably past the 256 KiB cap, and nothing that can be confused with an encoding problem.
  for _ in 0..<8000 {
    big.write_string("the quick brown fox jumps over the lazy dog\n")
  }
  write_text("\{cwd}/AGENTS.md", big.to_string())
  let read = workspace_agents_md(cwd)
  let whole = big.to_string()
  assert_true(read != "", msg="a big file is still read")
  assert_true(read.length() < whole.length(), msg="it is cut off")
  assert_true(read.has_prefix("the quick brown fox"), msg=read[:40])
}
