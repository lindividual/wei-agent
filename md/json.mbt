///|
/// The wire form.
///
/// JSON rather than a C struct because the host is a Swift program that already has a decoder, and
/// because the host boundary in this app is one line of JSON per fact — a second framing for one
/// event would be a second thing to keep in step.
///
/// Tagged objects — `{"t":"heading","level":2,...}` — rather than arrays of positional fields: a
/// field that is added later must not be able to shift the meaning of one that is already there.

///|
/// One finished block of markdown, as the host draws it.
///
/// This is the call the shell makes when a streaming block stops growing. The host holds the rows;
/// what crosses is the row's id and the structure of its text.
pub fn blocks_json(text : String) -> Json {
  Json::array(parse(text).map(fn(block) { block.to_json() }))
}

///|
pub fn Block::to_json(self : Block) -> Json {
  match self {
    Paragraph(spans) => tag("p", [("spans", spans_json(spans))])
    Heading(level, spans) =>
      tag("h", [
        ("level", Json::number(level.to_double(), repr=level.to_string())),
        ("spans", spans_json(spans)),
      ])
    Code(lang, text) =>
      tag("code", [("lang", Json::string(lang)), ("text", Json::string(text))])
    Bullets(items) => tag("ul", [("items", lists_json(items))])
    Numbers(start, items) =>
      tag("ol", [
        ("start", Json::number(start.to_double(), repr=start.to_string())),
        ("items", lists_json(items)),
      ])
    Quote(blocks) => tag("quote", [("blocks", blocks_json_of(blocks))])
    Rule => tag("hr", [])
    Table(header, rows, align) =>
      tag("table", [
        ("header", cells_json(header)),
        ("rows", Json::array(rows.map(fn(row) { cells_json(row) }))),
        ("align", Json::array(align.map(fn(value) { Align::name(value) }))),
      ])
  }
}

///|
fn Align::name(self : Align) -> Json {
  match self {
    Left => Json::string("left")
    Center => Json::string("center")
    Right => Json::string("right")
  }
}

///|
fn cells_json(cells : Array[Array[Span]]) -> Json {
  Json::array(cells.map(fn(cell) { spans_json(cell) }))
}

///|
fn lists_json(items : Array[Array[Block]]) -> Json {
  Json::array(items.map(fn(item) { blocks_json_of(item) }))
}

///|
fn blocks_json_of(blocks : Array[Block]) -> Json {
  Json::array(blocks.map(fn(block) { block.to_json() }))
}

///|
/// A run of spans, as the host's text view reads it.
pub fn Span::to_json(self : Span) -> Json {
  match self {
    Text(text) => tag("text", [("text", Json::string(text))])
    Code(code) => tag("code", [("text", Json::string(code))])
    Emph(spans) => tag("em", [("spans", spans_json(spans))])
    Strong(spans) => tag("strong", [("spans", spans_json(spans))])
    Strike(spans) => tag("del", [("spans", spans_json(spans))])
    Link(url, spans) =>
      tag("link", [("url", Json::string(url)), ("spans", spans_json(spans))])
    Image(url, alt) =>
      tag("image", [("url", Json::string(url)), ("alt", Json::string(alt))])
  }
}

///|
fn spans_json(spans : Array[Span]) -> Json {
  Json::array(spans.map(fn(span) { span.to_json() }))
}

///|
/// One tagged object, with its kind first. The order is for the reader of a log line rather than
/// for the decoder: `kind` opens every event the shell sends, and a block that led with its
/// payload would be the one shape in the stream that read differently.
fn tag(kind : String, fields : Array[(String, Json)]) -> Json {
  let pairs : Array[(String, Json)] = [("t", Json::string(kind))]
  for field in fields {
    pairs.push(field)
  }
  Json::object(Map(pairs))
}
