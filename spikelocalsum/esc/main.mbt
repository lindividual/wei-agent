///|
/// Does `Json::stringify` escape non-ASCII?
///
/// The answer decides whether byte counts taken from encoded JSON can be compared
/// with a provider's token counts at all. A CJK character is three UTF-8 bytes and
/// becomes six (`\uXXXX`) if it is escaped, so a conversation with Chinese in it
/// would look half again as large as it is.
fn main {
  let s = "中文 thinking 内容 1234567890"
  let object = Json::object(Map([("text", Json::string(s))]))
  let encoded = object.stringify()
  println("string utf8 bytes:    \{@utf8.encode(s).length()}")
  println("stringify utf8 bytes: \{@utf8.encode(encoded).length()}")
  println("encoded: \{encoded}")
}
