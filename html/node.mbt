///|
/// A minimal HTML tree and its serializer.
///
/// Built here rather than taken from rabbita: that library keeps its virtual DOM
/// in an `internal` package, so `server_side_render` and the `VNode` type are
/// both unreachable from outside — MoonBit enforces that at compile time. The
/// only entry point it exposes is whole-page rendering plus client hydration,
/// which is the wrong shape for pushing fragments.
///
/// This is the smaller thing that is actually needed: build a tree, serialize it,
/// escape everything on the way out.
///
/// ## The tag is a type
///
/// `el` takes a `Tag`, not a `String`. The reason is that a tag was the one thing in this file the
/// compiler could not check: `el("dvi", ...)` compiled and produced markup a browser silently
/// ignores, and the consequence is worse than a wrong tag — the client drops a patch whose target
/// element is missing (`if (!node) return`), so a mistyped *wrapper* means a region that quietly
/// stops updating while every byte-level assertion still passes. That is the same failure class as
/// the most expensive bug this UI has had.
///
/// The alternatives were considered and rejected on evidence rather than taste:
///
/// - **One function per tag** (`div(...)`, `i(...)`): reads best, and unusable. A tag name is an
///   ordinary lowercase identifier, so it collides with locals — `for i in 0..<n` in a file that
///   renders `<i>` shadows the function and fails with "has type : Int, wanted : function type".
///   Ten such collisions already exist in this tree (`i`, `label`, `body`, `head`, `html`, `input`,
///   `meta`, `style`, `summary`, `title`), and they are all natural names, so the collision would
///   be rediscovered forever. Measured, not guessed: see the probe in `node_test.mbt`.
/// - **Capitalized functions** (`Div(...)`): a parse error. Uppercase names are for constructors.
/// - **A sub-package** (`@tags.div(...)`): would break the package cycle through `Node`, so it is a
///   three-package split — that is candidate C's work, not this.
///
/// So the tag is a value of an enum type, written `el(Div, ...)`. Bare constructors are inferred
/// from the parameter's type, so it is the same length as the string it replaces, it cannot be
/// mistyped, and `Tag::name` below is the single place a tag becomes markup.

///|
/// A tag this program emits.
///
/// Only the tags in use, because the type is a claim about what this file can produce. Adding one
/// is a deliberate act with a compile-time consequence: `Tag::name` is a total match, so a new
/// variant that is not named does not build.
pub(all) enum Tag {
  Aside
  B
  Body
  Br
  Button
  Dd
  Details
  Div
  Dl
  Dt
  Form
  H2
  H3
  Head
  Html
  I
  Input
  Label
  Li
  Meta
  Option
  P
  Pre
  Script
  Section
  Select
  Span
  Style
  Summary
  Textarea
  Time
  Title
  Ul
} derive(Eq, Debug)

///|
/// The tag as it is written in markup.
///
/// Total on purpose. A new `Tag` variant that is not named here fails to build, which is the whole
/// reason the tag became a type: the mapping from "which tag" to "which bytes" now has exactly one
/// home, and the compiler knows when it is incomplete.
fn Tag::name(self : Tag) -> String {
  match self {
    Aside => "aside"
    B => "b"
    Body => "body"
    Br => "br"
    Button => "button"
    Dd => "dd"
    Details => "details"
    Div => "div"
    Dl => "dl"
    Dt => "dt"
    Form => "form"
    H2 => "h2"
    H3 => "h3"
    Head => "head"
    Html => "html"
    I => "i"
    Input => "input"
    Label => "label"
    Li => "li"
    Meta => "meta"
    Option => "option"
    P => "p"
    Pre => "pre"
    Script => "script"
    Section => "section"
    Select => "select"
    Span => "span"
    Style => "style"
    Summary => "summary"
    Textarea => "textarea"
    Time => "time"
    Title => "title"
    Ul => "ul"
  }
}

