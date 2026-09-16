///|
/// Parsing markdown into blocks and spans.
///
/// `strict=false` is the same flag the web UI renders with, and for the same reason: the
/// extensions are what make a table a table, and what enable strikethrough and task lists. Leaving
/// it on would give the two front ends different opinions about the same answer.
///
/// Raw HTML is dropped rather than passed through, which is the decision `safe=true` makes on the
/// HTML side. A model that emits `<script>` gets nothing here; the alternative — handing the host a
/// string to execute — is a hole in a window rather than in a page, and the cost of closing it is
/// that a document using HTML for layout looks plainer on this side.
pub fn parse(text : String) -> Array[Block] {
  let doc = @cmark.Doc::from_string(text, strict=false)
  let out : Array[Block] = []
  push_blocks(doc.block, doc.defs, out)
  out
}

///|
/// One block, and the children it owns.
///
/// Blocks that are containers recurse into their own array rather than flattening: a list item's
/// second paragraph belongs to that item, and a host that is handed it as a sibling of the list
/// cannot tell them apart.
fn push_blocks(
  block : @cmark.Block,
  defs : Map[String, @cmark.LabelDef],
  out : Array[Block],
) -> Unit {
  match block {
    // Blank lines are layout, a link definition is a definition and nothing else, and a footnote
    // definition is a block the host has no way to place. Dropping them is what the HTML renderer
    // does with the first two as well.
    BlankLine(_) | LinkRefDefinition(_) | ExtFootnoteDefinition(_) => ()
    // The one that matters: a model's raw HTML. Not rendered, not shown as source. See above.
    HtmlBlock(_) => ()
    Blocks(nodes) =>
      for child in nodes.v.to_array() {
        push_blocks(child, defs, out)
      }
    Paragraph(paragraph) =>
      out.push(Paragraph(push_spans(paragraph.v.inline, defs)))
    Heading(heading) =>
      out.push(Heading(heading.v.level, push_spans(heading.v.inline, defs)))
    ThematicBreak(_) => out.push(Rule)
    CodeBlock(code) => out.push(Code(code_language(code.v), code_text(code.v)))
    // Math is out of scope for this host, and a display formula is better shown as its own source
    // than as a paragraph with the delimiters stripped off it.
    ExtMathBlock(code) => out.push(Code("", code_text(code.v)))
    BlockQuote(quote) => {
      let inner : Array[Block] = []
      push_blocks(quote.v.block, defs, inner)
      out.push(Quote(inner))
    }
    List(list) => out.push(list_block(list.v, defs))
    ExtTable(table) => out.push(table_block(table.v, defs))
  }
}

///|
fn list_block(
  list : @cmark.BlockList,
  defs : Map[String, @cmark.LabelDef],
) -> Block {
  let items : Array[Array[Block]] = []
  for item in list.items.to_array() {
    let inner : Array[Block] = []
    push_blocks(item.v.block, defs, inner)
    task_marker(item.v.ext_task_marker, inner)
    items.push(inner)
  }
  match list.ty {
    @cmark_base.ListType::Unordered(_) => Bullets(items)
    // The first number is kept: a list that starts at 3 is saying something the host cannot say
    // with a bullet, and renumbering it from 1 would be the renderer editing the answer.
    @cmark_base.ListType::Ordered(start, _) => Numbers(start, items)
  }
}

///|
/// A task list item's checkbox, folded into the first thing in the item.
///
/// A block rather than a span because the item's text is a block: turning the marker into a
/// leading span would mean reaching into whatever kind of block came first, and a checkbox inside
/// a code block is a different claim about the document than one in front of a paragraph.
fn task_marker(marker : @cmark.Node[Char]?, blocks : Array[Block]) -> Unit {
  let mark = match marker {
    None => return
    Some(node) =>
      match node.v {
        'x' | 'X' => "\u{2611} "
        _ => "\u{2610} "
      }
  }
  match blocks.get(0) {
    Some(Paragraph(spans)) => spans.insert(0, Text(mark))
    _ => blocks.insert(0, Paragraph([Text(mark)]))
  }
}

