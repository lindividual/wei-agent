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
/// Why a call to the model endpoint failed, split by whether another attempt could help.
///
/// The split is the whole point of the type. A connection that dropped, a stream that went
/// quiet, a 5xx or a 429 are all the endpoint failing to answer *this time*, and the next
/// attempt can get a real answer. A 401 or a 400 is the endpoint answering — it will answer the
/// same way however many times it is asked, so retrying only spends the reader's time and buys
/// another identical failure.
///
/// The platform raises this rather than deciding: how many attempts, how long to wait between
/// them, and when a reader has already seen too much to retry are all the caller's business.
pub suberror ModelError {
  /// The request never got a usable answer, and another attempt could get one.
  Transient(String)
  /// The endpoint answered, and will answer the same way again.
  Permanent(String)
}

///|
/// The message already says what happened and to which URL, so the rendering is the message.
pub impl Show for ModelError with fn output(self, logger) {
  match self {
    Transient(msg) => logger.write_string(msg)
    Permanent(msg) => logger.write_string(msg)
  }
}

///|
/// Whether a status code describes a condition that could clear on its own.
///
/// 408 (the server gave up waiting for the request) and 429 (too many requests) are about
/// timing, not about the request; 5xx is the server failing at its job. Everything else in the
/// 4xx range is about the request itself — a bad key, a malformed body, a context that is too
/// long — and repeating it is pointless.
fn status_is_transient(code : Int) -> Bool {
  code == 408 || code == 429 || code >= 500
}

///|
/// Classify a failure at the transport boundary, as the error to raise.
///
/// Two jobs, and both matter.
///
/// **Cancellation passes through untouched.** Cancellation is an ordinary error in this runtime,
/// and it is not a failure of the request: it means the caller stopped wanting the answer — the
/// reader pressed Stop, or the turn's task group was torn down. Turning it into a transient
/// failure would turn "the reader gave up" into "ask the model again", which is the opposite of
/// what they asked for. `is_being_cancelled` is checked as well as `is_cancellation_error`,
/// because the latter is documented as not always accurate during cancellation handling.
///
/// **Everything else is transient, including errors that are not `OSError`s.** That is the point
/// of routing every transport call through here: a peer that closes the connection before
/// answering surfaces as `ReaderClosed`, a reset surfaces as an `OSError`, and both are the same
/// condition as far as the caller is concerned — the request never got an answer, and asking
/// again could get one. A boundary that classified only the errors it happened to expect is how
/// a raw error type ends up on a reader's status line.
///
/// Generic in its result so it can stand in for any call: it never returns a value, it only
/// raises one of the two classified errors. Spelling that as `Unit` would force every call site
/// into a shape that discards a real result type.
fn[T] transport_failure(context : String, err : Error) -> T raise {
  if @async.is_cancellation_error(err) || @async.is_being_cancelled() {
    raise err
  }
  raise Transient("\{context}: \{err}")
}

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

///|
/// How much of an endpoint's explanation to show.
///
/// A few hundred characters carries `error.message`; the rest of a JSON error body is the envelope
/// and a request id. Bounded because this goes in front of a reader, and because an endpoint that
/// answers with a page of HTML should not become the whole message.
let error_detail_limit : Int = 600

