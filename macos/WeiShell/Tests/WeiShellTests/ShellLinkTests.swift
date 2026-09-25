import XCTest

import WeiKit
import WeiShellC

/// The boundary, with the real runtime behind it.
///
/// Every other test here is about a value: an event decodes, a transcript becomes rows, a sidebar
/// becomes sections. This one is about the pipe — whether an app that has been told there is a shell
/// ever hears from it.
///
/// It exists because for a while it did not: `ShellClient` installed a reader and never called
/// `wei_set_emit`, so the C side had no sink and dropped every line. Nothing failed — the app
/// started, drew a window and sat on "starting…" — which is exactly the shape of bug a unit test
/// suite full of decoders cannot see. The fix was to make `Emit.install` register the callback too;
/// this test is what makes that permanent.
///
/// It boots a real MoonBit runtime on a real thread, against a store in a temporary directory, so it
/// must not run in the same process as anything that assumes the agent is not started.
@MainActor
final class ShellLinkTests: XCTestCase {
    /// Wait for `condition`, pumping the main run loop — which is what lets the shell's lines, hopped
    /// onto the main actor by `ShellClient`, actually run.
    private func wait(
        upTo seconds: TimeInterval = 15,
        for condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// The text of the last `note` row in the transcript, or `nil` when there is none.
    ///
    /// The MCP report and a compaction summary are both notes, so this reads the rows the client
    /// already decoded rather than reaching into the wire.
    private func noteText(in client: ShellClient) -> String? {
        client.conversation.rows.last(where: { $0.kind == .note })?.text
    }

    /// The form the shell speaks: POSIX `realpath`, because that is literally what the shell calls
    /// (`@platform.canonical_dir` → `@fs.realpath`).
    ///
    /// **Not `URL.resolvingSymlinksInPath()`**, which is what this started as and is subtly wrong for
    /// this purpose: Foundation strips the `/private` prefix for the standard temp trees, so it answers
    /// `/var/folders/…` where the shell answers `/private/var/folders/…`. That mismatch made this test
    /// report a failure whose own message showed the shell doing the right thing — the expected value was
    /// the wrong spelling, not the actual one.
    private func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func testAShellThatWasStartedIsHeardFrom() throws {
        // A store of this test's own: the real one belongs to whoever is running the tests, and a test
        // that writes into it is a test that can delete their conversations.
        let root = NSTemporaryDirectory() + "wei-shell-link-\(UUID().uuidString)"
        setenv("WEI_STORE", root, 1)
        // A home of its own for the same reason, and because it decides which settings file is read:
        // this test must not care whether the machine it runs on has a saved key.
        setenv("HOME", root + "-home", 1)

        let client = ShellClient()
        client.start()

        // The three events the shell sends before it does anything else. Waiting for all of them is
        // waiting for the pipe in both directions a snapshot needs: `settings` is asked for at startup
        // and pushed, and `session` is what says a conversation is open.
        //
        // **Deliberately not "the sidebar filled in".** That was the old condition, and it only ever
        // became true because of a bug: with a store that has nothing in it, this shell opened a session
        // that has not been written, and `say_sessions` *invented a workspace* to hold it — so the
        // process that had never been told where to work drew a sidebar with one row in it. That row is
        // gone (`carry_current` in `macos/appffi/sessions.mbt`; the rule has a test of its own in
        // `macos/appffi/app_wbtest.mbt`), and a store with nothing in it now lists nothing, which is what
        // a first run should see.
        XCTAssertTrue(
            wait(for: { client.settings != nil && !client.currentPath.isEmpty }),
            "the shell was started but never heard from: state=\(client.state)"
        )
        XCTAssertNotEqual(client.state, .starting)

        // And the other direction: a command the host sends is one the shell reads. `/new` opens a
        // session in the project that is open, so a *different* session path coming back proves the
        // round trip. The path rather than the list, for the reason above: this store has no workspaces
        // in it yet, so what changed is the session and not the sidebar.
        let before = client.currentPath
        client.newSession()
        XCTAssertTrue(
            wait(for: { client.currentPath != before }),
            "the shell did not answer a command"
        )

        // ── and the part that is about *which project*, which is where this went wrong ──────────
        //
        // A new session opens in the project it names. It used to open in the project of the session on
        // screen, because the command carried no project at all: the window's middle column lists one
        // project while the open session can be in another, and only the window knows which of the two
        // the reader is looking at. The symptom was the session landing in the old project *and* the
        // window's own selection jumping back there, since it follows `currentPath`.
        //
        // It lives in this method rather than in a second one because a MoonBit runtime boots once per
        // process — its event loop is global — and this class is that process's one owner. Two test
        // methods here would be two boots.
        //
        // Two projects, created here because the shell checks the directory exists before it opens
        // anything in it.
        let projA = root + "-proj-a"
        let projB = root + "-proj-b"
        for dir in [projA, projB] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Phase one: make A the open project, by adding it. This is the state the bug needed — a session
        // open in A — because "wherever the session on screen is" was the old answer, and it is correct
        // here: this is the command that *means* "add this folder".
        client.addWorkspace(projA)
        XCTAssertTrue(
            wait(for: { client.currentWorkspace == self.canonical(projA) }),
            "the shell did not open a session in the folder it was given: \(client.currentWorkspace)"
        )

        // Phase two: the bug. Name B — a project that is not in the sidebar — and the session has to open
        // *there*. Before the fix this assertion read `\(canonical(projA))`, because the command carried no
        // project and the shell fell back to the session on screen.
        //
        // B is also the case that keeps `carry_current` honest from the other side: a session in a folder
        // the store does not list would have no group to be listed under, so naming a folder for a new
        // session is what records it as a workspace (`note_workspace`, `macos/appffi/sessions.mbt`). That
        // is why this assertion still has something to read.
        client.newSession(in: projB)
        XCTAssertTrue(
            wait(for: { client.currentWorkspace == self.canonical(projB) }),
            "the new session did not open in the project it named — it is in \(client.currentWorkspace)"
        )
        XCTAssertNotEqual(
            client.currentWorkspace,
            canonical(projA),
            "the new session opened in the project that was already open"
        )

        // ── pinning, which is a command, a file and a flag on a row ──────────────────────────────
        //
        // The whole path in one place, because the three halves live in three languages: `pinned`
        // crosses on the `sessions` line, the flag is `pins.json` under this test's own HOME, and the
        // command is the one the context menu and the toolbar send. A pin that only the writer believed
        // in would be a menu item that appears to do nothing.
        let kept = client.currentPath
        client.setPinned(kept, to: true)
        XCTAssertTrue(
            wait(for: { client.sessions.first(where: { $0.path == kept })?.pinned == true }),
            "the shell did not report the pin on the row"
        )
        // And it is on disk, beside the settings, as a plain list of paths — what a reader finds if they
        // go looking, and what makes the pin outlive the process.
        let pinsFile = root + "-home" + "/.wei/pins.json"
        XCTAssertEqual(try? String(contentsOfFile: pinsFile, encoding: .utf8), "[\"\(kept)\"]\n")

        client.setPinned(kept, to: false)
        XCTAssertTrue(
            wait(for: { client.sessions.first(where: { $0.path == kept })?.pinned == false }),
            "the shell did not report the pin coming off"
        )
        XCTAssertEqual(try? String(contentsOfFile: pinsFile, encoding: .utf8), "[]\n")

        // ── the thinking level, which is a per-model fact travelling as a session setting ────────
        //
        // Three things in one place, and they are the reason this is not a menu drawn by the host: the
        // list of levels comes from the shell, the choice goes back as a *request*, and the answer to
        // that request is clamped by the model the session is on. The last of those is the one worth a
        // real round trip — `low` is flash's level and not the pro model's, so switching models is what
        // makes the difference between "a level that is offered" and "a level that will be sent".
        XCTAssertTrue(
            wait(for: { client.thinking.items.contains(where: { $0.id == "low" }) }),
            "the shell never said which levels this model has: \(client.thinking)"
        )
        // `high` is what this repository has always asked for, so it is where a session starts — the
        // reader's last choice is inherited by a *new session*, and this one is new, which is the same
        // rule the model picker follows.
        XCTAssertEqual(client.thinking.current, "high")
        XCTAssertTrue(client.thinking.currentLevel?.isDefault == true)

        client.setThinkLevel("low")
        XCTAssertTrue(
            wait(for: { client.thinking.current == "low" }),
            "the shell did not take the level: \(client.thinking.current)"
        )

        // And now a model that has no `low`. The command is accepted (it is a level this build knows)
        // and the level that will really be asked for is the new model's default — not `low`, which
        // would be a request the API refuses. Nothing here writes to the log: the driver records the
        // level at the top of the next turn, which is the only moment it is true.
        client.setModel("deepseek-v4-pro")
        XCTAssertTrue(
            wait(for: { client.thinking.current == "high" && client.catalog.current == "deepseek-v4-pro" }),
            "the level survived a model that does not have it: \(client.thinking)"
        )
        XCTAssertFalse(
            client.thinking.items.contains(where: { $0.id == "low" }),
            "the pro model was offered a level it does not have"
        )
        // Turning it off is offered by every model, and is a level rather than the absence of one —
        // which is what makes it recordable, and what the driver test for the disabled form covers.
        client.setThinkLevel("off")
        XCTAssertTrue(
            wait(for: { client.thinking.current == "off" }),
            "off is a level like any other: \(client.thinking.current)"
        )

        // ── MCP, which is a config file, a child process and a panel row ─────────────────────────
        //
        // The whole path in one place, and every link of it is real: the `.mcp.json` is written by this
        // test into a project before the shell has looked at it, the server is a `python3` child the
        // shell spawns and handshakes with, and the row that comes back crosses the C boundary as a
        // field. Nothing here would have been caught by a unit test at one layer — the panel is drawn
        // from a file that a *different* layer read.
        let serverScript = root + "-mcp-server.py"
        // A hand-written server rather than an installed one: what is under test is the shell's own
        // half — the config it reads, the process it starts, the handshake it performs and the row it
        // draws — and a real server would make this a test of somebody else's release schedule. It
        // answers exactly one tool so that the tool count on the row has something to be wrong about.
        let serverSource = """
        import sys, json
        def send(p):
            sys.stdout.write(json.dumps(p) + "\\n")
            sys.stdout.flush()
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            m = msg.get("method")
            if m == "initialize":
                send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "echo", "version": "1"}}})
            elif m == "tools/list":
                send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": [
                    {"name": "say", "description": "Say it back.",
                     "inputSchema": {"type": "object"}}]}})
        """
        let config = """
        {"mcpServers":{"echo":{"command":"python3","args":["\(serverScript)"],"description":"Says things back."}}}
        """
        try? serverSource.write(
            toFile: serverScript, atomically: true, encoding: .utf8
        )
        try? config.write(
            toFile: projB + "/.mcp.json", atomically: true, encoding: .utf8
        )

        // Switching to B is what makes the shell look: `mcp_ensure` runs at the top of every command,
        // for the directory on screen. Then `/settings` is what re-reads the panel.
        client.newSession(in: projB)
        XCTAssertTrue(
            wait(for: { client.currentWorkspace == self.canonical(projB) }),
            "the session did not move to the project with the config"
        )
        client.refreshSettings()
        XCTAssertTrue(
            wait(for: { !(client.settings?.servers.isEmpty ?? true) }),
            "the shell never reported the MCP server: \(String(describing: client.settings?.servers))"
        )
        let server = try XCTUnwrap(client.settings?.servers.first)
        XCTAssertEqual(server.name, "echo")
        XCTAssertEqual(server.transport, "stdio")
        XCTAssertEqual(server.description, "Says things back.")
        XCTAssertTrue(server.enabled)
        // One tool, handshaked for real: the count is the server's answer, not a guess from the config.
        XCTAssertEqual(server.toolCount, 1)
        XCTAssertEqual(server.status, "1 tool")
        XCTAssertTrue(server.note.isEmpty, "a server that came up has nothing to explain: \(server.note)")

        // The switch is a command, and the row follows it. The process stays up — see `mcp_ensure`
        // for why that is deliberate — so what changes is what a turn may reach, which the panel
        // reports as `off`.
        client.toggleServer("echo")
        XCTAssertTrue(
            wait(for: {
                client.settings?.servers.first(where: { $0.name == "echo" })?.enabled == false
            }),
            "the switch did not come back on the row"
        )
        client.toggleServer("echo")
        XCTAssertTrue(
            wait(for: {
                client.settings?.servers.first(where: { $0.name == "echo" })?.enabled == true
            }),
            "switching it back on did not come back on the row"
        )

        // And `/mcp` answers with the workspace's servers, as a labelled note in the transcript —
        // which is the one place a *failed* server's reason would be readable.
        client.reportMcp()
        XCTAssertTrue(
            wait(for: { self.noteText(in: client)?.contains("echo") == true }),
            "`/mcp` said nothing about the server"
        )
        let report = try XCTUnwrap(self.noteText(in: client))
        XCTAssertTrue(report.contains("1 tool(s)"), report)

        // Stops the agent thread rather than leaving it to the process exit: the runtime has an event
        // loop of its own, and a test process that ends with one still spinning is a test process
        // somebody later finds hanging.
        wei_send("quit")
    }
}
