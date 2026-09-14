///|
/// The HTTP surface.
///
/// Four routes, and the smallest set that can work:
///
/// - `GET /`          the page, with whatever conversation already exists
/// - `GET /events`    an SSE stream of patches
/// - `POST /prompt`   a user message
/// - `POST /session`  open a saved session (of any workspace)
/// - `POST /workspace` add a directory as a workspace
/// - `POST /workspace/pick` open the host's folder chooser and add what it returns
/// - `POST /new`      start a new session in a workspace
/// - `POST /more`     lift the session-list cap for one workspace
/// - `POST /abort`    stop the running turn
/// - `POST /settings/key`    save or clear the key the panel writes
/// - `POST /settings/skills` apply the set of enabled skills
/// - `POST /settings/limits` set or clear the two turn limits
/// - `POST /model`    switch the displayed session's model
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
  /// Async like the rest: asking a session to stop tells everyone watching about it.
  abort : async (String) -> Unit
  /// Opens the session at this path, and moves the agent into its workspace.
  ///
  /// Async for the same reason `prompt` is: leaving one session for another is
  /// something the reader may need to be told about while it happens.
  switch_session : async (String) -> Unit
  /// Starts a new session in this working directory. Separate from opening one
  /// because "a directory" and "a session file" would otherwise have to be told
  /// apart by inspecting the path.
  new_session : async (String) -> Unit
  /// Stops a background job, by id.
  kill_job : async (String) -> Unit
  /// Adds a directory as a workspace. Reports why not through the status line when the path
  /// does not name a directory.
  add_workspace : async (String) -> Unit
  /// Asks the host to open its folder chooser, and adds whatever comes back.
  ///
  /// No body: the answer to a dialog is not in the request, and the reader is the one choosing.
  /// Async because the dialog is waited on — this is the one route whose handler outlives its
  /// response on purpose.
  choose_workspace : async () -> Unit
  /// Renames the displayed session to the body, verbatim.
  ///
  /// Passed through as typed, like `prompt`: the `/name` command reaches the same rename with the
  /// same undecoded text, and a second decoding convention would be a second thing to keep true.
  rename : async (String) -> Unit
  /// Takes one saved session out of the store by renaming it aside, so it can be put back.
  ///
  /// The body is the session's path, which the sidebar already holds — the identity used for opening
  /// is the file, not the id, and deleting uses the same one for the same reason.
  delete_session : async (String) -> Unit
  /// Lists every session of a workspace, past the sidebar's cap. The body is the working
  /// directory, which is what a workspace is addressed by everywhere else.
  more : async (String) -> Unit
  /// Puts the last deleted session back. The body is the path it had.
  undo_delete : async (String) -> Unit
  /// Shows more of the displayed session's conversation. No body: the session is the one on screen,
  /// and the window is a property of it.
  earlier : async () -> Unit
  /// Switches the displayed session to the model named in the body, which is one id.
  ///
  /// Its own route rather than a settings form: the model is a property of a session, not of the
  /// process, so it is not something `~/.pi-mb/settings.json` holds and it must not go through the
  /// panel's settings lock.
  set_model : async (String) -> Unit
  /// Resumes the interrupted turn of the displayed session.
  ///
  /// The body names the session; empty means the one on screen, like `abort`. Its own route rather
  /// than part of `prompt`, because it is the one gesture that does NOT carry a new message: the
  /// prompt it continues is already in the log, and sending it again would append a second copy.
  continue_turn : async (String) -> Unit
  /// Closes the displayed session's interrupted turn without resuming it.
  ///
  /// The other half of the same choice. It writes an outcome rather than doing nothing, because
  /// otherwise the turn stays open forever and the notice keeps coming back.
  dismiss_turn : async (String) -> Unit
  /// Handles one POST from the settings panel: `saved key=…&clear=1` or `skill=a&skill=b`.
  ///
  /// One entry point rather than two, because the two forms differ only in a field name and a
  /// second variant of `Routes` would be a second thing to wire up and test. The body is passed
  /// through as the form-encoded text the browser sent, and decoding it is the application's
  /// business — the transport has no opinion about what a key or a skill is.
  settings : async (String) -> Unit
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
/// How often an idle patch stream says something anyway.
///
/// A live stream is silent for as long as nothing changes, and a long tool call changes nothing for
/// minutes. Silence is indistinguishable from a dead connection at *both* ends: the browser has no
/// reason to reconnect, because `EventSource` only retries after an error, and a half-open socket
/// produces no error until a write finally fails — which on a quiet connection can be many minutes,
/// or never.
///
/// The reader's symptom is a page frozen on "running" that a manual reload fixes, because
/// reconnecting fetches the whole snapshot. That is the failure this bounds.
pub fn heartbeat_interval_ms() -> Int {
  15000
}

