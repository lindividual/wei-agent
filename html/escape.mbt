///|
/// HTML escaping.
///
/// The whole safety story of this renderer rests on one rule: text is escaped on
/// the way out, always, and there is exactly one way to opt out.
///
/// That matters more here than in a typical web app, because the text being
/// rendered is model output and file contents — strings nobody vetted. A tool
/// result containing `<script>` must arrive in the browser as those eight
/// characters.

///|
/// Escape text for an element's body.
///
/// `&` is replaced first. Doing it in any other order would re-escape the
/// ampersands introduced by the other replacements, turning `<` into
/// `&amp;lt;` — which renders as the literal text `&lt;`.
pub fn escape_text(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Escape a value for a double-quoted attribute.
///
/// Quoting is what makes this different from `escape_text`: an attribute value
/// that closes its own quote can grow new attributes, so `"` and `'` are escaped
/// too.
pub fn escape_attr(value : String) -> String {
  let out = StringBuilder()
  for c in value {
    match c {
      '&' => out.write_string("&amp;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}
