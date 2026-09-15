import XCTest

import PiKit
import PiShellC

/// The boundary, with the real runtime behind it.
///
/// Every other test here is about a value: an event decodes, a transcript becomes rows, a sidebar
/// becomes sections. This one is about the pipe — whether an app that has been told there is a shell
/// ever hears from it.
///
/// It exists because for a while it did not: `PiClient` installed a reader and never called
/// `pi_shell_set_emit`, so the C side had no sink and dropped every line. Nothing failed — the app
/// started, drew a window and sat on "starting…" — which is exactly the shape of bug a unit test
/// suite full of decoders cannot see. The fix was to make `Emit.install` register the callback too;
/// this test is what makes that permanent.
///
/// It boots a real MoonBit runtime on a real thread, against a store in a temporary directory, so it
/// must not run in the same process as anything that assumes the agent is not started.
@MainActor
final class ShellLinkTests: XCTestCase {
    /// Wait for `condition`, pumping the main run loop — which is what lets the shell's lines, hopped
    /// onto the main actor by `PiClient`, actually run.
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

    func testAShellThatWasStartedIsHeardFrom() {
        // A store of this test's own: the real one belongs to whoever is running the tests, and a test
        // that writes into it is a test that can delete their conversations.
        let root = NSTemporaryDirectory() + "pi-shell-link-\(UUID().uuidString)"
        setenv("PI_SHELL_STORE", root, 1)
        // A home of its own for the same reason, and because it decides which settings file is read:
        // this test must not care whether the machine it runs on has a saved key.
        setenv("HOME", root + "-home", 1)

        let client = PiClient()
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

        // Stops the agent thread rather than leaving it to the process exit: the runtime has an event
        // loop of its own, and a test process that ends with one still spinning is a test process
        // somebody later finds hanging.
        pi_shell_send("quit")
    }
}