///|
/// The frame that says "still here" when there is nothing else to say.
///
/// A named event rather than an SSE comment (`: ping`). A comment is legal and cheaper, but
/// `EventSource` discards comments without firing anything — so the client, the one party that needs
/// to observe the heartbeat, would never see it. The name is what makes liveness checkable from the
/// page.
pub fn heartbeat_frame() -> String {
  "event: ping\ndata: {}\n\n"
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
  heartbeat_ms : Int,
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
  @async.with_task_group(group => {
    // The heartbeat is put into the subscriber's own queue rather than written to the socket from
    // here, and the reason is the second one: there is exactly one writer, so a ping cannot land in
    // the middle of a frame's bytes; and the read stays a plain blocking read. Wrapping `queue.get()`
    // in a timeout would *cancel* it, and a frame arriving in that same instant would be lost —
    // trading a rare hang for a rare silently dropped patch.
    group.spawn_bg(no_wait=true, () => {
      while true {
        @async.sleep(heartbeat_ms)
        // A closed queue means the writer loop has ended and the group is being cancelled.
        try queue.put(heartbeat_frame()) catch {
          _ => ()
        } noraise {
          _ => ()
        }
      }
    })
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
  })
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
pub async fn serve(
  port : Int,
  hub : Hub,
  routes : Routes,
  /// How often an idle stream is told the connection is still there. A production default, and a
  /// parameter so a test can ask for a heartbeat it does not have to wait fifteen seconds for.
  heartbeat_ms? : Int = 15000,
) -> Unit {
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
      (Get, "/events") => stream_events(conn, hub, routes, heartbeat_ms)
      (Post, "/abort") => {
        // The body names the session to stop; empty means the one on screen.
        let target = read_body(body)
        (routes.abort)(target.trim().to_owned())
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
      (Post, "/name") => {
        let name = read_body(body)
        ok(conn)
        (routes.rename)(name)
      }
      (Post, "/earlier") => {
        ok(conn)
        (routes.earlier)()
      }
      (Post, "/session/delete") => {
        let path = read_body(body)
        ok(conn)
        (routes.delete_session)(path)
      }
      (Post, "/session/undo") => {
        let path = read_body(body)
        ok(conn)
        (routes.undo_delete)(path)
      }
      (Post, "/more") => {
        let cwd = read_body(body)
        ok(conn)
        (routes.more)(cwd.trim().to_owned())
      }
      (Post, "/new") => {
        let cwd = read_body(body)
        ok(conn)
        (routes.new_session)(cwd)
      }
      (Post, "/job/kill") => {
        let id = read_body(body)
        ok(conn)
        (routes.kill_job)(id.trim().to_owned())
      }
      (Post, "/continue") => {
        let target = read_body(body)
        ok(conn)
        (routes.continue_turn)(target.trim().to_owned())
      }
      (Post, "/dismiss") => {
        let target = read_body(body)
        ok(conn)
        (routes.dismiss_turn)(target.trim().to_owned())
      }
      (Post, "/model") => {
        let id = read_body(body)
        ok(conn)
        (routes.set_model)(id.trim().to_owned())
      }
      (Post, "/workspace") => {
        let cwd = read_body(body)
        ok(conn)
        (routes.add_workspace)(cwd.trim().to_owned())
      }
      (Post, "/workspace/pick") => {
        // Drained before answering for the same reason as every other POST: the body belongs to the
        // request, and a handler that runs before it has been read is racing the connection.
        ignore(read_body(body))
        ok(conn)
        (routes.choose_workspace)()
      }
      // One handler for both settings forms: the path says which, and the body is the
      // form-encoded fields the browser sent.
      (Post, "/settings/key")
      | (Post, "/settings/skills")
      | (Post, "/settings/limits")
      | (Post, "/settings/agents") => {
        let text = read_body(body)
        ok(conn)
        (routes.settings)(text)
      }
      _ => not_found(conn)
    }
  })
}
