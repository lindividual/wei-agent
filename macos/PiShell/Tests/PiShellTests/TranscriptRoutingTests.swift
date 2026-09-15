import XCTest

@testable import PiKit

/// Where an event goes when more than one conversation is open.
///
/// The wire is driven with literals rather than a shell, because the routing is pure: given a line, which
/// transcript does it belong to. That is the part of concurrency that fails *silently* — an answer filed
/// under the wrong session draws perfectly, as an answer — and it only becomes visible once two turns are
/// running, which is exactly the state a test can produce on purpose and a reader cannot reproduce.
///
/// The literals are the ones `macos/appffi/app_wbtest.mbt` asserts from the writing side.
@MainActor
final class TranscriptRoutingTests: XCTestCase {
    private let a = "/store/aaaa.jsonl"
    private let b = "/store/bbbb.jsonl"

    private func client() -> PiClient {
        let client = PiClient()
        // The shell is up, and it is A that is on screen. Everything after this is routed against it.
        client.receive(
            #"{"kind":"ready","session":"\#("/store/aaaa.jsonl")","model":"DeepSeek V4 Flash","cwd":"/tmp","key":"saved"}"#
        )
        client.receive(
            #"{"kind":"session","session":"/store/aaaa.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        client.receive(#"{"kind":"history","session":"/store/aaaa.jsonl","rows":[{"kind":"user","id":"h-1","text":"what A asked","complete":true,"name":"","detail":"","output":"","error":false}]}"#)
        return client
    }

    /// The whole point: an answer to a question in another conversation does not land in the one being
    /// watched.
    func testAnAnswerForAnotherSessionDoesNotLandInTheOneOnScreen() {
        let client = client()
        XCTAssertEqual(client.conversation.rows.count, 1)

        // A turn in B, while A is what the window shows. Everything but the switch is B's.
        client.receive(#"{"kind":"user","session":"/store/bbbb.jsonl","text":"what B asked","continued":false}"#)
        client.receive(#"{"kind":"reply","session":"/store/bbbb.jsonl","id":"reply-1-1","delta":"B's answer"}"#)
        client.receive(#"{"kind":"status","session":"/store/bbbb.jsonl","text":"thinking…"}"#)
        client.receive(#"{"kind":"end","session":"/store/bbbb.jsonl","text":"","calls":1,"tools":0,"cost":"0.01"}"#)

        // A is untouched: one row, the question it had, and no status of its own.
        XCTAssertEqual(client.conversation.rows.count, 1)
        XCTAssertEqual(client.conversation.rows[0].text, "what A asked")
        XCTAssertFalse(client.conversation.running, "A was told a turn started that was B's")
        XCTAssertEqual(client.conversation.status, "")
    }

    /// Switching draws the other conversation's rows, live ones included — and the one being left keeps
    /// everything it had.
    func testASwitchSwapsTranscriptsAndKeepsTheOneBeingLeft() {
        let client = client()
        client.receive(#"{"kind":"user","session":"/store/bbbb.jsonl","text":"what B asked","continued":false}"#)
        client.receive(#"{"kind":"reply","session":"/store/bbbb.jsonl","id":"reply-1-1","delta":"half an ans"}"#)

        // The switch: a `session` event and nothing else — no history, because the host is watching this
        // turn happen and its own copy is newer than the log.
        client.receive(
            #"{"kind":"session","session":"/store/bbbb.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        XCTAssertEqual(client.currentPath, "/store/bbbb.jsonl")
        XCTAssertEqual(client.conversation.running, true, "the turn in flight was lost on the switch")
        XCTAssertTrue(
            client.conversation.rows.contains { $0.text == "half an ans" },
            "the part-arrived answer was not there when the reader came back"
        )

        // And back: A is exactly as it was.
        client.receive(
            #"{"kind":"session","session":"/store/aaaa.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        XCTAssertEqual(client.currentPath, "/store/aaaa.jsonl")
        XCTAssertEqual(client.conversation.rows.count, 1)
        XCTAssertEqual(client.conversation.rows[0].text, "what A asked")
    }

    /// An answer that arrives while the reader is looking elsewhere is kept, not dropped. This is the
    /// case a single-transcript host would get wrong in the other direction: the turn would be *stopped*
    /// by nobody listening.
    func testAnAnswerIsKeptWhileTheReaderIsSomewhereElse() {
        let client = client()
        // B starts a turn, the reader switches to... B is shown; go back to A first.
        client.receive(#"{"kind":"user","session":"/store/bbbb.jsonl","text":"what B asked","continued":false}"#)
        client.receive(
            #"{"kind":"session","session":"/store/aaaa.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        // B's answer arrives with A on screen.
        client.receive(#"{"kind":"reply","session":"/store/bbbb.jsonl","id":"reply-1-1","delta":"the whole answer"}"#)
        client.receive(#"{"kind":"end","session":"/store/bbbb.jsonl","text":"","calls":1,"tools":0,"cost":"0.01"}"#)
        XCTAssertEqual(client.conversation.rows.count, 1, "B's answer was written into A")

        // Come back to B: the question and the answer are both there.
        client.receive(
            #"{"kind":"session","session":"/store/bbbb.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        // The question, the answer, and the figures the turn ended with — a note row rather than a
        // status line, which is why it is here rather than on `status`.
        XCTAssertEqual(
            client.conversation.rows.map(\.text),
            ["what B asked", "the whole answer", "1 model call · $0.01"]
        )
        XCTAssertFalse(client.conversation.running, "the turn did not end cleanly")
    }

    /// Why nothing can be sent, said where a reader is about to type.
    ///
    /// This used to live in the window's subtitle. The titlebar is now the project and its count — that is
    /// what the column above the list is about — so the one line that says *the shell cannot send* had to
    /// move, and it moved to the composer's own line. It is worth a test because the failure it describes is
    /// the one that blocks everything: a machine with no key must not be a machine that says nothing.
    func testAMachineWithNoKeySaysSo() {
        let client = PiClient()
        // Before anything arrives: not an error, just not up yet.
        XCTAssertEqual(client.blocked, "starting…")

        client.receive(
            #"{"kind":"ready","session":"/store/aaaa.jsonl","model":"DeepSeek V4 Flash","cwd":"/tmp","key":"missing"}"#
        )
        XCTAssertEqual(client.blocked, "no API key — open Settings")

        // And a key arrives — saving one re-sends `ready` — so the warning goes away on its own.
        client.receive(
            #"{"kind":"ready","session":"/store/aaaa.jsonl","model":"DeepSeek V4 Flash","cwd":"/tmp","key":"saved"}"#
        )
        XCTAssertNil(client.blocked)
    }

    /// A shell that could not start at all says that instead, and says which failure it was.
    func testAShellThatCouldNotStartSaysWhy() {
        let client = PiClient()
        client.receive(#"{"kind":"error","text":"could not start: Failure(no HOME)"}"#)
        XCTAssertEqual(client.blocked, "could not start: Failure(no HOME)")
    }

    /// An event with no session is about the one on screen — the rule that keeps the answers to a
    /// reader's own click from having to name a path they would only repeat.
    func testAnEventWithNoSessionBelongsToWhatIsOnScreen() {
        let client = client()
        client.receive(#"{"kind":"status","text":"open: no session path"}"#)
        XCTAssertEqual(client.conversation.status, "open: no session path")
    }

    /// A row is running *per session*, which is what the sidebar's spinner is drawn from: two turns can
    /// be in flight, and a row that showed one because *a* turn was running would point at the wrong
    /// conversation.
    func testTheSidebarSaysWhichSessionsAreRunning() {
        let client = client()
        client.receive(
            #"{"kind":"sessions","workspaces":[{"cwd":"/tmp","label":"tmp","current":true,"sessions":[{"path":"/store/aaaa.jsonl","id":"aaaa","label":"A","modified":1,"current":true,"running":true},{"path":"/store/bbbb.jsonl","id":"bbbb","label":"B","modified":2,"current":false,"running":true}]}]}"#
        )
        let rows = client.groups.flatMap(\.sessions)
        XCTAssertEqual(rows.map(\.running), [true, true])
        XCTAssertEqual(rows.map(\.current), [true, false])
    }
}
