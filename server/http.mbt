///|
/// The HTTP surface.
///
/// Three routes, and the smallest one that can work:
///
/// - `GET /`         the page, with whatever conversation already exists
/// - `GET /events`   an SSE stream of patches
/// - `POST /prompt`  a user message, which runs a turn to completion
///
/// `POST /prompt` blocks until the turn finishes and its output goes out over the
/// SSE stream rather than as the response body. The browser sends it without
/// awaiting, so a long turn never looks like a hung request.

///|
/// Everything the transport needs from the application.
pub(all) struct Routes {
  /// Renders the page as it stands. Called for the initial request and whenever a
  /// client reconnects, which is what makes a reconnect recover the full state
  /// without a separate snapshot protocol.
  page : () -> String
  /// Runs one turn. Output is expected to reach clients through the hub.
  prompt : async (String) -> Unit
  /// Asks the running turn to stop.
  ///
  /// A request rather than a cancellation: the turn checks it between steps and
  /// while reading the model's response, so the process never abandons a tool that
  /// has already started.
  abort : () -> Unit
}

///|
/// A 404 with a plain body. Not worth a template.
async fn not_found(conn : @http.ServerConnection) -> Unit {
  conn.send_response(404, "Not Found", extra_headers={
    "Content-Type": "text/plain",
  })
  conn.write_string("not found")
  conn.end_response()
}

///|
/// Serve one SSE subscriber until it goes away.
///
/// The first frame is the whole page body, so a client that connects mid-turn —
/// or reconnects after the process restarted — converges on the current state
/// rather than missing everything that happened before it arrived.
async fn stream_events(
  conn : @http.ServerConnection,
  hub : Hub,
  routes : Routes,
) -> Unit {
  conn.send_response(200, "OK", extra_headers={
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
  })
  let (id, queue) = hub.subscribe()
  // Send the current document first, before any patch can arrive.
  conn.write_string(
    @html.Patch::Replace(target="transcript", html=(routes.page)()).to_sse(),
  )
  conn.flush()
  // A failure here means the browser went away; there is nothing to report, only
  // a subscriber to remove.
  let alive = try {
    while true {
      let frame = queue.get()
      conn.write_string(frame)
      conn.flush()
    }
    true
  } catch {
    _ => false
  } noraise {
    _ => true
  }
  hub.unsubscribe(id)
  ignore(alive)
  conn.end_response()
}

///|
/// Read a request body as text.
async fn read_body(body : &@io.Reader) -> String {
  let data = body.read_all()
  @utf8.decode_lossy(data.binary())
}

///|
/// Run the server until cancelled.
pub async fn serve(port : Int, hub : Hub, routes : Routes) -> Unit {
  // `reuse_addr` so a restart does not fail on a socket still in TIME_WAIT. Without
  // it, stopping and starting within a minute is enough to hit
  // "Address already in use" with nothing actually listening.
  let server = @http.Server(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  server.run_forever((request, body, conn) => {
    match (request.meth, request.path) {
      (Get, "/") => {
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/html; charset=utf-8",
        })
        conn.write_string((routes.page)())
        conn.end_response()
      }
      (Get, "/events") => stream_events(conn, hub, routes)
      (Post, "/abort") => {
        (routes.abort)()
        conn.send_response(200, "OK", extra_headers={ "Content-Type": "text/plain" })
        conn.write_string("ok")
        conn.end_response()
      }
      (Post, "/prompt") => {
        let prompt = read_body(body)
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/plain",
        })
        conn.write_string("ok")
        conn.end_response()
        // After the response, so the browser is not left waiting on a turn that
        // takes a minute.
        (routes.prompt)(prompt)
      }
      _ => not_found(conn)
    }
  })
}