///|
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
  // Connecting and sending are the two failures that say nothing about the request, so they are
  // transient: nothing about the answer was learned, and asking again is the only way to learn it.
  let client = try @http.post_stream(url, headers=http_headers) catch {
    err => transport_failure("could not reach \{url}", err)
  } noraise {
    client => client
  }
  defer client.close()
  try client.write(body) catch {
    err => transport_failure("could not send the request to \{url}", err)
  } noraise {
    _ => ()
  }
  // Waiting for the response headers is its own chance to hang: `end_request` blocks
  // until the status line arrives, which is *before* the first byte of the body. A
  // timeout around the read loop alone would leave the most likely stall — a
  // connection that was accepted and then forgotten — unbounded.
  //
  // It is also the one call that both writes and reads. The buffered writer holds the tail of the
  // body until this point, so a failure here can come from either direction: a socket that will
  // not take the rest of the request, or a peer that closed before answering. Both are classified,
  // and that is why this call goes through the same helper as the two around it rather than being
  // left bare — leaving it bare is what put `OSError("@socket.Tcp::write(): …")` in front of a
  // reader, and it is the kind of gap that reappears wherever a boundary is written by hand.
  let finishing : async () -> @http.Response = async fn() {
    try client.end_request() catch {
      err => transport_failure("could not send the request to \{url}", err)
    } noraise {
      response => response
    }
  }
  let response = match @async.with_timeout_opt(idle_timeout_ms, finishing) {
    Some(response) => response
    None =>
      raise Transient(
        "the model endpoint sent no response within \{idle_timeout_ms}ms",
      )
  }
  if response.code != 200 {
    // The endpoint's own words, not only its status line. A 400 is the endpoint saying what is wrong
    // with the request, and none of that is inferable from `400` alone — see `read_error_body`.
    let detail = read_error_body(client)
    let message = if detail == "" {
      "the model endpoint returned HTTP \{response.code}"
    } else {
      "the model endpoint returned HTTP \{response.code}: \{detail}"
    }
    if status_is_transient(response.code) {
      raise Transient(message)
    }
    raise Permanent(message)
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
        // A connection that breaks mid-response raises rather than returning a short read, and
        // whether that is worth retrying depends on how much of the answer already reached the
        // reader — which only the caller knows. So it is classified here as transient and left
        // for the caller to decide.
        try client.read(buffer, offset=0, max_len=buffer.length()) catch {
          err => transport_failure("the model stream broke mid-response", err)
        } noraise {
          count => count
        }
      }) {
      Some(count) => count
      None =>
        raise Transient(
          "the model stream sent nothing for \{idle_timeout_ms}ms",
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

///|
/// What an endpoint said when it answered with something other than 200.
///
/// A status line on its own is not a diagnosis. A 400 is the endpoint explaining what is wrong with
/// the request — an unanswered tool call, a field it will not take, a context that is too long — and
/// none of that is inferable from `400`. Measured: a session failed every turn with
/// "the model endpoint returned HTTP 400", and finding out why took a rebuilt request log; the answer
/// had been in the response body the whole time, thrown away one line after it arrived.
///
/// Bounded, because this goes in front of a reader, and an endpoint that answers with a page of HTML
/// should not become the whole message. Clipped at the end rather than the beginning: the reason is
/// in the first sentence of `error.message`, and it is the first thing an over-long body carries.
///
/// Failure to read is not itself an error: this runs on the path that is already reporting a failure,
/// and a second one raised from here would replace the endpoint's answer with a socket error.
async fn read_error_body(client : @http.Client) -> String {
  let buffer = FixedArray::make(4096, b'\x00')
  let collected = StringBuilder()
  let mut total = 0
  while total < error_detail_limit * 4 {
    let count = try
      client.read(buffer, offset=0, max_len=buffer.length())
    catch {
      _ => 0
    } noraise {
      count => count
    }
    if count <= 0 {
      break
    }
    let piece = FixedArray::make(count, b'\x00')
    for i in 0..<count {
      piece[i] = buffer[i]
    }
    collected.write_string(@utf8.decode_lossy(Bytes::from_array(piece)))
    total += count
  }
  clip_error_detail(collected.to_string())
}

///|
/// The endpoint's explanation, with the envelope taken off when it is the JSON envelope we expect.
///
/// `{"error":{"message":"..."}}` is what an OpenAI-compatible endpoint sends, and what a reader needs
/// from it is the sentence. Everything else — the type, the code, the request id — is for whoever is
/// reading the endpoint's docs, not for whoever is trying to get a turn to run.
fn clip_error_detail(raw : String) -> String {
  let text = raw.trim().to_owned()
  if text == "" {
    return ""
  }
  // Not JSON — an HTML error page, or a proxy's plain text — is shown as it came, because a reader
  // comparing it with the endpoint's docs is the person this message is for. `None` rather than a
  // return, so that everything below still applies: a page of HTML is exactly what the clip is for.
  let parsed = try @json.parse(text) catch {
    _ => None
  } noraise {
    json => Some(json)
  }
  let unwrapped = match parsed {
    None => text
    Some(Object(fields)) =>
      match fields.get("error") {
        Some(Object(error)) =>
          match error.get("message") {
            Some(String(message)) => message
            _ => text
          }
        Some(String(message)) => message
        _ =>
          match fields.get("message") {
            Some(String(message)) => message
            _ => text
          }
      }
    _ => text
  }
  if unwrapped.length() <= error_detail_limit {
    unwrapped
  } else {
    unwrapped[:error_detail_limit].to_owned() + "…"
  }
}
