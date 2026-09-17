///|
/// The tests assert on the JSON, not on the value, because the JSON is the contract: the host
/// decodes these names, and a rename here that the host does not know about is two builds that
/// disagree about the same answer. `macos/WeiShell/Tests/WeiModelTests/SidebarTests.swift` pins the
/// same literals from the consuming side.

///|
fn wire(text : String) -> String {
  blocks_json(text).stringify()
}

///|
test "a paragraph is a paragraph" {
  assert_eq(
    wire("hello there"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"hello there\"}]}]",
  )
}

///|
test "a heading carries its level" {
  assert_eq(
    wire("## Notes"),
    "[{\"t\":\"h\",\"level\":2,\"spans\":[{\"t\":\"text\",\"text\":\"Notes\"}]}]",
  )
}

///|
test "emphasis nests rather than flattening" {
  assert_eq(
    wire("a *b **c** d* e"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"a \"},{\"t\":\"em\",\"spans\":[{\"t\":\"text\",\"text\":\"b \"},{\"t\":\"strong\",\"spans\":[{\"t\":\"text\",\"text\":\"c\"}]},{\"t\":\"text\",\"text\":\" d\"}]},{\"t\":\"text\",\"text\":\" e\"}]}]",
  )
}

///|
test "a fenced block keeps its language and loses its fence" {
  assert_eq(
    wire("```moonbit\nlet x = 1\nlet y = 2\n```"),
    "[{\"t\":\"code\",\"lang\":\"moonbit\",\"text\":\"let x = 1\\nlet y = 2\"}]",
  )
}

///|
test "an indented block has no language" {
  assert_eq(
    wire("    indented"),
    "[{\"t\":\"code\",\"lang\":\"\",\"text\":\"indented\"}]",
  )
}

///|
test "a bullet list is a list of items" {
  assert_eq(
    wire("- one\n- two\n"),
    "[{\"t\":\"ul\",\"items\":[[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"one\"}]}],[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"two\"}]}]]}]",
  )
}

///|
test "an ordered list keeps where it starts" {
  assert_eq(
    wire("3. three\n"),
    "[{\"t\":\"ol\",\"start\":3,\"items\":[[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"three\"}]}]]}]",
  )
}

///|
test "a nested list stays inside its item" {
  assert_eq(
    wire("- one\n  - deep\n"),
    "[{\"t\":\"ul\",\"items\":[[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"one\"}]},{\"t\":\"ul\",\"items\":[[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"deep\"}]}]]}]]}]",
  )
}

///|
test "a task item says which way it is checked" {
  assert_eq(
    wire("- [x] done"),
    "[{\"t\":\"ul\",\"items\":[[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"\u{2611} \"},{\"t\":\"text\",\"text\":\"done\"}]}]]}]",
  )
}

///|
test "a quote is its own block" {
  assert_eq(
    wire("> quoted"),
    "[{\"t\":\"quote\",\"blocks\":[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"quoted\"}]}]}]",
  )
}

///|
test "a thematic break is a block" {
  assert_eq(
    wire("a\n\n---\n\nb"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"a\"}]},{\"t\":\"hr\"},{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"b\"}]}]",
  )
}

///|
test "a table carries its header, rows and alignments" {
  assert_eq(
    wire("| a | b |\n|:--|--:|\n| 1 | 2 |"),
    "[{\"t\":\"table\",\"header\":[[{\"t\":\"text\",\"text\":\"a\"}],[{\"t\":\"text\",\"text\":\"b\"}]],\"rows\":[[[{\"t\":\"text\",\"text\":\"1\"}],[{\"t\":\"text\",\"text\":\"2\"}]]],\"align\":[\"left\",\"right\"]}]",
  )
}

///|
test "an unaligned table column reads as left" {
  assert_eq(
    wire("| a |\n|---|\n| 1 |"),
    "[{\"t\":\"table\",\"header\":[[{\"t\":\"text\",\"text\":\"a\"}]],\"rows\":[[[{\"t\":\"text\",\"text\":\"1\"}]]],\"align\":[\"left\"]}]",
  )
}

///|
test "inline code is code and not emphasis" {
  assert_eq(
    wire("run `moon test` now"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"run \"},{\"t\":\"code\",\"text\":\"moon test\"},{\"t\":\"text\",\"text\":\" now\"}]}]",
  )
}

///|
test "a link carries its target" {
  assert_eq(
    wire("see [the docs](https://example.com/x)"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"see \"},{\"t\":\"link\",\"url\":\"https://example.com/x\",\"spans\":[{\"t\":\"text\",\"text\":\"the docs\"}]}]}]",
  )
}

///|
test "an unsafe link keeps its words and loses its target" {
  assert_eq(
    wire("[click](javascript:alert(1))"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"click\"}]}]",
  )
}

///|
test "raw html does not cross" {
  assert_eq(wire("<script>alert(1)</script>"), "[]")
}

///|
test "strikethrough is a span" {
  assert_eq(
    wire("~~gone~~"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"del\",\"spans\":[{\"t\":\"text\",\"text\":\"gone\"}]}]}]",
  )
}

///|
test "a picture crosses as a picture, with its alt text beside it" {
  assert_eq(
    wire("![a chart](https://example.com/c.png)"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"image\",\"url\":\"https://example.com/c.png\",\"alt\":\"a chart\"}]}]",
  )
}

///|
test "a picture the agent just wrote is one the host can read" {
  // The case the alt-text fallback made unusable, and the reason a bare path is allowed through:
  // the agent writes the file, then refers to it, and there is no URL in the answer at all.
  assert_eq(
    wire("![shot](/tmp/shot.png)"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"image\",\"url\":\"/tmp/shot.png\",\"alt\":\"shot\"}]}]",
  )
  assert_eq(
    wire("![shot](file:///tmp/shot.png)"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"image\",\"url\":\"file:///tmp/shot.png\",\"alt\":\"shot\"}]}]",
  )
}

///|
test "a data URL crosses only when it is a picture" {
  assert_eq(
    wire(
      "![d](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==)",
    ),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"image\",\"url\":\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==\",\"alt\":\"d\"}]}]",
  )
  // Not a picture, so not a picture span: the alt text is what is left of it. The parser's own
  // `is_unsafe` is what decides, and it allows four picture media types and nothing else.
  assert_eq(
    wire("![d](data:text/html,<b>hi</b>)"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"d\"}]}]",
  )
}

///|
test "a relative picture keeps its words and its target" {
  // Refused as a picture — relative to what is the reader's question, not the model's — and then
  // the link rule applies, which allows a relative link: the reader who wrote it may well have
  // meant one, and a link the platform cannot open is a link that does nothing rather than a hole.
  assert_eq(
    wire("![p](chart.png)"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"link\",\"url\":\"chart.png\",\"spans\":[{\"t\":\"text\",\"text\":\"p\"}]}]}]",
  )
}

///|
test "an unsafe picture is a word" {
  assert_eq(
    wire("![x](javascript:alert(1))"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"x\"}]}]",
  )
}

///|
test "alt text is flattened out of its emphasis" {
  // The alt arrives as inline nodes; the host is handed a caption, which is one line and one run.
  assert_eq(
    wire("![a **bold** chart](/tmp/c.png)"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"image\",\"url\":\"/tmp/c.png\",\"alt\":\"a bold chart\"}]}]",
  )
}

///|
test "a picture in a table cell or a bullet crosses the same way" {
  assert_eq(
    wire("- ![one](/tmp/1.png)"),
    "[{\"t\":\"ul\",\"items\":[[{\"t\":\"p\",\"spans\":[{\"t\":\"image\",\"url\":\"/tmp/1.png\",\"alt\":\"one\"}]}]]}]",
  )
}

///|
test "a hard break is a newline" {
  assert_eq(
    wire("one  \ntwo"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"text\",\"text\":\"one\"},{\"t\":\"text\",\"text\":\"\\n\"},{\"t\":\"text\",\"text\":\"two\"}]}]",
  )
}

///|
test "nothing is said about a document that is empty" {
  assert_eq(wire(""), "[]")
}

///|
test "internet shorthand survives, in one piece" {
  // The reason the span list is flat: a host accumulating attributes does not care where the
  // boundaries were, and this arrives as one word rather than three.
  assert_eq(
    wire("**a** b_c a*b"),
    "[{\"t\":\"p\",\"spans\":[{\"t\":\"strong\",\"spans\":[{\"t\":\"text\",\"text\":\"a\"}]},{\"t\":\"text\",\"text\":\" b_c a*b\"}]}]",
  )
}