///|
fn table_block(
  table : @cmark.Table,
  defs : Map[String, @cmark.LabelDef],
) -> Block {
  let mut header : Array[Array[Span]] = []
  let rows : Array[Array[Array[Span]]] = []
  let align : Array[Align] = []
  for entry in table.rows.to_array() {
    let (row, _) = entry
    match row.v {
      Header(cells) => header = cells_spans(cells, defs)
      Sep(seps) =>
        for sep in seps.to_array() {
          let (side, _) = sep.v.0
          align.push(
            match side {
              Some(@cmark.TableAlign::Center) => Center
              Some(@cmark.TableAlign::Right) => Right
              _ => Left
            },
          )
        }
      Data(cells) => rows.push(cells_spans(cells, defs))
    }
  }
  Table(header, rows, align)
}

///|
/// One row's cells, each parsed on its own.
///
/// `Seq` is private to the parser package, so the loop is written here rather than in a helper
/// that would have to name the type of the row it was handed.
fn cells_spans(
  cells : @cmark.Seq[(@cmark.Inline, @cmark.TableCellLayout)],
  defs : Map[String, @cmark.LabelDef],
) -> Array[Array[Span]] {
  let out : Array[Array[Span]] = []
  for cell in cells.to_array() {
    out.push(push_spans(cell.0, defs))
  }
  out
}

///|
fn code_language(code : @cmark.CodeBlock) -> String {
  match code.info_string {
    Some(info) =>
      match @cmark.CodeBlock::language_of_info_string(info.v) {
        Some((language, _)) => language
        None => ""
      }
    None => ""
  }
}

///|
fn code_text(code : @cmark.CodeBlock) -> String {
  code.code.to_array().map(fn(line) { line.v }).join("\n")
}

///|
fn push_spans(
  inline : @cmark.Inline,
  defs : Map[String, @cmark.LabelDef],
) -> Array[Span] {
  let out : Array[Span] = []
  push_inline(inline, defs, out)
  out
}

///|
fn push_inline(
  inline : @cmark.Inline,
  defs : Map[String, @cmark.LabelDef],
  out : Array[Span],
) -> Unit {
  match inline {
    Text(text) => out.push(Text(text.v))
    CodeSpan(code) => out.push(Code(code.v.code()))
    Inlines(nodes) =>
      for child in nodes.v.to_array() {
        push_inline(child, defs, out)
      }
    Emphasis(emphasis) => out.push(Emph(push_spans(emphasis.v.inline, defs)))
    StrongEmphasis(emphasis) =>
      out.push(Strong(push_spans(emphasis.v.inline, defs)))
    ExtStrikethrough(strike) => out.push(Strike(push_spans(strike.v.0, defs)))
    // A hard break is a newline and a soft one is the space the text was wrapped at. Both are
    // surfaced rather than swallowed: the host's own text view does the wrapping, and a source
    // line break that disappeared would join two words of a shell command.
    Break(brk) =>
      out.push(
        Text(
          match brk.v.ty {
            @cmark.InlineBreakType::Hard => "\n"
            _ => " "
          },
        ),
      )
    Autolink(link) => out.push(Link(link.v.link.v, [Text(link.v.link.v)]))
    Link(link) => push_link(link.v, defs, out)
    Image(image) => push_image(image.v, defs, out)
    RawHtml(_) => ()
    // Inline math keeps its delimiters, for the same reason the block form does.
    ExtMathSpan(math) =>
      out.push(
        Code(
          if math.v.display {
            "\\[" + math.v.tex() + "\\]"
          } else {
            "\\(" + math.v.tex() + "\\)"
          },
        ),
      )
  }
}

///|
/// A picture, when the host may be asked to draw one.
///
/// This crossed as its alt text once, on the grounds that the host had no loader and a broken-image
/// box is worse than a word. The host has one now — the same decode the composer uses for an
/// attachment — so the picture itself crosses, and the alt text crosses with it as the thing to say
/// when the bytes are not there after all. A target this package will not vouch for takes the old
/// road: the words, as a link when they point somewhere.
fn push_image(
  image : @cmark.InlineLink,
  defs : Map[String, @cmark.LabelDef],
  out : Array[Span],
) -> Unit {
  match image.reference_definition(defs) {
    Some(@cmark.LabelDef::LinkDef(definition)) =>
      match definition.v.dest {
        Some(dest) if drawable_image(dest.v) =>
          out.push(Image(dest.v, alt_text(image.text)))
        // Unresolvable, or a target the host is not to read: the words, and the target only if it is
        // one the host may open — which is the link rule, applied to an image whose picture is out.
        _ => push_link(image, defs, out)
      }
    // A footnote reference, or a label with no definition: the words are still the reader's.
    _ => push_inline(image.text, defs, out)
  }
}

