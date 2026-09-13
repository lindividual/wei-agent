///|
/// What the markdown path is expected to render.
///
/// The table test is the one that matters: tables come from a cmark *extension*, which is off
/// unless the render call says otherwise, and a coding agent emits them constantly. A silent
/// regression here is invisible in a unit test that only checks prose, so it is pinned directly.

///|
test "a GFM table renders as a table, not as a paragraph of pipes" {
  let source =
    #|| Name | Cost |
    #||------|------|
    #|| fast | $1   |
    #|| slow | $9   |
  let html = markdown_or_text(source).render()
  assert_true(html.contains("<table"), msg=html)
  assert_true(html.contains("<th>Name</th>"), msg=html)
  assert_eq(count_of(html, "<td"), 4, msg=html)
  // The failure this guards against: pipes left in a paragraph.
  assert_false(html.contains("| Name |"), msg=html)
}

///|
test "extensions do not reopen the raw-HTML hole" {
  let html = markdown_or_text("<script>alert(1)</script>").render()
  assert_false(html.to_lower().contains("<script"), msg=html)
}

///|
test "a fenced block keeps its language for the client to read" {
  let html = markdown_or_text("```moonbit\nfn main { }\n```").render()
  assert_true(html.contains("language-moonbit"), msg=html)
}
