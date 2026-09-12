///|
/// The platform layer: everything that touches the operating system.
///
/// Kept separate from `core/` so the logic there stays portable. Only the
/// native backend exists today; the interface is deliberately narrow so a
/// second implementation would be small.

///|
pub(all) struct HttpResponse {
  status : Int
  body : String
} derive(Eq, Debug)

///|
/// POST a JSON body and read the whole response back.
///
/// Deliberately not streaming: `core`'s SSE parser consumes a complete body, so
/// the platform layer's job is to fetch bytes and get out of the way.
/// Incremental delivery is a UI concern and will be added by exposing the
/// response reader rather than by changing the parser.
pub async fn post_json(
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> HttpResponse {
  let http_headers : @http.Headers = Map([])
  for name, value in headers {
    http_headers.set(@http.CaseInsensitiveString(name), value)
  }
  let (response, data) = @http.post(url, body, headers=http_headers)
  let bytes = data.binary()
  { status: response.code, body: @utf8.decode_lossy(bytes), }
}

///|
/// POST a JSON body and hand each piece of the response to a callback as it
/// arrives.
///
/// Two details are load-bearing.
///
/// Decoding happens per complete line, not per chunk. A network read can land in
/// the middle of a multi-byte character, and decoding that fragment would produce
/// a replacement glyph that no amount of later data can undo. Since SSE frames are
/// newline-delimited, cutting at a newline is always a character boundary.
///
/// The read buffer is small on purpose. A large one would sit waiting for it to
/// fill before the first delta reached the browser, which is precisely the
/// latency streaming exists to remove.
///
/// `idle_timeout_ms` bounds both waits that can hang — for the response to start, and
/// for each subsequent read. It is per wait rather than for the whole request, so a
/// long answer is never cut off for taking a long time; only silence is.
pub async fn post_sse(
  url : String,
  headers : Map[String, String],
  body : String,
  on_chunk : async (String) -> Unit,
  should_stop? : () -> Bool,
  idle_timeout_ms? : Int = 120000,
) -> Unit {
  // A cancelled turn stops reading rather than draining a response nobody wants.
  // Whatever arrived is still parsed by the caller, so the transcript keeps the
  // prefix the user already saw.
  let stopping = match should_stop {
    Some(check) => check
    None => fn() { false }
  }
  let http_headers : @http.Headers = Map([])
  for name, value in headers {
    http_headers.set(@http.CaseInsensitiveString(name), value)
  }
  let client = @http.post_stream(url, headers=http_headers)
  defer client.close()
  client.write(body)
  // Waiting for the response headers is its own chance to hang: `end_request` blocks
  // until the status line arrives, which is *before* the first byte of the body. A
  // timeout around the read loop alone would leave the most likely stall — a
  // connection that was accepted and then forgotten — unbounded.
  let response = match
    @async.with_timeout_opt(idle_timeout_ms, () => client.end_request()) {
    Some(response) => response
    None =>
      raise Failure::Failure(
        "model endpoint sent no response within \{idle_timeout_ms}ms",
      )
  }
  if response.code != 200 {
    raise Failure::Failure("model endpoint returned HTTP \{response.code}")
  }

  let buffer = FixedArray::make(4096, b'\x00')
  let mut carry : Bytes = b""
  while true {
    if stopping() {
      break
    }
    // A stream that goes quiet is the one failure a reader cannot tell from a model
    // that is thinking: without this, a dropped connection leaves the turn — and
    // every request queued behind it — waiting forever. The timeout is per read, so
    // a slow but live response is never cut off.
    let count = match
      @async.with_timeout_opt(idle_timeout_ms, () => {
        client.read(buffer, offset=0, max_len=buffer.length())
      }) {
      Some(count) => count
      None =>
        raise Failure::Failure(
          "model stream sent nothing for \{idle_timeout_ms}ms",
        )
    }
    if count <= 0 {
      break
    }
    let piece = FixedArray::make(count, b'\x00')
    for i in 0..<count {
      piece[i] = buffer[i]
    }
    let combined = carry + Bytes::from_array(piece)
    // Everything up to the last newline is safe to decode; the rest is carried
    // forward until its line completes.
    let mut last = -1
    let length = combined.length()
    for i in 0..<length {
      if combined[i] == b'\n' {
        last = i
      }
    }
    if last < 0 {
      carry = combined
    } else {
      let complete = combined[:last + 1].to_owned()
      carry = combined[last + 1:].to_owned()
      on_chunk(@utf8.decode_lossy(complete))
    }
  }
  if carry.length() > 0 {
    on_chunk(@utf8.decode_lossy(carry))
  }
}
