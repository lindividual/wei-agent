///|
/// The rule a block that is still growing is rendered by: how much of it can be kept, and how much
/// has to be re-parsed.
///
/// The tests are the cases the boundary has to get right, and they are written as "where does the
/// prefix end" rather than as "which character", because what the shell does with the answer is
/// `text[:boundary]` — the prefix it can stop re-parsing.

///|
/// The prefix, as a string, so a failure prints the markdown rather than an index.
fn prefix(text : String) -> String {
  text[:safe_boundary(text)].to_owned()
}

///|
/// Nothing has finished yet: no blank line, so every parse is of the whole thing.
test "a paragraph with no blank line has no boundary" {
  assert_eq(safe_boundary("one long paragraph that is still arriving"), 0)
}

///|
/// The everyday case, and the one that pays for the whole rule: the finished paragraph is never
/// parsed again, and the growing one is one line.
test "the last blank line is the boundary" {
  let text = "first paragraph\n\nsecond paragraph"
  assert_eq(prefix(text), "first paragraph\n\n")
}

///|
test "everything before the last blank line is the prefix" {
  let text = "one\n\ntwo\n\nthree"
  assert_eq(prefix(text), "one\n\ntwo\n\n")
}

///|
/// A blank line inside a fence is a blank line in a *code block*, not between blocks: cutting there
/// would show the reader two code blocks where the model wrote one, and the copy button would copy
/// half of it.
test "a blank line inside a fence is not a boundary" {
  let text = "```\na\n\nb\n```\n\nafter"
  assert_eq(prefix(text), "```\na\n\nb\n```\n\n")
}

///|
/// The fence is still open, so nothing after its blank line is a boundary either.
test "a blank line after an unclosed fence is not a boundary" {
  assert_eq(safe_boundary("```\na\n\nb"), 0)
}

///|
/// Four backticks are closed by four, not by three — the rule is the run length, and getting it
/// wrong here is what would cut a document at a line the reader sees as part of the code.
test "a longer fence is closed by a run at least as long" {
  let text = "````\ncode with ``` in it\n````\n\nafter"
  assert_eq(prefix(text), "````\ncode with ``` in it\n````\n\n")
  // And the shorter closer does not close it.
  assert_eq(safe_boundary("````\nstill open\n```\n\nafter"), 0)
}

///|
test "a tilde fence is a fence" {
  let text = "~~~\na\n\nb\n~~~\n\nafter"
  assert_eq(prefix(text), "~~~\na\n\nb\n~~~\n\n")
}

///|
/// An indented code block is not a fence: four spaces before a run of backticks is a code block whose
/// contents are markdown-shaped text, and treating it as a fence would swallow the rest of the
/// document.
test "an indented backtick run does not open a fence" {
  let text = "    ```\ntext\n\nafter"
  assert_eq(prefix(text), "    ```\ntext\n\n")
}

///|
/// A fence is the run plus an optional **info string** — ```moonbit opens a fence whose language is
/// moonbit — so a line that starts with three backticks is a fence even when text follows them. What
/// is *not* a fence is a run shorter than three: two backticks are inline code, and the blank line
/// under them is a real boundary.
test "a fence with an info string is still a fence" {
  assert_eq(safe_boundary("```js\nlet a = 1\n\nafter"), 0)
  assert_eq(prefix("``two``\n\nnext"), "``two``\n\n")
}

///|
/// A document that ends on a blank line is finished: the boundary is its end, so the next parse has
/// nothing to re-parse at all.
test "a document ending in a blank line is fully finished" {
  let text = "done\n\n"
  assert_eq(safe_boundary(text), text.length())
}

///|
test "a blank line with spaces on it is still a blank line" {
  let text = "done\n   \nnext"
  assert_eq(prefix(text), "done\n   \n")
}

///|
/// The boundary is a **byte** index into the string it came from, which is the one thing about it
/// that can be wrong in a way the tests above would not see: reasoning is full of emoji and CJK, and
/// an index counted in characters cuts the prefix in the middle of a character.
test "the boundary is an index into the string, not into its characters" {
  let text = "🎉 done\n\nstill going 🎉"
  let boundary = safe_boundary(text)
  assert_eq(text[:boundary].to_owned(), "🎉 done\n\n")
}

