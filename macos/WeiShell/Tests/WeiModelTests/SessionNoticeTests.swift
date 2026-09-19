import XCTest

@testable import WeiModel

/// The line that says a turn ended somewhere else — the facts of it, without a window.
///
/// The wire sends a token and this type writes the words, so this is where the translation is checked:
/// what an unknown token does, what a nameless session is called, and — because it is the difference
/// between one line and a stack of them — what makes two notices the same row.
final class SessionNoticeTests: XCTestCase {
    func testTheOutcomeIsATokenOffTheWire() {
        XCTAssertEqual(SessionNotice.Outcome(wire: "finished"), .finished)
        XCTAssertEqual(SessionNotice.Outcome(wire: "failed"), .failed)
        XCTAssertEqual(SessionNotice.Outcome(wire: "stopped"), .stopped)
        // A newer shell's outcome is kept rather than refused: the turn still ended, which is the whole
        // of what the line is for, and the token itself is more use than a line saying nothing happened.
        XCTAssertEqual(SessionNotice.Outcome(wire: "cancelled"), .other("cancelled"))
    }

    /// Every outcome has a word, including the ones with no word of their own.
    ///
    /// The two empty cases are the whole reason this is a function rather than a table: an unknown token
    /// that arrives blank would otherwise be drawn as a line ending in a space.
    func testEveryOutcomeSaysWhatHappened() {
        XCTAssertEqual(SessionNotice.Outcome.finished.word, "finished")
        XCTAssertEqual(SessionNotice.Outcome.failed.word, "failed")
        XCTAssertEqual(SessionNotice.Outcome.stopped.word, "stopped")
        XCTAssertEqual(SessionNotice.Outcome.other("cancelled").word, "cancelled")
        XCTAssertEqual(SessionNotice.Outcome.other("").word, "ended")
    }

    /// The name is quoted and named, because both halves are needed: the quotes are what says *this part
    /// is the name* — a label can be a whole sentence — and the word in front is what stops a sentence about
    /// a conversation reading as a remark about whatever the label happens to mention.
    func testTheLineNamesTheSessionItIsAbout() {
        let named = SessionNotice(path: "/s/b.jsonl", outcome: .finished, label: "refactor the parser")
        XCTAssertEqual(named.title, "Session “refactor the parser” finished")

        // A label that is itself a sentence needs the leading word most: without it the outcome attaches
        // to the wrong subject.
        let sentence = SessionNotice(path: "/s/b.jsonl", outcome: .failed, label: "fix the flaky test on CI")
        XCTAssertEqual(sentence.title, "Session “fix the flaky test on CI” failed")

        // No name is a sentence with a subject rather than no subject: the reader still has to know that
        // *something* happened, and to whom it did not.
        let unnamed = SessionNotice(path: "/s/b.jsonl", outcome: .failed, label: "")
        XCTAssertEqual(unnamed.title, "Another session failed")
    }

    /// One session is one row, and a second turn ending in it replaces the line rather than stacking
    /// under it.
    ///
    /// A stack of banners is a second inbox, and the transcript of the session that ended already keeps
    /// the record of every turn it ran — so the newest fact is the only one this line owes the reader.
    func testOneSessionIsOneLine() {
        let first = SessionNotice(path: "/s/b.jsonl", outcome: .finished, label: "one")
        let second = SessionNotice(path: "/s/b.jsonl", outcome: .failed, label: "two")
        XCTAssertEqual(first.id, second.id)

        let other = SessionNotice(path: "/s/c.jsonl", outcome: .finished, label: "three")
        XCTAssertNotEqual(first.id, other.id)
    }
}