///|
/// A tag that never takes a closing tag. Emitting `</br>` would be malformed.
///
/// Unlike `name`, this match is *not* exhaustive: the catch-all is deliberate, because 30 of the 33
/// tags answer `false` and listing them would be noise for no guarantee worth having. The cost is
/// stated plainly so nobody reads a guarantee into it — adding a void tag (`Img`, say) and
/// forgetting this list would emit `<img></img>`, which is wrong but visible, and the browser check
/// renders every page this program builds. `name` is the mapping that had to be exhaustive, because
/// a missing name has no fallback that produces anything sensible.
fn Tag::is_void(self : Tag) -> Bool {
  match self {
    Br | Input | Meta => true
    _ => false
  }
}

///|
pub(all) struct Attr {
  name : String
  value : String
} derive(Eq, Debug)

///|
pub fn attr(name : String, value : String) -> Attr {
  { name, value, }
}

///|
pub fn cls(value : String) -> Attr {
  { name: "class", value, }
}

///|
/// A node.
///
/// `Text` is escaped on serialization; `Raw` is not. `Raw` exists for HTML this
/// program produced itself — the output of the markdown renderer — and is the
/// only place an escaping bug can hide, so it is named to be conspicuous in a
/// diff.
pub(all) enum Node {
  Element(tag~ : Tag, attrs~ : Array[Attr], children~ : Array[Node])
  Text(String)
  Raw(String)
  /// Renders children with no wrapper of its own.
  Fragment(Array[Node])
  /// Renders nothing. Lets a conditional produce a node without a branch at the
  /// call site.
  Empty
} derive(Eq, Debug)

// ── Constructors ───────────────────────────────────────────────────────────

///|
/// An element.
///
/// The tag is a `Tag`, so it cannot come from model output or any other string — the markup this
/// produces is decided by this program's type, which is what the serializer relies on when it
/// writes the tag unescaped.
pub fn el(
  tag : Tag,
  attrs? : Array[Attr] = [],
  children? : Array[Node] = [],
) -> Node {
  Element(tag~, attrs~, children~)
}

///|
pub fn text(value : String) -> Node {
  Text(value)
}

///|
/// Pre-rendered, trusted HTML.
pub fn raw(html : String) -> Node {
  Raw(html)
}

///|
/// Concatenate children without a wrapper.
pub fn frag(children : Array[Node]) -> Node {
  Fragment(children)
}

///|
/// The empty node, for branches that render nothing.
pub fn nothing() -> Node {
  Empty
}

// ── Serialization ──────────────────────────────────────────────────────────

///|
pub fn Node::render(self : Node) -> String {
  let out = StringBuilder()
  let out = render_into(out, self)
  out.to_string()
}

///|
/// Write a node into a builder and hand the builder back.
///
/// Returning the builder rather than `Unit` keeps every branch an expression,
/// which is what MoonBit wants from a `match` used as a function body — a
/// trailing `Unit` there is rejected even though it is the declared return type.
fn render_into(out : StringBuilder, node : Node) -> StringBuilder {
  match node {
    Text(value) => {
      out.write_string(escape_text(value))
      out
    }
    Raw(html) => {
      out.write_string(html)
      out
    }
    Empty => out
    Fragment(children) => {
      for child in children {
        let _ = render_into(out, child)
      }
      out
    }
    Element(tag~, attrs~, children~) => {
      let name = tag.name()
      out.write_string("<")
      out.write_string(name)
      for a in attrs {
        out.write_string(" ")
        out.write_string(a.name)
        out.write_string("=\"")
        out.write_string(escape_attr(a.value))
        out.write_string("\"")
      }
      if tag.is_void() {
        out.write_string(">")
      } else {
        out.write_string(">")
        for child in children {
          let _ = render_into(out, child)
        }
        out.write_string("</")
        out.write_string(name)
        out.write_string(">")
      }
      out
    }
  }
}

///|
/// Render children into an existing builder, for callers assembling a page in
/// pieces.
pub fn render_append(out : StringBuilder, node : Node) -> StringBuilder {
  render_into(out, node)
}
