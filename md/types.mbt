///|
/// The shape of a markdown document, for a host that draws its own text.
///
/// The web UI renders markdown to HTML and hands the browser a string, because a browser is a
/// renderer and cmark speaks its language. A native host is not: a SwiftUI `Text` cannot be given
/// `<h2>`, and `AttributedString(markdown:)` — what this app used before this package existed —
/// takes the *source* rather than a parse, so it never sees a table at all and drops a fenced
/// block's language on the floor.
///
/// So the parse happens here, once per finished block, and crosses as data. What crosses is
/// deliberately coarse: headings, paragraphs, code, lists, quotes, rules, tables, and a small set
/// of inline spans. That is the set this agent's answers actually use — a coding agent's reply is
/// prose with code in it — and everything outside it arrives as plain text rather than being
/// dropped.
pub(all) enum Block {
  /// A run of text, the most common block by a wide margin.
  Paragraph(Array[Span])
  Heading(Int, Array[Span])
  /// A fenced block. `lang` is empty when the fence had no info string, and the host draws no
  /// language label rather than an empty one.
  Code(String, String)
  Bullets(Array[Array[Block]])
  Numbers(Int, Array[Array[Block]])
  Quote(Array[Block])
  /// A thematic break — `---`. A block rather than an inline because that is how it is written.
  Rule
  /// Header cells, body rows, and one alignment per column. The alignments are their own list
  /// because a table is written column-major in its separator row and row-major everywhere else,
  /// and the host needs a column's alignment while drawing a cell.
  Table(Array[Array[Span]], Array[Array[Array[Span]]], Array[Align])
} derive(Debug, Eq)

///|
/// How a column's cells line up. Carried because it is the one thing a markdown table says that
/// its cells do not: `|:--|` is a decision the writer made about the column.
pub(all) enum Align {
  Left
  Center
  Right
} derive(Debug, Eq)

///|
/// A run of styled text inside a block.
///
/// A flat list rather than a tree: the host applies Nesting by *accumulating* attributes, which is
/// what makes `*bold **and italic**` one pass rather than a recursive descent on the other side of
/// the wire. The one exception is `Link`, which carries its own spans because a link's target is a
/// property of the link rather than of the words inside it.
pub(all) enum Span {
  Text(String)
  Code(String)
  Emph(Array[Span])
  Strong(Array[Span])
  Strike(Array[Span])
  Link(String, Array[Span])
} derive(Debug, Eq)
