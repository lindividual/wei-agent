///|
/// Glob matching for the `glob` tool.
///
/// Supports what the tool description promises: `*` within a path segment, `**`
/// across segments, and `?` for one character. Matching is done on path segments
/// rather than the whole string, because `*` not crossing a separator is the
/// distinction that makes a glob a glob.

///|
/// Match `pattern` against one path segment, where `*` and `?` do not cross a
/// separator.
///
/// A backtracking scan rather than a translation to a regular expression: the
/// patterns here are short and the only special characters are `*` and `?`.
fn match_segment(pattern : StringView, text : StringView) -> Bool {
  let mut p = 0
  let mut t = 0
  // Position to resume from when a `*` turns out to have consumed too little.
  let mut star = -1
  let mut star_text = 0
  while t < text.length() {
    if p < pattern.length() && (pattern[p] == '?' || pattern[p] == text[t]) {
      p += 1
      t += 1
    } else if p < pattern.length() && pattern[p] == '*' {
      star = p
      star_text = t
      p += 1
    } else if star >= 0 {
      // Backtrack: let the last `*` swallow one more character.
      p = star + 1
      star_text += 1
      t = star_text
    } else {
      return false
    }
  }
  while p < pattern.length() && pattern[p] == '*' {
    p += 1
  }
  p == pattern.length()
}

///|
fn split_segments(path : StringView) -> Array[String] {
  let out : Array[String] = []
  for part in path.split("/") {
    if part != "" {
      out.push(part.to_owned())
    }
  }
  out
}

///|
/// Match a whole path against a pattern that may contain `**`.
///
/// `**` matches any number of segments, including none, so `src/**/*.ts` matches
/// `src/a.ts`. It only has that meaning as a whole segment: `a**b` is treated as
/// a segment pattern with two stars, which is what a shell does.
pub fn glob_match(pattern : String, path : String) -> Bool {
  let pat = split_segments(pattern[:])
  let parts = split_segments(path[:])
  match_segments(pat, 0, parts, 0)
}

///|
fn match_segments(
  pattern : Array[String],
  pi : Int,
  path : Array[String],
  si : Int,
) -> Bool {
  if pi == pattern.length() {
    return si == path.length()
  }
  if pattern[pi] == "**" {
    // Zero segments, or consume one and try again.
    if match_segments(pattern, pi + 1, path, si) {
      return true
    }
    if si < path.length() {
      return match_segments(pattern, pi, path, si + 1)
    }
    return false
  }
  if si == path.length() {
    return false
  }
  if !match_segment(pattern[pi][:], path[si][:]) {
    return false
  }
  match_segments(pattern, pi + 1, path, si + 1)
}

///|
/// Whether a path should be skipped when walking.
///
/// Directory names that are never worth searching, matching what an editor's file
/// finder hides. Not `.gitignore`, which would need the ignore grammar; these are
/// the ones whose absence is worse than their occasional wrongness.
pub fn is_ignored_dir(name : String) -> Bool {
  match name {
    ".git"
    | "node_modules"
    | ".mooncakes"
    | "target"
    | "_build"
    | "dist"
    | ".venv"
    | "__pycache" => true
    _ => false
  }
}
