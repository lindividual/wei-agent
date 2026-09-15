import XCTest

@testable import PiModel

/// The transcript, as a function of the events.
///
/// No runtime, no socket and no window: the events *are* the interface, so the tests are a list of
/// them. That is the property the whole host boundary was chosen for — the MoonBit half produces
/// facts, and this half's behaviour is checkable without it.
final class ConversationTests: XCTestCase {
    private func run(_ lines: [String]) -> Conversation {
        var conversation = Conversation()
        for line in lines {
            guard let event = PiEvent.decode(line: line) else {
                XCTFail("undecodable: \(line)")
                continue
            }
            conversation.apply(event)
        }
        return conversation
    }

    /// Deltas under one id are one block, and the block is not finished while they arrive.
    func testStreamedTextAccumulatesIntoOneBlock() {
        let conversation = run([
            #"{"kind":"user","text":"hi"}"#,
            #"{"kind":"reply","id":"reply-1","delta":"Hel"}"#,
            #"{"kind":"reply","id":"reply-1","delta":"lo"}"#,
        ])
        XCTAssertEqual(conversation.rows.count, 2)
        XCTAssertEqual(conversation.rows[1].text, "Hello")
        // Still arriving: markdown is for the finished block, and re-parsing a growing one on
        // every delta is the quadratic the web UI already paid for.
        XCTAssertFalse(conversation.rows[1].complete)
    }

    /// A new block id means the previous one is over, and the prompt closes everything before it.
    func testANewBlockSettlesThePreviousOne() {
        let conversation = run([
            #"{"kind":"reply","id":"reply-1","delta":"first"}"#,
            #"{"kind":"reply","id":"reply-2","delta":"second"}"#,
        ])
        XCTAssertEqual(conversation.rows.count, 2)
        XCTAssertTrue(conversation.rows[0].complete)
        XCTAssertFalse(conversation.rows[1].complete)
    }

    /// A tool is one row from start to finish, under one id.
    ///
    /// The running row is what the report replaces. Appending a second row was the earlier shape
    /// in the web UI, and it left a spinner sitting there for good.
    func testAToolIsOneRowAcrossItsWholeLife() {
        let conversation = run([
            #"{"kind":"tool","id":"tool-1","name":"bash","detail":"ls","done":false,"output":"","error":false}"#,
            #"{"kind":"tool","id":"tool-1","name":"bash","detail":"","done":true,"output":"a\nb","error":false}"#,
        ])
        XCTAssertEqual(conversation.rows.count, 1)
        XCTAssertEqual(conversation.rows[0].output, "a\nb")
        XCTAssertTrue(conversation.rows[0].complete)
        // The detail from the start survives the report, which does not carry one.
        XCTAssertEqual(conversation.rows[0].detail, "ls")
    }

    /// Answer text after a tool call is a new block, not more of the one before it.
    func testTextAfterAToolStartsANewBlock() {
        let conversation = run([
            #"{"kind":"reply","id":"reply-1","delta":"thinking about it"}"#,
            #"{"kind":"tool","id":"tool-1","name":"bash","detail":"ls","done":true,"output":"","error":false}"#,
            #"{"kind":"reply","id":"reply-2","delta":"here it is"}"#,
        ])
        XCTAssertEqual(conversation.rows.map(\.id), ["reply-1", "tool-1", "reply-2"])
        XCTAssertTrue(conversation.rows[0].complete)
        XCTAssertFalse(conversation.rows[2].complete)
    }

    /// A turn that finished normally says nothing extra: the answer is the report.
    func testANormalEndAddsOnlyTheFigures() {
        let conversation = run([
            #"{"kind":"status","text":"thinking…"}"#,
            #"{"kind":"reply","id":"reply-1","delta":"done"}"#,
            #"{"kind":"end","text":"","calls":2,"tools":1,"cost":"0.0013"}"#,
        ])
        XCTAssertEqual(conversation.status, "")
        XCTAssertEqual(conversation.rows.last?.text, "2 model calls · 1 tool call · $0.0013")
    }

    /// A turn a guard stopped says which guard, and the figures as well.
    func testAStoppedTurnSaysWhichGuardStoppedIt() {
        let conversation = run([
            #"{"kind":"end","text":"stopped at the cost limit","calls":19,"tools":25,"cost":"0.1000"}"#,
        ])
        XCTAssertEqual(conversation.rows.last?.text, "stopped at the cost limit · 19 model calls · 25 tool calls · $0.1000")
    }

    func testASingleCallIsNotPluralised() {
        let conversation = run([#"{"kind":"end","text":"","calls":1,"tools":1,"cost":"0"}"#])
        XCTAssertEqual(conversation.rows.last?.text, "1 model call · 1 tool call")
    }

    /// The status line and the transcript are different things, and an error is part of the
    /// transcript: what went wrong should not be replaced by the next thing that happens.
    func testAnErrorBecomesARow() {
        let conversation = run([
            #"{"kind":"status","text":"thinking…"}"#,
            #"{"kind":"error","text":"no API key: set DEEPSEEK_API_KEY and reopen"}"#,
        ])
        XCTAssertEqual(conversation.status, "")
        XCTAssertEqual(conversation.rows.count, 1)
        XCTAssertEqual(conversation.rows[0].text, "no API key: set DEEPSEEK_API_KEY and reopen")
    }

    /// Thinking and replying are separate blocks even though they interleave.
    func testReasoningAndTheAnswerAreSeparateBlocks() {
        let conversation = run([
            #"{"kind":"thinking","id":"thinking-1","delta":"hmm"}"#,
            #"{"kind":"reply","id":"reply-1","delta":"answer"}"#,
        ])
        XCTAssertEqual(conversation.rows.map(\.kind), [.thinking, .reply])
    }
}
