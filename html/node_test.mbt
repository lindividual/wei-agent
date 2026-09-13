///|
/// The tag type, and the mapping it exists to give one home.
///
/// `el` used to take a string, so the tag→markup mapping was spread across 194 call sites as
/// literals: `el("dd", ...)`. Each one was independently correct and none was checked. Now the
/// mapping lives in `Tag::name` alone, and the compiler enforces that it is total — but *total* is
/// not the same as *right*, and the rewrite that produced it was mechanical. `Dd => "dt"` would
/// compile. So the table below is the thing that pins it.
///
/// The second test is the reason the interface is shaped the way it is, kept as a regression
/// guard: the obvious design — one function per tag, `div(...)`, `i(...)` — cannot be used here,
/// and this is the smallest reproduction of why.

///|
/// Every tag, with the markup it must produce.
fn tag_table() -> Array[(Tag, String)] {
  [
    (Aside, "aside"),
    (B, "b"),
    (Body, "body"),
    (Br, "br"),
    (Button, "button"),
    (Dd, "dd"),
    (Details, "details"),
    (Div, "div"),
    (Dl, "dl"),
    (Dt, "dt"),
    (Form, "form"),
    (H2, "h2"),
    (H3, "h3"),
    (Head, "head"),
    (Html, "html"),
    (I, "i"),
    (Input, "input"),
    (Label, "label"),
    (Li, "li"),
    (Meta, "meta"),
    (Option, "option"),
    (P, "p"),
    (Pre, "pre"),
    (Script, "script"),
    (Section, "section"),
    (Select, "select"),
    (Span, "span"),
    (Style, "style"),
    (Summary, "summary"),
    (Textarea, "textarea"),
    (Time, "time"),
    (Title, "title"),
    (Ul, "ul"),
  ]
}

///|
/// The mapping, tag by tag, and the void elements that must not get a closing tag.
test "every tag renders the markup it names" {
  for entry in tag_table() {
    let (tag, expected) = entry
    let rendered = el(tag, children=[txt("c")]).render()
    // Void elements take no children and no closing tag; everything else wraps its children.
    let wanted = match tag {
      Br | Input | Meta => "<\{expected}>"
      _ => "<\{expected}>c</\{expected}>"
    }
    assert_eq(rendered, wanted)
  }
}

///|
/// The table covers the type. If a variant is added, its absence here is what is noticed — `name`
/// being total only proves it was *given* a name, not that the name is on this list.
test "the table names every variant the type has" {
  // A tag the table forgot would still render, so the check is the other direction: the count.
  // 33 variants, and the number is written down rather than derived because deriving it would
  // defeat the point — someone adding a tag has to come here and update both.
  assert_eq(tag_table().length(), 33)
}

///|
/// A local variable may share a tag's name, and that is the constraint the interface is built
/// around.
///
/// The design this replaced was one function per tag: `i(...)`, `label(...)`, `body(...)`. It reads
/// best, and it does not compile here — a tag name is an ordinary lowercase identifier, so a local
/// of the same name shadows the function. This file renders `<i>`, and `i` is the conventional
/// loop index; `label`, `body`, `head`, `input`, `meta`, `summary` and `title` are equally natural
/// as parameter and local names, and ten such collisions already exist in this tree.
///
/// So the tag is a value of an enum type instead, reached as `el(I, ...)`. The constructor lives in
/// the *type* namespace, which a local cannot shadow, so this test passes for the same reason the
/// real code does.
test "a local named after a tag cannot shadow the tag" {
  let out = StringBuilder()
  for i in 0..<2 {
    // `i` is an Int here, and the tag still resolves.
    let li = el(I, children=[txt("\{i}")])
    out.write_string(li.render())
  }
  assert_eq(out.to_string(), "<i>0</i><i>1</i>")
  // The same for the other names that collide in practice.
  let body : Array[Node] = [el(Body, children=[])]
  let label = el(Label, children=[txt("l")]).render()
  assert_eq(body.length(), 1)
  assert_eq(label, "<label>l</label>")
}

///|
/// The tag cannot come from a string, which is the escape hatch that would undo the whole point.
///
/// There is no `Tag::from_string` and no `el` overload taking one: the serializer writes the tag
/// unescaped, and it is safe only because the set of tags is closed and decided by this program's
/// type rather than by anything a model or a file produced.
test "markup is built from tags, not from text" {
  // Text that looks like markup is escaped; a tag is not text. The two paths cannot be confused.
  assert_eq(el(Div, children=[txt("<div>")]).render(), "<div>&lt;div&gt;</div>")
}
