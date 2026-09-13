///|
/// Escaping and serialization.
///
/// The tests that matter most are the ones named `injection`: this renderer's
/// input is model output and file contents, so a missed escape is a live XSS
/// rather than a cosmetic bug.

///|
/// Count occurrences of a substring. `split` yields one more piece than there are
/// separators, hence the subtraction.
fn occurrences(text : String, needle : String) -> Int {
  let mut count = 0
  for _ in text.split(needle) {
    count += 1
  }
  count - 1
}

// ── escape_text ────────────────────────────────────────────────────────────

///|
test "the three characters that can change markup are escaped" {
  assert_eq(escape_text("<div>"), "&lt;div&gt;")
  assert_eq(escape_text("a & b"), "a &amp; b")
}

///|
/// `&` has to be replaced before the others, or the entities they introduce get
/// escaped again and the page displays `&lt;` where it should display `<`.
test "ampersands are not double escaped" {
  assert_eq(escape_text("&lt;"), "&amp;lt;")
  assert_eq(escape_text("&"), "&amp;")
  // The order-dependent failure this guards against.
  assert_eq(escape_text("<"), "&lt;")
  assert_eq(escape_text("<").contains("&amp;"), false)
}

///|
test "ordinary text is left alone" {
  assert_eq(escape_text("hello world"), "hello world")
  assert_eq(escape_text(""), "")
  // Quotes are fine in element text; only attributes care.
  assert_eq(escape_text("it's \"quoted\""), "it's \"quoted\"")
}

///|
test "escaping survives unicode and newlines" {
  assert_eq(escape_text("中文\n<tag>"), "中文\n&lt;tag&gt;")
}

// ── escape_attr ────────────────────────────────────────────────────────────

///|
/// A value that closes its own quote can grow new attributes, so quotes are
/// escaped here and not in `escape_text`.
test "attribute quoting is escaped" {
  assert_eq(escape_attr("\"quoted\""), "&quot;quoted&quot;")
  assert_eq(escape_attr("it's"), "it&#39;s")
}

///|
test "attribute values escape markup too" {
  assert_eq(escape_attr("<b>"), "&lt;b&gt;")
  assert_eq(escape_attr("a & b"), "a &amp; b")
}

// ── Serialization ──────────────────────────────────────────────────────────

///|
test "an element renders with attributes and children" {
  let node = el(Div, attrs=[cls("block")], children=[text("hi")])
  assert_eq(node.render(), "<div class=\"block\">hi</div>")
}

///|
test "no attributes and no children" {
  assert_eq(el(Div).render(), "<div></div>")
}

///|
/// Void elements must not be given a closing tag; `</br>` is malformed and
/// browsers recover from it in ways that vary.
test "void elements have no closing tag" {
  assert_eq(el(Br).render(), "<br>")
  assert_eq(
    el(Input, attrs=[attr("type", "text")]).render(),
    "<input type=\"text\">",
  )
}

///|
test "nesting renders in order" {
  let node = el(Ul, children=[
    el(Li, children=[text("one")]),
    el(Li, children=[text("two")]),
  ])
  assert_eq(node.render(), "<ul><li>one</li><li>two</li></ul>")
}

///|
test "a fragment has no wrapper" {
  let node = frag([text("a"), text("b")])
  assert_eq(node.render(), "ab")
}

///|
/// The empty node exists so a conditional can produce a node without the caller
/// needing a branch.
test "the empty node renders nothing" {
  assert_eq(nothing().render(), "")
  assert_eq(el(Div, children=[nothing(), text("x")]).render(), "<div>x</div>")
}

///|
/// `Raw` is the one node that is not escaped. It exists for the markdown
/// renderer's own output.
test "raw passes through unescaped" {
  assert_eq(raw("<strong>bold</strong>").render(), "<strong>bold</strong>")
}

// ── Injection ──────────────────────────────────────────────────────────────

///|
/// The case this whole design exists for: a tool result containing a script tag
/// must arrive as text, not as markup.
test "injection: a script tag in text is escaped" {
  let node = el(Div, children=[text("<script>alert('xss')</script>")])
  let html = node.render()
  assert_false(html.contains("<script>"), msg=html)
  assert_true(html.contains("&lt;script&gt;"), msg=html)
}

///|
/// An image with an event handler is the other classic; the angle brackets are
/// what stop it, so the same escape covers it.
test "injection: an event handler attribute in text is escaped" {
  let node = el(P, children=[text("<img src=x onerror=alert(1)>")])
  let html = node.render()
  assert_false(html.contains("<img"), msg=html)
  assert_true(html.contains("&lt;img"), msg=html)
}

///|
/// A value that tries to close the attribute and open a new one must not be able
/// to, which is why `"` is escaped in attributes.
test "injection: an attribute value cannot break out" {
  let node = el(Div, attrs=[attr("title", "\" onmouseover=\"alert(1)")], children=[
    text("hover me"),
  ])
  let html = node.render()
  // Only the two quotes this renderer wrote are present.
  assert_eq(occurrences(html, "\""), 2, msg=html)
  assert_true(html.contains("&quot;"), msg=html)
}

///|
/// Closing the tag and starting a new element is the same attack from the text
/// side.
test "injection: text cannot close its element early" {
  let node = el(Div, children=[text("</div><script>alert(1)</script>")])
  let html = node.render()
  assert_eq(occurrences(html, "</div>"), 1, msg=html)
  assert_eq(occurrences(html, "<div"), 1, msg=html)
}
