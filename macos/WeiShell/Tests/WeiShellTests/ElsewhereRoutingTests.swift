import XCTest

import WeiModel
@testable import WeiKit

/// A turn that ends in a conversation the reader is not looking at.
///
/// This is the rule that used to be broken, and the test is written from the side that broke it. The
/// shell used to announce a background turn ending with a `session` event — the same event it sends when
/// the reader switches — and this side answers a `session` event by swapping transcripts. So an answer
/// finishing in session 2 *moved* a reader who was in session 1, with nothing they had done to ask for
/// it. The wire has two kinds now, and the difference between them is exactly what these check: one
/// changes what is on screen, the other only says something.
///
/// The literals are the ones `macos/appffi/app_wbtest.mbt` asserts from the writing side.
@MainActor
final class ElsewhereRoutingTests: XCTestCase {
    private let a = "/store/aaaa.jsonl"
    private let b = "/store/bbbb.jsonl"

    /// A window with A on screen, and a list that knows both conversations by name.
    private func client() -> ShellClient {
        let client = ShellClient()
        client.receive(
            #"{"kind":"ready","session":"\#("/store/aaaa.jsonl")","model":"DeepSeek V4 Flash","cwd":"/tmp","key":"saved"}"#
        )
        client.receive(
            #"{"kind":"session","session":"/store/aaaa.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        client.receive(#"{"kind":"history","session":"/store/aaaa.jsonl","rows":[{"kind":"user","id":"h-1","text":"what A asked","complete":true,"name":"","detail":"","output":"","error":false}]}"#)
        client.receive(
            #"{"kind":"sessions","workspaces":[{"cwd":"/tmp","label":"tmp","current":true,"sessions":[{"path":"/store/aaaa.jsonl","id":"aaaaaaaa","label":"what A asked","modified":1787466378656,"current":true,"running":false},{"path":"/store/bbbb.jsonl","id":"bbbbbbbb","label":"what B asked","modified":1787466378656,"current":false,"running":false}]}]}"#
        )
        return client
    }

    /// **The bug, as a test.** A turn ending elsewhere says so and leaves the window where it is.
    func testATurnEndingElsewhereDoesNotStealTheWindow() {
        let client = client()
        XCTAssertEqual(client.currentPath, a)

        client.receive(
            #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"finished"}"#
        )

        // What the reader was reading is still what they are reading.
        XCTAssertEqual(client.currentPath, a)
        XCTAssertEqual(client.conversation.rows.count, 1)
        XCTAssertEqual(client.conversation.rows[0].text, "what A asked")

        // And the fact is not dropped: it is said, with the name the sidebar knows it by.
        XCTAssertEqual(client.notice?.path, b)
        XCTAssertEqual(client.notice?.outcome, .finished)
        XCTAssertEqual(client.notice?.label, "what B asked")
        XCTAssertEqual(client.notice?.title, "Session “what B asked” finished")
    }

    /// The three outcomes travel as tokens, and an unknown one is still a turn that ended.
    func testTheOutcomeIsATokenThatThisSideTurnsIntoWords() {
        let client = client()
        for (wire, expected) in [("failed", SessionNotice.Outcome.failed), ("stopped", .stopped)] {
            client.receive(
                #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"\#(wire)"}"#
            )
            XCTAssertEqual(client.notice?.outcome, expected)
        }
        // A newer shell's fourth outcome is kept rather than refused — the turn still ended, which is
        // the whole of what the line is for — and it is shown as itself rather than as a blank.
        client.receive(
            #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"cancelled"}"#
        )
        XCTAssertEqual(client.notice?.outcome, .other("cancelled"))
        XCTAssertEqual(client.notice?.title, "Session “what B asked” cancelled")
    }

    /// A session the list has not got round to naming yet is still named as well as it can be.
    ///
    /// A conversation whose first turn has not been written has no label — that is the state the shell
    /// reports, not a missing field — and eight hex characters are still a way to recognise it. A line
    /// with no subject at all would be a line the reader cannot act on.
    func testANoticeAboutASessionTheListDoesNotHaveFallsBackToItsID() {
        let client = client()
        client.receive(
            #"{"kind":"sessions","workspaces":[{"cwd":"/tmp","label":"tmp","current":true,"sessions":[{"path":"/store/cc.jsonl","id":"cccccccc","label":"","modified":1787466378656,"current":false,"running":false}]}]}"#
        )
        client.receive(
            #"{"kind":"elsewhere","session":"/store/cc.jsonl","path":"/store/cc.jsonl","outcome":"finished"}"#
        )
        XCTAssertEqual(client.notice?.label, "cccccccc")

        // A session in no group at all is nameless rather than dropped, and the sentence says so.
        client.receive(
            #"{"kind":"elsewhere","session":"/store/dd.jsonl","path":"/store/dd.jsonl","outcome":"finished"}"#
        )
        XCTAssertEqual(client.notice?.label, "")
        XCTAssertEqual(client.notice?.title, "Another session finished")
    }

    /// Opening the session the notice names is what answers it: the line comes down.
    ///
    /// It is keyed on the switch rather than on the click, which is what makes it true for every way in —
    /// the sidebar row, `⌃⇥`, and the notice's own Open.
    func testGoingThereTakesTheNoticeDown() {
        let client = client()
        client.receive(
            #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"finished"}"#
        )
        XCTAssertNotNil(client.notice)

        client.receive(
            #"{"kind":"session","session":"/store/bbbb.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash","interrupted":false,"interrupted_prompt":""}"#
        )
        XCTAssertEqual(client.currentPath, b)
        XCTAssertNil(client.notice, "a line saying 'you have not seen this' over the thing itself")
    }

    /// A notice about a session that is then *renamed* is renamed with it.
    ///
    /// A turn just ending is the commonest moment for a conversation to acquire its name — the label is
    /// the first question, and the first question is what the turn was. So the list follows the notice
    /// rather than the notice holding a stale copy, or the reader is told about "ab12cd34" finishing.
    func testTheLabelFollowsTheList() {
        let client = client()
        client.receive(
            #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"finished"}"#
        )
        XCTAssertEqual(client.notice?.label, "what B asked")

        client.receive(
            #"{"kind":"sessions","workspaces":[{"cwd":"/tmp","label":"tmp","current":true,"sessions":[{"path":"/store/aaaa.jsonl","id":"aaaaaaaa","label":"what A asked","modified":1787466378656,"current":true,"running":false},{"path":"/store/bbbb.jsonl","id":"bbbbbbbb","label":"rename the parser","modified":1787466378657,"current":false,"running":false}]}]}"#
        )
        XCTAssertEqual(client.notice?.label, "rename the parser")
        XCTAssertEqual(client.notice?.title, "Session “rename the parser” finished")
    }

    /// The reader can take the line down, and nothing has to be told about it.
    ///
    /// The notice is not a fact about any conversation — the turn is over in its own transcript whatever
    /// this window draws — so declining to be told again is a window decision, and no command goes out.
    func testDismissingIsTheWindowsOwnBusiness() {
        let client = client()
        client.receive(
            #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"failed"}"#
        )
        XCTAssertNotNil(client.notice)
        client.dismissNotice()
        XCTAssertNil(client.notice)
        // And the reader's own transcript was never involved.
        XCTAssertEqual(client.currentPath, a)
        XCTAssertEqual(client.conversation.rows.count, 1)
    }

    /// **The count that rings, and the value that does not.**
    ///
    /// The chime is triggered by `noticeBeat` rather than by `notice` for a reason the reader would
    /// otherwise hear: a `sessions` event *rewrites* the notice to keep its name current, and a sound
    /// keyed on the value would go off again for a rename — every time the sidebar moved, for a turn that
    /// ended once.
    func testOnlyANewEventRingsNotARename() {
        let client = client()
        XCTAssertEqual(client.noticeBeat, 0)

        client.receive(
            #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"finished"}"#
        )
        XCTAssertEqual(client.noticeBeat, 1)

        // The label is refreshed, which is a change to `notice` and not a second event.
        client.receive(
            #"{"kind":"sessions","workspaces":[{"cwd":"/tmp","label":"tmp","current":true,"sessions":[{"path":"/store/bbbb.jsonl","id":"bbbbbbbb","label":"a new name","modified":1787466378657,"current":false,"running":false}]}]}"#
        )
        XCTAssertEqual(client.notice?.label, "a new name")
        XCTAssertEqual(client.noticeBeat, 1, "a rename rang the chime again")

        // A second turn ending in the same conversation is a *new* fact about it, and does ring.
        client.receive(
            #"{"kind":"elsewhere","session":"/store/bbbb.jsonl","path":"/store/bbbb.jsonl","outcome":"failed"}"#
        )
        XCTAssertEqual(client.noticeBeat, 2)
        XCTAssertEqual(client.notice?.outcome, .failed)
    }
}
