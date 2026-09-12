///|
/// The HTTP surface.
///
/// Four routes, and the smallest set that can work:
///
/// - `GET /`          the page, with whatever conversation already exists
/// - `GET /events`    an SSE stream of patches
/// - `POST /prompt`   a user message
/// - `POST /session`  switch to another saved session, or start a new one
/// - `POST /abort`    stop the running turn
///
/// The POST routes answer immediately and the work happens behind them. A turn
/// can take minutes; a request that waits for it to finish makes the browser look
/// hung and, worse, invites the client to treat "still working" as "failed". The
/// transport therefore never owns the turn — it hands it to the application and
/// returns.

///|
/// Everything the transport needs from the application.
pub(all) struct Routes {
  /// Renders the page as it stands. Called for the initial request.
  ///
  /// Async because rendering the sidebar reads the store: describing the saved
  /// sessions is the one part of the page that is not a pure function of the
  /// in-memory conversation.
  page : async () -> String
  /// Patches that bring a connected client up to date: the transcript, the
  /// session list, the status line.
  ///
  /// One definition of what can change, used both for the first frame of every
  /// connection and after any change too large to describe as a smaller patch.
  /// Without it a reconnect would need a second, parallel notion of the page, and
  /// the two would drift.
  regions : async () -> Array[@html.Patch]
  /// Queues one user message. Doesn't wait for the turn to run.
  ///
  /// Async only because broadcasting a frame is; nothing here blocks on the turn.
  prompt : async (String) -> Unit
  /// Asks the running turn to stop.
  ///
  /// A request rather than a cancellation: the turn checks it between steps and
  /// while reading the model's response, so the process never abandons a tool that
  /// has already started.
  abort : () -> Unit
  /// Switches the session every client is looking at. An empty path means a new
  /// session.
  switch_session : (String) -> Unit
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
/// Answer a request whose work happens elsewhere.
async fn ok(conn : @http.ServerConnection) -> Unit {
  conn.send_response(200, "OK", extra_headers={ "Content-Type": "text/plain" })
  conn.write_string("ok")
  conn.end_response()
}

///|
/// Serve one SSE subscriber until it goes away.
///
/// The first frames are the whole mutable page, so a client that connects
/// mid-turn — or reconnects after the process restarted — converges on the current
/// state rather than missing everything that happened before it arrived.
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
  // Before any live patch can arrive: subscribing first would let a broadcast
  // overtake the snapshot and be overwritten by it.
  let snapshot = (routes.regions)()
  for patch in snapshot {
    conn.write_string(patch.to_sse())
  }
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
        ok(conn)
      }
      (Post, "/prompt") => {
        let prompt = read_body(body)
        ok(conn)
        (routes.prompt)(prompt)
      }
      (Post, "/session") => {
        let path = read_body(body)
        ok(conn)
        (routes.switch_session)(path)
      }
      _ => not_found(conn)
    }
  })
}
