import XCTest

@testable import WeiModel

/// What the transcript has to scroll to when it goes to the end.
///
/// This is a one-line rule with a whole bug behind it, so it is tested rather than written inline in the
/// view. The view scrolls with `ScrollViewReader.scrollTo(id)`, and `scrollTo` **does nothing at all when
/// no view has that id** — no warning, no error, no scroll. The ids the view registers are *turn* ids
/// (`ForEach(turns, id: \.element.id)`), and a turn's id is its question's row id. The obvious thing to
/// scroll to — the last row — is therefore almost always an id that does not exist: after any answer the
/// last row is a piece of that answer, whose id is `"<turn>/<block>"`.
///
/// That is what "clicking a session does not go to the bottom" was: not a layout problem, not a timing
/// problem, but a scroll to a name nothing answers to.
final class TranscriptEndTests: XCTestCase {
    private func run(_ lines: [String]) -> [Row] {
        var conversation = Conversation()
        for line in lines {
            guard let event = ShellEvent.decode(line: line) else {
                XCTFail("undecodable: \(line)")
                continue
            }
            conversation.apply(event)
        }
        return conversation.rows
    }

    /// The end is the last *turn*, and that id is the one the view registers.
    func testTheEndIsTheLastTurn() {
        let rows = run([
            #"{"kind":"user","text":"first"}"#,
            #"{"kind":"reply","id":"r1","delta":"one"}"#,
            #"{"kind":"user","text":"second"}"#,
            #"{"kind":"reply","id":"r2","delta":"two"}"#,
        ])
        let turns = WeiModel.turns(of: rows)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(endOf(rows), turns.last?.id)
        // A turn is identified by its question, which is what makes a fold stay open across redraws.
        XCTAssertEqual(turns.last?.id, "user-2")
    }

    /// **The trap, written down**: the last row is not the last turn, and scrolling to it scrolls to
    /// nothing. If this ever stops being true it is because something else changed, and the doc comment
    /// above the helper is what should be re-read.
    func testTheLastRowIsNotTheEndOfATurn() {
        let rows = run([
            #"{"kind":"user","text":"a question"}"#,
            #"{"kind":"reply","id":"r1","delta":"an answer"}"#,
        ])
        XCTAssertEqual(rows.last?.id, "1/r1")
        XCTAssertNotEqual(endOf(rows), rows.last?.id)
    }

    /// A transcript with nothing in it has no end to go to, and the view has to be able to tell.
    func testAnEmptyTranscriptHasNoEnd() {
        XCTAssertNil(endOf([]))
    }

    /// A turn with no question — a log whose first entries were compacted away — still has an id the view
    /// registers, so the end is still somewhere it can scroll.
    func testATurnWithoutAQuestionStillHasAnEnd() {
        let rows = run([#"{"kind":"reply","id":"r1","delta":"mid-answer"}"#])
        XCTAssertEqual(endOf(rows), "turn-0")
    }
}