///|
/// A rule and a table separator are single lines: they cannot be a boundary by themselves, because
/// the line that makes them a rule (or a table) is the line *before* them.
test "a rule is not a boundary" {
  assert_eq(safe_boundary("text\n---\nmore"), 0)
}

///|
/// The case the rule admits to being wrong about, written down so that a change in it is a decision
/// rather than a surprise: a list interrupted by a blank line is one **loose** list in the whole
/// document and two **tight** lists either side of the boundary. The items and their order survive,
/// which is what makes the distortion affordable — a reader sees a little more or less space between
/// items while the model is still writing them.
test "a blank line between list items is a boundary, and the items survive" {
  let text = "- one\n\n- two"
  assert_eq(prefix(text), "- one\n\n")
  let (head, tail) = split(text)
  assert_eq(all_text(head), "one")
  assert_eq(all_text(tail), "two")
  // The distortion itself: two blocks rather than one, with the same words in them.
  assert_eq(head.length() + tail.length(), 2)
  assert_eq(all_text(parse(text)), "onetwo")
}

///|
/// Every piece of text in a parse, in order — the list case above is about which words survived, and
/// a list block's words are one level down from where a paragraph's are.
fn all_text(blocks : Array[Block]) -> String {
  let out = StringBuilder()
  for block in blocks {
    match block {
      Paragraph(spans) | Heading(_, spans) =>
        out.write_string(spans_text(spans))
      Bullets(items) | Numbers(_, items) =>
        for item in items {
          out.write_string(all_text(item))
        }
      Quote(inner) => out.write_string(all_text(inner))
      Code(_, text) => out.write_string(text)
      Rule => ()
      Table(_, _, _) => ()
    }
  }
  out.to_string()
}

///|
fn spans_text(spans : Array[Span]) -> String {
  spans
  .map(fn(span) {
    match span {
      Text(text) | Code(text) => text
      Emph(inner) | Strong(inner) | Strike(inner) => spans_text(inner)
      Link(_, inner) => spans_text(inner)
      Image(_, alt) => alt
    }
  })
  .join("")
}

///|
/// One paragraph, split at the boundary, is the same paragraph — the property the whole rule rests
/// on. A table is the case that would break it if the separator line were treated as a boundary.
test "parsing the prefix then the tail agrees with parsing the whole" {
  let text = "## Heading\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\ntail paragraph"
  let boundary = safe_boundary(text)
  let whole = parse(text)
  let joined = parse(text[:boundary].to_owned()) +
    parse(text[boundary:].to_owned())
  assert_eq(joined, whole)
}

///|
/// The two halves of a text at its boundary.
fn split(text : String) -> (Array[Block], Array[Block]) {
  let at = safe_boundary(text)
  (parse(text[:at].to_owned()), parse(text[at:].to_owned()))
}

///|
/// The diff is what keeps a finished block from crossing the wire twice: the host already has the
/// leading blocks, and only the tail is replaced.
test "a diff counts the blocks that have not changed" {
  let one = parse("a\n\nb")
  let two = parse("a\n\nb\n\nc")
  assert_eq(diff_prefix(one, two), 2)
}

///|
test "a changed block makes everything from it on new" {
  let one = parse("same\n\n## before")
  let two = parse("same\n\n## after")
  assert_eq(diff_prefix(one, two), 1)
}

///|
test "an unchanged document is all prefix" {
  let blocks = parse("a\n\nb\n\nc")
  assert_eq(diff_prefix(blocks, blocks), blocks.length())
}

///|
/// A shorter parse — text removed, which is not something the shell does today but is a shape the
/// function has to answer rather than index past the end of.
test "a shorter parse diffs against what it has" {
  let one = parse("a\n\nb\n\nc")
  let two = parse("a")
  assert_eq(diff_prefix(one, two), 1)
}

///|
test "nothing before is nothing to keep" {
  assert_eq(diff_prefix([], parse("a")), 0)
  assert_eq(diff_prefix(parse("a"), []), 0)
}
