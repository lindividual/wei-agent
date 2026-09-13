///|
/// Skill discovery against a real filesystem.
///
/// Roots are passed in rather than read from the environment, which is what makes these
/// deterministic: the same fixture builds the same catalog on any machine. Scratch directories
/// live under `_build`, which the repository already ignores, so a failed test leaves nothing
/// behind.

///|
async fn skill_scratch(name : String) -> String {
  // Unique rather than merely distinct: tests run concurrently, and two creating a shared
  // parent would race between the existence check and the `mkdir`.
  let dir = "_build/skill_test/\{name}-\{@core.new_entry_id()}"
  make_dirs(dir)
  dir
}

///|
async fn write_skill(dir : String, name : String, description : String) -> Unit {
  make_dirs("\{dir}/\{name}")
  write_text(
    "\{dir}/\{name}/SKILL.md",
    "---\nname: \{name}\ndescription: \{description}\n---\n\n# \{name}\n",
  )
}

///|
fn index_of(values : Array[String], wanted : String) -> Int? {
  for i, value in values {
    if value == wanted {
      return Some(i)
    }
  }
  None
}

///|
/// The roots are pi's, global first and project last, so a project skill shadows a global one.
test "skill roots put the project last" {
  let roots = skill_roots("/work/project/sub", "/home/u")
  assert_eq(roots[0], "/home/u/.pi/agent/skills")
  assert_eq(roots[1], "/home/u/.agents/skills")
  // The project root and its ancestors, nearest first.
  assert_true(
    roots.contains("/work/project/sub/.pi/skills"),
    msg=roots.join(", "),
  )
  assert_true(roots.contains("/work/project/.pi/skills"), msg=roots.join(", "))
  assert_true(roots.contains("/work/.agents/skills"), msg=roots.join(", "))
  // The last entry is the outermost project root, so it is `contains` order that matters for
  // shadowing, not the position of any single root.
  let project_at = index_of(roots, "/work/project/.pi/skills").unwrap()
  let global_at = index_of(roots, "/home/u/.pi/agent/skills").unwrap()
  assert_true(global_at < project_at, msg=roots.join(", "))
}

///|
async test "a bundle and a flat file are both discovered" {
  let home = skill_scratch("bundles")
  let cwd = skill_scratch("bundles-cwd")
  write_skill("\{home}/.pi/agent/skills", "alpha", "First skill.")
  write_text(
    "\{home}/.pi/agent/skills/beta.md",
    "---\nname: beta\ndescription: Second skill.\n---\n",
  )
  let found = discover_skills(cwd, home)
  let names : Array[String] = found.map(skill => skill.name)
  assert_true(names.contains("alpha"), msg=names.join(", "))
  assert_true(names.contains("beta"), msg=names.join(", "))
}

///|
async test "files that are not skills are skipped, and dotfiles are ignored" {
  let home = skill_scratch("skip")
  let cwd = skill_scratch("skip-cwd")
  let root = "\{home}/.pi/agent/skills"
  make_dirs(root)
  // A README with no frontmatter, a header missing a description, an unclosed fence, and a
  // hidden directory: none is a catalog entry.
  write_text("\{root}/README.md", "# Notes\n")
  write_text("\{root}/nodesc.md", "---\nname: nodesc\n---\n")
  write_text("\{root}/unclosed.md", "---\nname: unclosed\ndescription: x\n")
  make_dirs("\{root}/.hidden")
  write_text(
    "\{root}/.hidden/SKILL.md",
    "---\nname: hidden\ndescription: x\n---\n",
  )
  assert_eq(discover_skills(cwd, home).length(), 0)
}

///|
async test "a project skill shadows the global one of the same name" {
  let home = skill_scratch("shadow-home")
  let cwd = skill_scratch("shadow-cwd")
  write_skill("\{home}/.pi/agent/skills", "shared", "Global version.")
  write_skill("\{cwd}/.pi/skills", "shared", "Project version.")
  let found = discover_skills(cwd, home)
  // Both are discovered — the shadowing is `dedup_skills`'s job, and it keeps the last.
  assert_eq(found.length(), 2)
  let catalog = @core.skill_catalog_prompt(found)
  assert_true(catalog.contains("Project version."), msg=catalog)
  assert_false(catalog.contains("Global version."), msg=catalog)
}

///|
async test "a missing root is skipped rather than reported" {
  let home = skill_scratch("missing-home")
  let cwd = skill_scratch("missing-cwd")
  // Nothing was created under either root.
  assert_eq(discover_skills(cwd, home).length(), 0)
}
