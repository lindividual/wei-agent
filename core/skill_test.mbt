///|
/// Skill frontmatter parsing, and the catalog it produces.
///
/// The fixtures are shaped like real skills rather than minimal ones: a plain scalar, a quoted
/// one, and a block (`|`) are all forms that occur in the wild, and a parser that only handled
/// the simple case would silently drop the others.

///|
test "a plain frontmatter yields name and description" {
  let text = "---\nname: moonbit-proof\ndescription: Use when writing proof-carrying code.\n---\n\n# Body\n"
  let skill = parse_skill_header(text, "/skills/moonbit-proof/SKILL.md").unwrap()
  assert_eq(skill.name, "moonbit-proof")
  assert_eq(skill.description, "Use when writing proof-carrying code.")
  assert_eq(skill.path, "/skills/moonbit-proof/SKILL.md")
}

///|
test "a quoted description keeps its colons" {
  let text = "---\nname: moonbit-refactoring\ndescription: \"Refactor MoonBit code: shrink APIs, use views, keep tests green.\"\n---\n"
  let skill = parse_skill_header(text, "/s/x/SKILL.md").unwrap()
  assert_eq(
    skill.description,
    "Refactor MoonBit code: shrink APIs, use views, keep tests green.",
  )
}

///|
test "a block description folds onto one line" {
  // The form `kimi-webbridge` actually uses, including a blank line and a following key.
  let text = "---\nname: kimi-webbridge\ndescription: |\n  Control the real browser.\n\n  Use it for any webpage task.\nmetadata:\n  version: \"1.11.5\"\n---\n"
  let skill = parse_skill_header(text, "/s/kimi/SKILL.md").unwrap()
  assert_eq(
    skill.description,
    "Control the real browser. Use it for any webpage task.",
  )
}

///|
test "nested keys never stand in for a missing field" {
  let text = "---\nname: x\nmetadata:\n  description: not the real one\n  name: also not\n---\n"
  // The nested `description` is indented, so it is part of `metadata` and cannot supply the
  // missing top-level one. A parser that read it would invent a skill.
  assert_true(parse_skill_header(text, "/s/x/SKILL.md") is None)
}

///|
test "CRLF, a BOM, and a missing field are all handled" {
  let crlf = "---\r\nname: a\r\ndescription: b\r\n---\r\n"
  assert_eq(parse_skill_header(crlf, "/s/a/SKILL.md").unwrap().name, "a")
  let bom = "\u{FEFF}---\nname: a\ndescription: b\n---\n"
  assert_eq(parse_skill_header(bom, "/s/a/SKILL.md").unwrap().description, "b")
  // No description, no skill: a catalog entry the model cannot act on is worse than none.
  assert_true(
    parse_skill_header("---\nname: a\n---\n", "/s/a/SKILL.md") is None,
  )
}

///|
test "a non-skill file is rejected rather than guessed at" {
  assert_true(parse_skill_header("# Just a note\n", "/s/note.md") is None)
  // An opening fence that never closes is not frontmatter — reading the body as fields would
  // manufacture a description from prose.
  assert_true(
    parse_skill_header("---\nname: a\ndescription: b\n", "/s/a/SKILL.md")
    is None,
  )
}

///|
test "the catalog is empty when there are no skills" {
  // Byte-for-byte empty, so a machine with no skills sees the same system prompt as before
  // skills existed and pays no prompt-cache invalidation.
  assert_eq(skill_catalog_prompt([]), "")
}

///|
test "the catalog is sorted, deduplicated, and escaped" {
  let skills : Array[Skill] = [
    { name: "zeta", description: "last", path: "/s/z/SKILL.md", },
    { name: "alpha", description: "a <b> & \"c\"", path: "/s/a/SKILL.md", },
    // Same name as the first, discovered later: the later one wins, which is how a project
    // skill shadows the global one it is meant to replace.
    { name: "zeta", description: "shadowed", path: "/s/z2/SKILL.md", },
  ]
  let prompt = skill_catalog_prompt(skills)
  assert_true(prompt.contains("<name>alpha</name>"), msg=prompt)
  assert_true(prompt.contains("a &lt;b&gt; &amp; &quot;c&quot;"), msg=prompt)
  assert_true(prompt.contains("/s/z2/SKILL.md"), msg=prompt)
  assert_false(
    prompt.contains("shadowed</description>\n    <location>/s/z/SKILL.md"),
    msg=prompt,
  )
  // alpha sorts before zeta.
  let first = prompt.find("<name>alpha</name>").unwrap()
  let second = prompt.find("<name>zeta</name>").unwrap()
  assert_true(first < second, msg=prompt)
}
