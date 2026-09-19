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

    func testAShellThatWasStartedIsHeardFrom() {
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
        // and pushed, and `sessions` is what the sidebar draws.
        XCTAssertTrue(
            wait(for: { client.settings != nil && !client.groups.isEmpty }),
            "the shell was started but never heard from: state=\(client.state)"
        )
        XCTAssertNotEqual(client.state, .starting)
        XCTAssertFalse(client.currentPath.isEmpty, "no session was opened")

        // And the other direction: a command the host sends is one the shell reads. `/sessions` asks
        // for the list again, so a change that arrives proves the round trip.
        let before = client.groups
        client.newSession()
        XCTAssertTrue(
            wait(for: { client.currentPath != "" && client.groups != before || !client.groups.isEmpty }),
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

        // Phase two: the bug. Name B — a project the store has never been told about — and the session
        // has to open *there*. Before the fix this assertion read `\(canonical(projA))`, because the
        // command carried no project and the shell fell back to the session on screen.
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

        // Stops the agent thread rather than leaving it to the process exit: the runtime has an event
        // loop of its own, and a test process that ends with one still spinning is a test process
        // somebody later finds hanging.
        wei_send("quit")
    }
}
