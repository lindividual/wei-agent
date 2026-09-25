import XCTest

import WeiModel
@testable import WeiKit

/// What the updater is allowed to interrupt.
///
/// `ShellClient.isWorking` is the whole of the answer to "may this process restart now", and the answer
/// decides whether installing an update costs the reader a turn. The type that *asks* it — `Updater` —
/// cannot be tested: it is an app-target type whose job is to talk to Sparkle, and everything it does is
/// Sparkle's. So the question is written down where it can be, and the case worth having a test for is
/// the one nothing on screen would show: a turn running in a session the reader is not looking at still
/// counts, because restarting the process destroys it just the same.
///
/// The wire literals are the ones the other routing tests use, which are the ones
/// `macos/appffi/app_wbtest.mbt` asserts from the writing side.
@MainActor
final class UpdatePostponeTests: XCTestCase {
    private let a = "/store/aaaa.jsonl"
    private let b = "/store/bbbb.jsonl"

    private func client() -> ShellClient {
        let client = ShellClient()
        client.receive(
            #"{"kind":"ready","session":"\#(a)","model":"DeepSeek V4 Flash","cwd":"/tmp","key":"saved"}"#
        )
        client.receive(
            #"{"kind":"session","session":"\#(a)","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        return client
    }

    /// The sidebar as the shell sends it on its tick. `runningInB` is the whole reason this test exists:
    /// it is a turn in a session that is not on screen.
    private func sidebar(runningInB: Bool) -> String {
        #"{"kind":"sessions","workspaces":[{"cwd":"/tmp","label":"tmp","current":true,"sessions":[{"path":"\#(a)","id":"aaaaaaaa","label":"what A asked","modified":1787466378656,"current":true,"running":false},{"path":"\#(b)","id":"bbbbbbbb","label":"what B asked","modified":1787466378656,"current":false,"running":\#(runningInB)}]}]}"#
    }

    func testAShellWithNothingInFlightMayRestart() {
        let client = client()
        client.receive(sidebar(runningInB: false))
        XCTAssertFalse(client.isWorking)
    }

    func testATurnOnScreenBlocksTheRestart() {
        let client = client()
        client.receive(sidebar(runningInB: false))
        client.receive(#"{"kind":"user","session":"\#(a)","text":"what A asked","continued":false}"#)
        XCTAssertTrue(client.isWorking)
    }

    /// The case the window would not show. A restart here looks idle and costs someone a turn.
    func testATurnInABackgroundSessionBlocksTheRestart() {
        let client = client()
        client.receive(sidebar(runningInB: true))
        XCTAssertTrue(
            client.isWorking,
            "a turn running in a session the reader is not looking at was treated as idle"
        )
    }

    func testAFinishedTurnStopsBlockingIt() {
        let client = client()
        client.receive(#"{"kind":"user","session":"\#(a)","text":"what A asked","continued":false}"#)
        XCTAssertTrue(client.isWorking)
        client.receive(#"{"kind":"end","session":"\#(a)","text":"","calls":1,"tools":0,"cost":"0.01"}"#)
        XCTAssertFalse(client.isWorking)
    }
}
