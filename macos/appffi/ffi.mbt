///|
/// The two directions of the host boundary.
///
/// What crosses is a line of JSON, not the SSE frames the web UI sends, and the difference
/// is what each side owns. Over there the server owned the document and the browser applied
/// patches to it; here the host owns the view and draws it from facts. So an event says what
/// happened — this text arrived, this tool started, this turn ended — and never how to draw
/// it.
///
/// One JSON object per line rather than a length prefix or a C struct: the host is a Swift
/// program that already has a decoder, and a line is the one framing that survives an
/// argument about field names later.

///|
/// Hand one event to the host.
///
/// `#borrow` because the host copies: the bytes belong to MoonBit and must not outlive this
/// call. Nothing here defines `wei_emit` — the host does, and `host_stub.c` is only a weak
/// default so that `moon test` links without one.
pub fn emit(event : Json) -> Unit {
  let line = event.stringify() + "\n"
  let bytes = @utf8.encode(line)
  wei_emit(bytes, bytes.length())
}

///|
#borrow(bytes)
extern "C" fn wei_emit(bytes : Bytes, len : Int) -> Unit = "wei_emit"

///|
/// Read the oldest command, or the empty string when there is none.
///
/// The buffer is reused across calls rather than sized per message: a prompt is bounded by
/// what a person will type, and the alternative is a length query that would need its own
/// call into the host.
pub fn take_command() -> String {
  let buffer = Bytes::new(65536)
  let len = wei_recv(buffer, buffer.length())
  if len <= 0 {
    ""
  } else {
    @utf8.decode_lossy(buffer.view(end=len))
  }
}

///|
#borrow(buffer)
extern "C" fn wei_recv(buffer : Bytes, capacity : Int) -> Int = "wei_recv"
