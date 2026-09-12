///|
/// Glob matching for the file-finding tool.

///|
test "star does not cross a separator" {
  assert_true(glob_match("*.ts", "a.ts"))
  assert_false(glob_match("*.ts", "src/a.ts"))
  assert_true(glob_match("src/*.ts", "src/a.ts"))
  assert_false(glob_match("src/*.ts", "src/deep/a.ts"))
}

///|
/// `**` is the only thing that crosses a separator, and it matches zero segments
/// as well as many — otherwise `src/**/*.ts` would miss a file directly in `src`.
test "double star crosses separators and may match nothing" {
  assert_true(glob_match("**/*.ts", "a.ts"))
  assert_true(glob_match("**/*.ts", "src/a.ts"))
  assert_true(glob_match("**/*.ts", "src/deep/a.ts"))
  assert_true(glob_match("src/**/*.spec.ts", "src/a.spec.ts"))
  assert_true(glob_match("src/**/*.spec.ts", "src/x/y/a.spec.ts"))
  assert_false(glob_match("src/**/*.spec.ts", "lib/a.spec.ts"))
}

///|
test "question mark matches exactly one character" {
  assert_true(glob_match("a?c.ts", "abc.ts"))
  assert_false(glob_match("a?c.ts", "ac.ts"))
  assert_false(glob_match("a?c.ts", "abbc.ts"))
}

///|
test "literal patterns match themselves" {
  assert_true(glob_match("src/main.mbt", "src/main.mbt"))
  assert_false(glob_match("src/main.mbt", "src/other.mbt"))
}

///|
test "a trailing star is handled" {
  assert_true(glob_match("src/*", "src/a.ts"))
  assert_true(glob_match("*.ts", "a.ts"))
  assert_true(glob_match("a*", "a"))
}

///|
test "matching is anchored at both ends" {
  assert_false(glob_match("a.ts", "xa.ts"))
  assert_false(glob_match("a.ts", "a.tsx"))
}

///|
/// Build directories are never worth walking; the list matches what editors hide.
test "build directories are skipped" {
  assert_true(is_ignored_dir("node_modules"))
  assert_true(is_ignored_dir(".git"))
  assert_true(is_ignored_dir("_build"))
  assert_false(is_ignored_dir("src"))
}
