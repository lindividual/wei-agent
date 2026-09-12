///|
/// A model stream that goes quiet must fail rather than wait forever.
///
/// This is the difference between a slow turn and a frozen one. The worker that runs
/// turns is single-threaded: a read that never returns does not just hang this turn, it
/// leaves every request behind it queued for the life of the process, with the page
/// showing nothing to explain why.
///
/// A real socket that accepts a request and then says nothing, rather than a mock: the
/// timeout has to interrupt an actual blocked read.
async test "a silent stream times out instead of hanging" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group(group => {
    // Accept, read the request, then stay silent. Cancelled when the test ends.
    ignore(
      group.spawn(
        () => {
          let (tcp, _) = server.accept()
          ignore(tcp.read_until("\r\n\r\n"))
          @async.sleep(60000)
          tcp.close()
        },
        no_wait=true,
      ),
    )
    @async.sleep(20)
    let started = @env.now()
    let failed = try {
      post_sse(
        "http://127.0.0.1:\{port}/chat/completions",
        Map([("Content-Type", "application/json")]),
        "{\"model\":\"m\"}",
        chunk => ignore(chunk),
        idle_timeout_ms=300,
      )
      false
    } catch {
      _ => true
    } noraise {
      raised => raised
    }
    let elapsed = (@env.now() - started).reinterpret_as_int64()
    assert_true(failed, msg="a silent stream must raise")
    // Bounded by the timeout rather than by the test harness.
    assert_true(elapsed < 3000L, msg="took \{elapsed}ms")
    server.close()
  })
}
