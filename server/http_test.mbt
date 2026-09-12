///|
/// The transport, over a real socket.
///
/// The bug these tests exist to prevent was invisible from the application side: the
/// first frame of an SSE connection carried a whole HTML document where a fragment
/// was expected. It still rendered, after a fashion — the browser spliced the
/// document's contents into the body and quietly detached the composer — so nothing
/// failed except the page. Asserting on the bytes is the only way to see it.
///
/// A raw socket rather than an HTTP client, because an SSE stream never ends: reading
/// has to stop after the frames under test, and only a socket lets the test decide
/// that.

///|
/// A port nothing is listening on, for the test to take.
///
/// Bound and released rather than hardcoded: a fixed port makes the suite fail
/// whenever something else on the machine happens to hold it.
async fn free_port() -> Int {
  let probe = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = probe.addr.port()
  probe.close()
  port
}

///|
/// Run `body` with a server listening on a free port.
async fn with_server(routes : Routes, body : async (Int) -> Unit) -> Unit {
  let port = free_port()
  @async.with_task_group(group => {
    // `no_wait`: the server only ever stops when it is cancelled, so a group that
    // waits for it would wait for the test binary to be killed instead of
    // finishing the test.
    ignore(group.spawn(() => serve(port, Hub::new(), routes), no_wait=true))
    // The listener is up before the first connection, so a connect that succeeds
    // means the server is ready to serve it.
    @async.sleep(50)
    body(port)
  })
}

///|
/// Send a request and read up to `frames` SSE frames back.
///
/// Deadline-bounded rather than end-bounded: a stream that stays open is the normal
/// case here, and a test that waits for it would wait forever. Whatever arrived is
/// returned, so the assertions can say what was missing.
async fn read_frames(
  port : Int,
  request : String,
  frames : Int,
  timeout_ms : Int,
) -> String {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
  defer tcp.close()
  let mut text = ""
  try
    @async.with_timeout(timeout_ms, async fn() {
      tcp.write(request)
      for _ in 0..<frames {
        match tcp.read_until("\n\n") {
          Some(frame) => text = text + frame + "\n\n"
          None => break
        }
      }
    })
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
  text
}

///|
/// Send a request whose answer is a whole small response, and read it back.
///
/// Reads to the end of the headers and then takes whatever body is already there:
/// these responses are a status line plus a few bytes, so there is nothing to
/// track. Separate from `read_frames` because the delimiters differ — an SSE frame
/// ends in `\n\n`, an HTTP response's headers end in `\r\n\r\n`, and a reader
/// waiting for the wrong one waits forever.
async fn read_response(
  port : Int,
  request : String,
  timeout_ms : Int,
) -> String {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
  defer tcp.close()
  let mut text = ""
  try
    @async.with_timeout(timeout_ms, async fn() {
      tcp.write(request)
      match tcp.read_until("\r\n\r\n") {
        Some(headers) => text = headers
        None => ()
      }
      match tcp.read_some(max_len=4096) {
        Some(body) => text = text + @utf8.decode_lossy(body)
        None => ()
      }
    })
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
  text
}

///|
/// A minimal set of routes: enough to tell a fragment from a document, and to record
/// what the POSTs handed over.
fn routes_with(regions : Array[@html.Patch], seen : Array[String]) -> Routes {
  {
    page: fn() { "<html><body><div id=\"transcript\"></div></body></html>" },
    regions: fn() { regions },
    prompt: text => seen.push("prompt:\{text}"),
    abort: fn(path) { seen.push("abort:\{path}") },
    switch_session: path => seen.push("session:\{path}"),
    new_session: dir => seen.push("new:\{dir}"),
  }
}

///|
fn post_request(path : String, body : String) -> String {
  "POST \{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \{body.length()}\r\n\r\n\{body}"
}

///|
/// Every connection starts with the mutable regions, as patches for their own
/// elements.
///
/// The assertion that matters is the negative one: no frame may carry a document
/// skeleton. A frame containing `<html>` means the first frame is the whole page,
/// which is exactly what silently broke the composer.
async test "events starts with the region patches" {
  let regions = [
    @html.Patch::Replace(
      target="transcript",
      html="<div id=\"transcript\">hi</div>",
    ),
    @html.Patch::Replace(
      target="sessions",
      html="<aside id=\"sessions\"></aside>",
    ),
  ]
  let routes = routes_with(regions, [])
  with_server(routes, async fn(port) {
    let text = read_frames(
      port, "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", 2, 3000,
    )
    assert_true(text.contains("\"target\":\"transcript\""), msg=text)
    assert_true(text.contains("\"target\":\"sessions\""), msg=text)
    assert_true(text.contains("\"op\":\"replace\""), msg=text)
    assert_false(text.contains("<html"), msg=text)
  })
}

///|
/// A prompt is accepted without waiting for the turn, and reaches the application
/// exactly once.
///
/// Both halves matter: a route that ran the turn inside the request would look
/// identical to the browser until the turn took a minute, which is the failure this
/// shape exists to avoid.
async test "a prompt is handed off rather than run in the request" {
  let seen : Array[String] = []
  let routes = routes_with([], seen)
  with_server(routes, async fn(port) {
    let response = read_response(
      port,
      post_request("/prompt", "hello there"),
      3000,
    )
    assert_true(response.contains("200 OK"), msg=response)
    // The application is called after the response is written, so give it a beat.
    @async.sleep(50)
    assert_eq(seen, ["prompt:hello there"])
  })
}

///|
/// Abort, opening a session and starting one reach the application too, and are all
/// just as fire-and-forget.
async test "abort, open and new reach the application" {
  let seen : Array[String] = []
  let routes = routes_with([], seen)
  with_server(routes, async fn(port) {
    ignore(
      read_response(port, post_request("/abort", "/tmp/store/a.jsonl"), 3000),
    )
    let path = "/tmp/store/--tmp--/session.jsonl"
    ignore(read_response(port, post_request("/session", path), 3000))
    let cwd = "/tmp/another-project"
    ignore(read_response(port, post_request("/new", cwd), 3000))
    @async.sleep(50)
    assert_eq(seen, [
      "abort:/tmp/store/a.jsonl",
      "session:\{path}",
      "new:\{cwd}",
    ])
  })
}

///|
/// A live patch reaches the subscriber that is already connected.
///
/// This is the other half of the first frame: the snapshot must not replace the
/// stream, and a broadcast must not be swallowed by it.
async test "broadcasts reach a connected subscriber" {
  let hub = Hub::new()
  let routes = routes_with([], [])
  let port = free_port()
  @async.with_task_group(group => {
    ignore(group.spawn(() => serve(port, hub, routes), no_wait=true))
    ignore(
      group.spawn(() => {
        // Wait for the subscriber to arrive before broadcasting, otherwise the
        // frame is emitted into an empty subscriber list.
        while hub.count() == 0 {
          @async.sleep(10)
        }
        @async.sleep(50)
        hub.broadcast(@html.Patch::Status(text="working…").to_sse())
      }),
    )
    @async.sleep(50)
    let text = read_frames(
      port, "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", 3, 3000,
    )
    assert_true(text.contains("\"op\":\"status\""), msg=text)
    assert_true(text.contains("working"), msg=text)
  })
}

///|
/// An unknown path is a 404, not a silent success.
async test "unknown routes are refused" {
  let routes = routes_with([], [])
  with_server(routes, async fn(port) {
    let text = read_response(
      port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", 3000,
    )
    assert_true(text.contains("404"), msg=text)
  })
}
