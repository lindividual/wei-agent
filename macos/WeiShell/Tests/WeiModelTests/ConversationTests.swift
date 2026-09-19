import XCTest

@testable import WeiModel

/// The transcript, as a function of the events.
///
/// No runtime, no socket and no window: the events *are* the interface, so the tests are a list of
/// them. That is the property the whole host boundary was chosen for — the MoonBit half produces
/// facts, and this half's behaviour is checkable without it.
final class ConversationTests: XCTestCase {
    private func run(_ lines: [String]) -> Conversation {
        var conversation = Conversation()
        for line in lines {
            guard let event = ShellEvent.decode(line: line) else {
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
        // Named per turn by the host, so this turn's ids are scoped by it — see `Conversation.turn`.
        XCTAssertEqual(conversation.rows.map(\.id), ["0/reply-1", "0/tool-1", "0/reply-2"])
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

    /// A second turn's blocks are new rows, not more of the first turn's.
    ///
    /// The bug this is here for: the shell names a turn's blocks `thinking-1`, `reply-1`, `tool-1`,
    /// starting again every turn. A host that appended by that name alone wrote the second answer
    /// into the first answer's row, overwrote the first turn's tool rows in place, and left the
    /// reader with a transcript whose previous thinking and tool calls had simply gone. Reported as
    /// "once a turn ends and I continue, the thinking and tool calls are gone and I cannot follow the
    /// progress" — nothing was missing from the shell, and the host had silently drawn it in the
    /// wrong place.
    func testASecondTurnDoesNotWriteIntoTheFirstTurnsBlocks() {
        let conversation = run([
            #"{"kind":"user","text":"first"}"#,
            #"{"kind":"thinking","id":"thinking-1","delta":"turn one reasoning"}"#,
            #"{"kind":"tool","id":"tool-1","name":"bash","detail":"ls","done":true,"output":"a","error":false}"#,
            #"{"kind":"reply","id":"reply-1","delta":"first answer"}"#,
            #"{"kind":"end","text":"","calls":1,"tools":1,"cost":"0.001"}"#,
            #"{"kind":"user","text":"second"}"#,
            #"{"kind":"thinking","id":"thinking-1","delta":"turn two reasoning"}"#,
            #"{"kind":"tool","id":"tool-1","name":"bash","detail":"pwd","done":true,"output":"b","error":false}"#,
            #"{"kind":"reply","id":"reply-1","delta":"second answer"}"#,
        ])
        XCTAssertEqual(
            conversation.rows.map(\.text),
            [
                "first",
                "turn one reasoning",
                "",
                "first answer",
                "1 model call · 1 tool call · $0.001",
                "second",
                "turn two reasoning",
                "",
                "second answer",
            ]
        )
        // The first turn's tool row is still its own: the second turn's `tool-1` is a second row.
        XCTAssertEqual(conversation.rows.filter { $0.kind == .tool }.map(\.output), ["a", "b"])
        // And the rows are distinct identities, which is what makes SwiftUI draw two of them.
        XCTAssertEqual(Set(conversation.rows.map(\.id)).count, conversation.rows.count)
    }

    /// A `blocks` parse lands on its own turn's row, not on the one before it.
    ///
    /// The same repeated name, one event later: the shell sends the parse for `reply-1` when the
    /// block stops growing, and a host that patched by that name alone would put the second turn's
    /// markdown on the first turn's text.
    func testAParseIsPatchedIntoTheTurnItBelongsTo() {
        let conversation = run([
            #"{"kind":"user","text":"first"}"#,
            #"{"kind":"reply","id":"reply-1","delta":"one"}"#,
            #"{"kind":"end","text":"","calls":1,"tools":0,"cost":"0"}"#,
            #"{"kind":"user","text":"second"}"#,
            #"{"kind":"reply","id":"reply-1","delta":"two"}"#,
            #"{"kind":"blocks","id":"reply-1","blocks":[{"t":"p","spans":[{"t":"text","text":"two"}]}]}"#,
        ])
        let replies = conversation.rows.filter { $0.kind == .reply }
        XCTAssertEqual(replies.count, 2)
        XCTAssertNil(replies[0].blocks, "the second turn's parse landed on the first turn's row")
        XCTAssertEqual(replies[1].blocks?.count, 1)
    }

    // ── what a question carried ───────────────────────────────────────────

    /// **The pictures travel with the prompt, and land on the question's own row.**
    ///
    /// They are part of the message rather than of the composer's state, and the difference matters:
    /// the shell empties the composer in the same breath, so a host that waited for `images` would
    /// draw the question with no picture on it, one event later.
    func testAQuestionKeepsThePicturesItWasSentWith() {
        let conversation = run([
            #"{"kind":"user","text":"what is this?","continued":false,"images":[{"mime":"image/png","data":"AAA="},{"mime":"image/jpeg","data":"BBB="}]}"#,
            #"{"kind":"reply","id":"reply-1","delta":"a cat"}"#,
        ])
        let question = conversation.rows.first { $0.kind == .user }
        XCTAssertEqual(question?.images.map(\.mime), ["image/png", "image/jpeg"])
        XCTAssertEqual(question?.images.first?.bytes, Data([0x00, 0x00]))
        // The answer carries none, and asking its picture list is how a view would ask.
        XCTAssertEqual(conversation.rows.first { $0.kind == .reply }?.images, [])
    }

    /// A prompt that carried no pictures — every prompt before this field existed, and most prompts
    /// since — decodes with an empty list rather than failing to decode at all.
    ///
    /// The absent case is the one worth pinning: a shell that predates `images` writes no such field,
    /// and a transcript that refused those lines would turn an old log into an empty window.
    func testAQuestionWithNoPicturesDecodes() {
        let conversation = run([
            #"{"kind":"user","text":"plain"}"#,
            #"{"kind":"user","text":"and again","continued":false,"images":[]}"#,
        ])
        XCTAssertEqual(conversation.rows.map(\.text), ["plain", "and again"])
        XCTAssertEqual(conversation.rows.map(\.images), [[], []])
    }

    /// **A `/skill:<name>` question arrives as the command, not as the document it expanded to.**
    ///
    /// The prompt in the log is the shell's framing with the skill's whole body inside it — a page of
    /// somebody else's instructions — and the reader's own words are at the bottom of it. The parts are
    /// what the view draws: their words as the question, and the body behind a fold. An older shell
    /// sends no `skill` field at all, which decodes to `nil` and draws the text as it always did.
    func testASkillQuestionArrivesAsItsParts() {
        // The wire line is built the way the shell builds it rather than pasted as a literal: the
        // prompt is full of quotes and newlines, and escaping them by hand here would be testing the
        // escaping rather than the decoding.
        let prompt = "<skill name=\"demo\" location=\"/s/SKILL.md\">\n"
            + "References are relative to /s.\n\nDo it.\n</skill>\n\nthis one"
        let line = #"{"kind":"user","text":"\#(escaped(prompt))","continued":false,"images":[],"skill":{"name":"demo","args":"this one","body":"Do it."}}"#
        let conversation = run([line, #"{"kind":"user","text":"plain"}"#])
        let question = conversation.rows[0]
        XCTAssertEqual(question.skill?.name, "demo")
        XCTAssertEqual(question.skill?.args, "this one")
        XCTAssertEqual(question.skill?.body, "Do it.")
        // The label answers the fold's only question — how much is behind this — with the same figure
        // the composer's own line uses, for the same reason.
        XCTAssertEqual(question.skill?.foldLabel, "skill demo · 6 characters")
        // The text still crosses whole, and a question with no framing has no parts at all.
        XCTAssertTrue(question.text.hasPrefix("<skill name="))
        XCTAssertNil(conversation.rows[1].skill)
    }

    /// A string as JSON would spell it: the quotes and newlines a skill framing is made of.
    private func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The pictures are named by their own bytes, not by the row.
    ///
    /// This is the cache key, and the reason it cannot be the row id: `user-1` is one picture in one
    /// session and a different one in the next, so a cache keyed by row would draw the previous
    /// conversation's screenshot in this one. Two different pictures must therefore differ here — and
    /// the same picture, in two rows or two sessions, must not.
    func testAPicturesKeyIsItsBytesRatherThanItsRow() {
        let one = RowImage(mime: "image/png", data: "AAA=")
        let two = RowImage(mime: "image/png", data: "BBB=")
        XCTAssertNotEqual(one.key, two.key)
        XCTAssertEqual(one.key, RowImage(mime: "image/png", data: "AAA=").key)
        XCTAssertEqual(RowImage(mime: "image/png", data: "AAA=").bytes, Data([0x00, 0x00]))
        // Not base64 at all is not bytes rather than a crash: a row is data off a wire.
        XCTAssertNil(RowImage(mime: "image/png", data: "not base64!!").bytes)
    }

    /// **A question can be a picture and nothing else**, which is the case a screenshot is.
    ///
    /// Two things have to hold for it to be drawn: the row survives with empty text (the shell skips a
    /// row with neither words nor pictures, and this one has a picture), and it still *starts a turn* —
    /// grouping is on the row kind, not on whether it says anything, so an empty question is the
    /// question rather than a row orphaned inside the previous turn's work.
    func testAQuestionWithNoWordsStillStartsATurn() {
        let conversation = run([
            #"{"kind":"user","text":"first"}"#,
            #"{"kind":"reply","id":"reply-1","delta":"an answer"}"#,
            #"{"kind":"end","text":"","calls":1,"tools":0,"cost":"0"}"#,
            #"{"kind":"user","text":"","continued":false,"images":[{"mime":"image/png","data":"AAA="}]}"#,
        ])
        let grouped = turns(of: conversation.rows)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[1].question?.text, "")
        XCTAssertEqual(grouped[1].question?.images.count, 1)
    }
}