///|
/// Whether a picture may be loaded from this target.
///
/// **It is a policy, and narrower than "any URL".** The link side refuses `javascript:` and `file:`
/// because it hands its target to the platform's opener — a hole in a browser is a hole in whatever
/// the reader clicks it with. A picture is not that: the host reads the bytes itself and decodes
/// them, so the test is not "is this safe to open" but "is this a picture that may be read". What
/// passes it:
///
///   - an absolute path, and a `file:` URL — a picture the agent just wrote is the case this exists
///     for, and it is the one the alt-text fallback made unusable;
///   - `data:` — the parser's own test still filters it, so only the four picture media types get
///     through and `data:text/html` is not a picture;
///   - `http(s)` — the one case that needs the network, and so the one case that can still be
///     arriving when the host draws it.
///
/// A *relative* target is refused rather than guessed at: what it is relative to is the reader's
/// directory as much as it is the model's, and a picture loaded from the wrong one is worse than a
/// caption. Everything refused arrives as the alt text, which is what arrived for all of them
/// before.
fn drawable_image(target : String) -> Bool {
  if target.has_prefix("/") {
    // A bare path. Not a URL at all, so there is no scheme to be fooled by, and it is the shape a
    // model writes for a picture it has just saved.
    true
  } else {
    let lower = target.to_lower()
    if lower.has_prefix("data:") ||
      lower.has_prefix("http:") ||
      lower.has_prefix("https:") {
      // The parser's own test still applies to these — it is what keeps `data:text/html` from being
      // a picture, and it is the same test the link side uses.
      !@cmark.InlineLink::is_unsafe(target)
    } else {
      // A local `file:` URL, and **deliberately not `is_unsafe`**: that test refuses `file:` because
      // its own caller hands the URL to the platform's opener, and this one reads the bytes itself.
      // A path the model can name is a path the host reads either way (the composer attaches one),
      // so the narrower rule would refuse the pictures this was built for and allow the same read
      // through another door. What is refused is the *remote* form — `file://host/x` loads from
      // somewhere this machine is not.
      lower.has_prefix("file:///") ||
      (lower.has_prefix("file:/") && !lower.has_prefix("file://"))
    }
  }
}

///|
/// An image's alt text, flattened into one line.
///
/// The parser gives it as the inline nodes between the brackets, so `![**bold**](…)` is an emphasis
/// rather than a string. A host that draws it as the caption under a picture wants one line: the
/// lines are joined with a space, because a caption is not a paragraph and a newline in it is a line
/// break nothing asked for.
fn alt_text(text : @cmark.Inline) -> String {
  text
  .to_plain_text(break_on_soft=false)
  .map(fn(line) { line.to_array().join("") })
  .to_array()
  .join(" ")
}

///|
/// A link, resolved against the document's definitions.
///
/// The URL is checked with the parser's own `is_unsafe` — the same test the HTML renderer uses to
/// decide whether to emit an `href` at all — because the link this becomes is one the host will
/// hand to `NSWorkspace`. A `javascript:` URL is a hole in a browser; here it is a hole in whatever
/// the reader clicks it with.
///
/// A link to something unresolvable, or to something unsafe, keeps its words and loses its target.
/// The alternative is dropping the words, which is the renderer deciding to say less than the
/// model did.
fn push_link(
  link : @cmark.InlineLink,
  defs : Map[String, @cmark.LabelDef],
  out : Array[Span],
) -> Unit {
  match link.reference_definition(defs) {
    Some(@cmark.LabelDef::LinkDef(definition)) => {
      let target = match definition.v.dest {
        Some(dest) => dest.v
        None => ""
      }
      if target == "" || @cmark.InlineLink::is_unsafe(target) {
        push_inline(link.text, defs, out)
      } else {
        out.push(Link(target, push_spans(link.text, defs)))
      }
    }
    // A footnote reference, or a label with no definition: the words are still the reader's.
    _ => push_inline(link.text, defs, out)
  }
}
