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

///|
/// Every way a request can fail must arrive as a classified error, not as a raw one.
///
/// This is a regression test for a real failure a reader saw:
///
/// ```text
/// failed: OSError("@socket.Tcp::write(): Resource temporarily unavailable")
/// ```
///
/// The cause was a boundary that classified two of its three calls. `end_request` — the call that
/// flushes the rest of the buffered body *and* waits for the status line — was left bare, so an
/// error raised from inside it escaped as itself and reached the status line as an `OSError` no
/// reader can act on.
///
/// A table of shapes rather than one case, because the error type depends on how the peer went
/// away and on where in the exchange the write landed: a reset surfaces as an `OSError`, a clean
/// close as `ReaderClosed`, and a body large enough to overflow the send buffer fails during the
/// write rather than during `end_request`. The assertion for all of them is the same and is the
/// only one that matters to a caller: it is a `ModelError`, so the driver's retry policy can see
/// it — and, for the reason above, none of them is a cancellation.

///|
/// A cancelled request is a cancellation, not a failure worth retrying.
///
/// This is the other half of the classification rule, and it is not cosmetic: a cancelled turn
/// means the reader stopped wanting the answer — or the process is shutting down — and the driver
/// retries a `Transient` failure. Classifying cancellation as transient would answer "stop" with
/// "ask the model again", spending tokens on an answer nobody is waiting for.
///
/// Cancellation is an ordinary error in this runtime, so there is nothing about it that a bare
/// `catch` would notice; the guard has to be explicit. Removing it makes this test report
/// `Transient`, which is exactly the bug it exists to prevent.
async test "cancelling a request surfaces as a cancellation, not as a retryable failure" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  let observed = Ref("the request never came back")
  @async.with_task_group(group => {
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
    // Cancel from outside while the request is blocked waiting for a response. The inner idle
    // timeout is long enough that only the cancellation can end the call.
    ignore(
      try
        @async.with_timeout(250, async fn() {
          observed.val = try {
            post_sse(
              "http://127.0.0.1:\{port}/chat/completions",
              Map([("Content-Type", "application/json")]),
              "{\"model\":\"m\"}",
              chunk => ignore(chunk),
              idle_timeout_ms=30000,
            )
            "completed without error"
          } catch {
            @platform.Transient(_) => "Transient — the turn would be retried"
            @platform.Permanent(_) => "Permanent"
            err =>
              if @async.is_cancellation_error(err) {
                "cancelled"
              } else {
                "UNCLASSIFIED: \{err}"
              }
          } noraise {
            result => result
          }
        })
      catch {
        _ => ()
      } noraise {
        _ => ()
      },
    )
    server.close()
  })
  assert_eq(observed.val, "cancelled")
}

///|
async test "every transport failure is classified rather than escaping raw" {
  // Each shape: how much request body to send, and whether the server closes without reading it.
  // The pairs cover the error types a peer can produce — a reset, a clean close, and writes that
  // land during the body (large) versus during end_request's flush (small).
  let sizes = [0, 16, 4096, 1048576]
  for size in sizes {
    for close_early in [true, false] {
      let label = "size=\{size} " +
        (if close_early { "closed before reading" } else { "read then closed" })
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let port = server.addr.port()
      @async.with_task_group(group => {
        ignore(
          group.spawn(
            () => {
              let (tcp, _) = server.accept()
              if !close_early {
                // Read the request line so the write path succeeds, then close without answering.
                let _ = tcp.read_until("\r\n\r\n")
              }
              tcp.close()
            },
            no_wait=true,
          ),
        )
        @async.sleep(20)
        let body = StringBuilder()
        body.write_string("{\"model\":\"m\",\"pad\":\"")
        for _ in 0..<size {
          body.write_string("x")
        }
        body.write_string("\"}")
        let outcome = try {
          post_sse(
            "http://127.0.0.1:\{port}/chat/completions",
            Map([("Content-Type", "application/json")]),
            body.to_string(),
            chunk => ignore(chunk),
            idle_timeout_ms=1500,
          )
          "no error at all"
        } catch {
          @platform.Transient(_) => "Transient"
          @platform.Permanent(_) => "Permanent"
          err =>
            if @async.is_cancellation_error(err) {
              "cancellation leaked"
            } else {
              "UNCLASSIFIED: \{err}"
            }
        } noraise {
          result => result
        }
        assert_true(
          outcome == "Transient",
          msg="\{label}: expected a transient failure, got \{outcome}",
        )
        server.close()
      })
    }
  }
}
