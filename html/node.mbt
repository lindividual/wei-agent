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

///|
/// A tag that never takes a closing tag. Emitting `</br>` would be malformed.
fn is_void_element(tag : String) -> Bool {
  match tag {
    "area"
    | "base"
    | "br"
    | "col"
    | "embed"
    | "hr"
    | "img"
    | "input"
    | "link"
    | "meta"
    | "param"
    | "source"
    | "track"
    | "wbr" => true
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
  Element(tag~ : String, attrs~ : Array[Attr], children~ : Array[Node])
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
/// An element. `tag` must be a literal from this program, never a value derived
/// from model output; it is written into the markup unescaped.
pub fn el(
  tag : String,
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
      out.write_string("<")
      out.write_string(tag)
      for a in attrs {
        out.write_string(" ")
        out.write_string(a.name)
        out.write_string("=\"")
        out.write_string(escape_attr(a.value))
        out.write_string("\"")
      }
      if is_void_element(tag) {
        out.write_string(">")
      } else {
        out.write_string(">")
        for child in children {
          let _ = render_into(out, child)
        }
        out.write_string("</")
        out.write_string(tag)
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
