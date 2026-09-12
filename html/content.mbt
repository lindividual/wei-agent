///|
/// Rendering agent content as HTML.
///
/// The shape follows what the conversation actually is: a user message, then the
/// assistant's blocks — reasoning, prose, tool calls — with each tool call paired
/// to the result that answered it. Pairing happens here rather than being assumed
/// of the caller, because the two arrive in separate messages.

///|
/// One renderable unit of assistant output.
pub(all) enum Piece {
  /// A block that stands alone.
  Plain(block~ : @core.Content)
  /// A tool call with the result that answered it, if one has arrived.
  Tool(call~ : @core.Content, result~ : @core.ToolResultMessage?)
} derive(Eq, Debug)

///|
/// Pair tool calls with their results by call id.
///
/// A call without a result is not an error: it is a tool still running, or one
/// that never finished because the process died. Both are worth showing.
pub fn pair_tools(
  blocks : Array[@core.Content],
  results : Array[@core.ToolResultMessage],
) -> Array[Piece] {
  let units : Array[Piece] = []
  for block in blocks {
    match block {
      @core.ToolCall(id~, ..) => {
        let mut found : @core.ToolResultMessage? = None
        for result in results {
          if result.tool_call_id == id {
            found = Some(result)
          }
        }
        units.push(Tool(call=block, result=found))
      }
      _ => units.push(Plain(block~))
    }
  }
  units
}

///|
/// Render markdown to HTML.
///
/// `safe=true` makes cmark drop raw HTML embedded in the markdown, which matters
/// because the markdown is model output. Without it, a model could emit a script
/// tag inside a code block's sibling and have it execute.
pub fn markdown(text : String) -> Node raise {
  Raw(@cmark_html.render(text, safe=true))
}
