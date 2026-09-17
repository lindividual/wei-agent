import XCTest

@testable import WeiModel

/// Turns: the shape a reader sees in a flat list of rows.
///
/// The rule is the web UI's (`html/render.mbt`'s `render_exchange`), and the cases here are the ones that rule
/// was written for: several replies in one turn, a turn that ended in a tool call, a compaction that has to
/// fold with the work, and the figures that end a turn.
final class TurnsTests: XCTestCase {
    private func user(_ text: String, _ id: String) -> Row {
        Row(id: id, kind: .user, text: text, complete: true)
    }

    private func reply(_ text: String, _ id: String) -> Row {
        Row(id: id, kind: .reply, text: text, complete: true)
    }

    private func thinking(_ text: String, _ id: String) -> Row {
        Row(id: id, kind: .thinking, text: text, complete: true)
    }

    private func tool(_ name: String, _ id: String, output: String = "ok") -> Row {
        var row = Row(id: id, kind: .tool, text: "", complete: true)
        row.name = name
        row.output = output
        return row
    }

    private func figures(_ text: String, _ id: String) -> Row {
        Row(id: id, kind: .note, text: text, complete: true)
    }

    private func note(_ text: String, _ label: String, _ id: String) -> Row {
        var row = Row(id: id, kind: .note, text: text, complete: true)
        row.name = label
        return row
    }

    /// The everyday shape: a question, some work, and an answer — where the answer is the **last** text, and
    /// the reasoning and the tool calls are the work.
    func testATurnIsItsQuestionItsWorkAndItsLastAnswer() {
        let turns = turns(of: [
            user("what changed?", "u1"),
            thinking("let me look", "t1"),
            tool("git", "x1"),
            reply("first, the parser", "r1"),
            tool("git", "x2"),
            reply("here is the summary", "r2"),
            figures("2 model calls · 2 tool calls · $0.01", "n1"),
        ])
        XCTAssertEqual(turns.count, 1)
        let turn = turns[0]
        XCTAssertEqual(turn.question?.text, "what changed?")
        XCTAssertEqual(turn.answer?.text, "here is the summary", "the answer is not the last text")
        XCTAssertEqual(turn.work.map(\.id), ["t1", "x1", "r1", "x2"], "the work is not everything but the answer")
        XCTAssertEqual(turn.figures, "2 model calls · 2 tool calls · $0.01")
        XCTAssertTrue(turn.hasWork)
    }

    /// A turn that ended in a tool call rather than in prose — a round limit, or a stop. The last thing said
    /// is shown in the answer's place, which is what the web UI does and is better than showing nothing.
    func testATurnThatEndedInAToolCallStillHasAnAnswer() {
        let turns = turns(of: [
            user("keep going", "u1"),
            reply("almost", "r1"),
            tool("sleep", "x1"),
        ])
        XCTAssertEqual(turns[0].answer?.id, "r1")
        XCTAssertEqual(turns[0].work.map(\.id), ["x1"])
    }

    /// A compaction is part of what happened, so it folds with the work; an unlabelled note is the turn's
    /// figures. The two are the same row kind and different things, which is what the label is for.
    func testACompactionFoldsAndTheFiguresDoNot() {
        let turns = turns(of: [
            user("go", "u1"),
            note("the summary", "context compacted", "c1"),
            reply("done", "r1"),
            figures("1 model call · $0.02", "n1"),
        ])
        XCTAssertEqual(turns[0].work.map(\.id), ["c1"], "the compaction did not fold with the work")
        XCTAssertEqual(turns[0].figures, "1 model call · $0.02")
    }

    /// The fold's label counts the work, and drops the money: the figure line is the shell's own sentence and
    /// the label is a phrase in front of a fold.
    func testTheFoldLabelCountsAndDoesNotPrice() {
        let turn = turns(of: [
            user("go", "u1"),
            tool("a", "x1"),
            reply("done", "r1"),
            figures("3 model calls · 2 tool calls · $0.0128", "n1"),
        ])[0]
        XCTAssertEqual(turn.workLabel, "Worked through 3 model calls, 2 tool calls")
    }

    /// No figures — a replayed session, or a turn still running — and the label falls back to the web UI's own
    /// fallback rather than to a count of zeroes.
    func testTheLabelFallsBackWhenThereAreNoFigures() {
        let turn = turns(of: [user("go", "u1"), tool("a", "x1"), reply("done", "r1")])[0]
        XCTAssertNil(turn.figures)
        XCTAssertEqual(turn.workLabel, "What it did")
    }

    /// Several turns, and the fold does not run across a question: the last answer of one turn is not the work
    /// of the next.
    func testTurnsDoNotBleedAcrossQuestions() {
        let turns = turns(of: [
            user("first", "u1"),
            thinking("hm", "t1"),
            reply("one", "r1"),
            figures("1 model call · $0.01", "n1"),
            user("second", "u2"),
            reply("two", "r2"),
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].answer?.id, "r1")
        XCTAssertEqual(turns[0].work.map(\.id), ["t1"])
        XCTAssertEqual(turns[0].figures, "1 model call · $0.01")
        XCTAssertEqual(turns[1].answer?.id, "r2")
        XCTAssertFalse(turns[1].hasWork, "the second turn has nothing to fold")
        XCTAssertNil(turns[1].figures)
    }

    /// A transcript that begins mid-turn — a resumed session, or a log whose first entries were compacted —
    /// is its own turn with no question, and is not dropped.
    func testRowsBeforeAnyQuestionAreATurnOfTheirOwn() {
        let turns = turns(of: [
            thinking("left over", "t0"),
            reply("and then", "r0"),
            user("next", "u1"),
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertNil(turns[0].question)
        XCTAssertEqual(turns[0].answer?.id, "r0")
        XCTAssertEqual(turns[1].question?.id, "u1")
        // The id is stable even with no question to borrow one from.
        XCTAssertEqual(turns[0].id, "turn-0")
    }

    /// An empty transcript is no turns, not one empty turn: the view draws "nothing here" from an empty list.
    func testAnEmptyTranscriptIsNoTurns() {
        XCTAssertTrue(turns(of: []).isEmpty)
    }

    /// A turn with no work has nothing to fold — the point being that the *view* can then skip the fold
    /// entirely rather than draw an empty one.
    func testATurnThatWasOneAnswerHasNothingToFold() {
        let turns = turns(of: [user("hi", "u1"), reply("hello", "r1")])
        XCTAssertFalse(turns[0].hasWork)
        XCTAssertEqual(turns[0].answer?.text, "hello")
    }

    /// The turn's identity is its question's row id, which is what keeps a fold the reader opened open across
    /// redraws — the streaming case, where the list is rebuilt on every delta.
    func testATurnsIdentityIsItsQuestionsRow() {
        let turns = turns(of: [user("hi", "u1"), reply("hello", "r1")])
        XCTAssertEqual(turns[0].id, "u1")
    }
}
