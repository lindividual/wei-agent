///|
/// Spike: verify MoonBit native async can serve HTTP + upgrade WebSocket
/// and bridge a spawned child process over a bidirectional pipe.
const SPIKE_PAGE : String =
  #|<!DOCTYPE html>
  #|<html><head><meta charset="utf-8"><title>pi-web-shell spike</title></head>
  #|<body>
  #|<h1>pi-web-shell spike</h1>
  #|<pre id="log"></pre>
  #|<script>
  #|const log = (s) => { document.getElementById('log').textContent += s + "\n"; };
  #|const ws = new WebSocket(`ws://${location.host}/ws`);
  #|ws.onopen = () => { log("[open]"); ws.send("hello from browser"); };
  #|ws.onmessage = (e) => log("[recv] " + e.data);
  #|ws.onclose = () => log("[closed]");
  #|</script>
  #|</body></html>

///|
async fn main_serve(port : Int) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:\{port}")
  let server = @http.Server(addr)
  println("spike listening on http://127.0.0.1:\{port}")
  server.run_forever((request, _body, conn) => {
    if request.path == "/ws" {
      handle_ws(request, conn)
    } else {
      conn
      ..send_response(200, "OK", extra_headers={
        "Content-Type": "text/html; charset=utf-8",
      })
      ..write(SPIKE_PAGE)
      .end_response()
    }
  })
}

///|
/// Bridge one browser WebSocket to one child process over pipes.
async fn handle_ws(
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let ws = @websocket.from_http_server(request, conn)
  defer ws.close()
  try @async.with_task_group(group => {
    let (child_stdin, we_write) = @process.write_to_process()
    let (we_read, child_stdout) = @process.read_from_process()
    // Stand-in for `pi --mode rpc`: echo every line back, prefixed.
    @process.spawn(
      group,
      "sh",
      ["-c", "while IFS= read -r line; do printf 'echo:%s\\n' \"$line\"; done"],
      stdin=child_stdin,
      stdout=child_stdout,
    )
    |> ignore
    // Upstream: browser -> child stdin
    group.spawn_bg(() => {
      for ;; {
        let msg = ws.recv()
        we_write.write(msg.read_all().text())
        we_write.write("\n")
      }
    })
    // Downstream: child stdout -> browser
    for ;; {
      match we_read.read_until("\n") {
        Some(line) => ws.send_text(line)
        None => break
      }
    }
  }) catch {
    @websocket.ConnectionClosed(_, reason) =>
      println("client disconnected: \{@debug.to_string(reason)}")
    e => println("ws error: \{e}")
  }
}

///|
async fn main {
  main_serve(8899)
}
