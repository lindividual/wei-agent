import XCTest

@testable import WeiModel

/// The sidebar and the history, from the side that reads them.
///
/// The literals here are the ones `macos/appffi/app_wbtest.mbt` asserts from the side that writes them
/// — the same arrangement as `EventTests`, and for the same reason: a field renamed on one side and
/// not the other stops a build here rather than producing a sidebar that never fills.
final class SidebarTests: XCTestCase {
    /// A session list, exactly as `sessions_event` writes it.
    private let sessionsLine = #"""
    {"kind":"sessions","workspaces":[{"cwd":"/home/me/project","label":"project","current":true,"sessions":[{"path":"/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl","id":"01a02d4c","label":"set up the project","modified":1787466378656,"current":true,"running":false,"pending":false}]}]}
    """#

    func testSessionsCarryTheirWorkspacesAndTheirRows() throws {
        let event = try XCTUnwrap(ShellEvent.decode(line: sessionsLine))
        guard case let .sessions(workspaces) = event else {
            return XCTFail("expected sessions, got \(event)")
        }
        XCTAssertEqual(workspaces.count, 1)
        let group = try XCTUnwrap(workspaces.first)
        XCTAssertEqual(group.cwd, "/home/me/project")
        XCTAssertEqual(group.label, "project")
        XCTAssertTrue(group.current)
        let row = try XCTUnwrap(group.sessions.first)
        XCTAssertEqual(
            row.path,
            "/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl"
        )
        XCTAssertEqual(row.shortID, "01a02d4c")
        XCTAssertEqual(row.label, "set up the project")
        // Milliseconds since the epoch, so that the host does its own "how long ago" — a value the
        // shell cannot compute, because it stops being true as the reader watches.
        XCTAssertEqual(row.modified, 1_787_466_378_656)
        XCTAssertTrue(row.current)
        XCTAssertFalse(row.running)
    }

    /// Moving between sessions without the pointer: the row below, the row above, and the ends of the
    /// list.
    ///
    /// Wrapping is the case worth pinning: a reader holding `⌃⇥` down is cycling, and a shortcut that
    /// stops at the last row is one that looks broken rather than finished.
    func testTheNextAndPreviousSession() {
        let rows = [row("a"), row("b"), row("c")]
        XCTAssertEqual(neighbourSession(rows: rows, from: "a", step: 1)?.path, "b")
        XCTAssertEqual(neighbourSession(rows: rows, from: "b", step: -1)?.path, "a")
        XCTAssertEqual(neighbourSession(rows: rows, from: "c", step: 1)?.path, "a")
        XCTAssertEqual(neighbourSession(rows: rows, from: "a", step: -1)?.path, "c")
        // Two rows: both directions lead to the other one, which is not a special case to write.
        XCTAssertEqual(neighbourSession(rows: [row("a"), row("b")], from: "a", step: 1)?.path, "b")
        XCTAssertEqual(neighbourSession(rows: [row("a"), row("b")], from: "a", step: -1)?.path, "b")
    }

    /// No neighbour is a refusal, not a move to the top of the list: one session is not a choice, and
    /// a session the store has lost has no row to be next to.
    func testThereIsNowhereToGoFrom() {
        XCTAssertNil(neighbourSession(rows: [], from: "a", step: 1))
        XCTAssertNil(neighbourSession(rows: [row("a")], from: "a", step: 1))
        // A session created in this process and not yet in the list, or one since deleted.
        XCTAssertNil(neighbourSession(rows: [row("a"), row("b")], from: "z", step: 1))
    }

    /// A row with nothing but a path: the fields these tests are not about are the ones the shell
    /// fills in, and a default here keeps each test about the thing it names.
    private func row(_ path: String) -> SessionRow {
        SessionRow(
            path: path, shortID: path, label: path, modified: 0,
            current: false, running: false
        )
    }

    /// Where a session lives, as the list says it.
    ///
    /// The label and not the path, because two readers use this answer: the subtitle under a row in the
    /// middle column, and the project name in the flat "Running sessions" list. Both are read next to the
    /// first column's own rows, so a path here would be a third vocabulary for one thing.
    func testASessionIsNamedByItsWorkspace() {
        let groups = [
            SessionGroup(cwd: "/home/me/one", label: "one", current: true, sessions: [row("a")]),
            SessionGroup(cwd: "/home/me/two", label: "two", current: false, sessions: [row("b")]),
        ]
        XCTAssertEqual(workspaceLabel(of: row("a"), in: groups), "one")
        XCTAssertEqual(workspaceLabel(of: row("b"), in: groups), "two")
    }

    /// A session the store has not listed — one created a moment ago, or one whose store has since gone —
    /// has no workspace, and the answer is empty rather than an educated guess: the caller's rule is to
    /// draw nothing, and a guess would be a row claiming to be somewhere it is not.
    func testASessionOutsideEveryGroupHasNoWorkspace() {
        let groups = [
            SessionGroup(cwd: "/home/me/one", label: "one", current: true, sessions: [row("a")])
        ]
        XCTAssertEqual(workspaceLabel(of: row("elsewhere"), in: groups), "")
        XCTAssertEqual(workspaceLabel(of: row("a"), in: []), "")
    }

    /// A row's identity is its path: the label can change under a rename and a list must not then
    /// treat the same session as two. The eight hex characters are a name the shell sends, not the
    /// identity — two workspaces could hold sessions whose ids collide.
    func testTheIdentityOfARowIsItsPath() throws {
        let event = try XCTUnwrap(ShellEvent.decode(line: sessionsLine))
        guard case let .sessions(workspaces) = event else { return XCTFail("expected sessions") }
        let row = workspaces[0].sessions[0]
        XCTAssertEqual(row.id, row.path)
        XCTAssertEqual(workspaces[0].id, workspaces[0].cwd)
    }

    /// A history is rows, and every row in it is finished — which is what lets the view render its
    /// markdown instead of paying to re-parse a block that is still growing.
    func testAHistoryArrivesAsRows() throws {
        let line = #"""
        {"kind":"history","rows":[{"kind":"user","id":"h-1","text":"list it","complete":true,"name":"","detail":"","output":"","error":false},{"kind":"tool","id":"h-2","text":"","complete":true,"name":"bash","detail":"ls","output":"a.txt","error":false}]}
        """#
        let event = try XCTUnwrap(ShellEvent.decode(line: line))
        guard case let .history(rows, _, _) = event else {
            return XCTFail("expected history, got \(event)")
        }
        XCTAssertEqual(rows.map(\.kind), [.user, .tool])
        XCTAssertEqual(rows[0].text, "list it")
        XCTAssertEqual(rows[1].name, "bash")
        XCTAssertEqual(rows[1].detail, "ls")
        XCTAssertEqual(rows[1].output, "a.txt")
        XCTAssertFalse(rows[1].isError)
        XCTAssertTrue(rows.allSatisfy(\.complete))
    }

    /// A switch says which session is open — as the routing field — and does not disturb the transcript
    /// in between. What is in the session arrives after, as either a history or nothing at all.
    func testASwitchNamesTheSessionWithoutTouchingTheTranscript() throws {
        let envelope = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"session","session":"/store/s2.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash"}"#
            )
        )
        XCTAssertEqual(envelope.session, "/store/s2.jsonl")
        guard case let .session(cwd, model, interrupted, prompt) = envelope.event else {
            return XCTFail("expected session, got \(envelope.event)")
        }
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(model, "DeepSeek V4 Flash")
        // Absent on the wire means false, which is what an older shell's event decodes to: the
        // interruption notice is simply not drawn rather than the whole event being refused.
        XCTAssertFalse(interrupted)
        XCTAssertEqual(prompt, "")

        var conversation = Conversation()
        conversation.apply(.user(text: "the old session's question", continued: false, images: []))
        conversation.apply(envelope.event)
        XCTAssertEqual(conversation.rows.count, 1)
    }
}

/// The settings, from the side that reads them.
///
/// The literal is the shape `Shell::say_settings` writes. Two facts about it are asserted separately
/// because they are the ones a reader is affected by: a key from the environment overruling a saved
/// one, and the path of the file to edit by hand.
final class SettingsTests: XCTestCase {
    /// The whole event, as `Shell::say_settings` writes it: the five settings kinds a running process
    /// can honour, and the file they live in.
    ///
    /// The two skills are deliberately one of each: a skill with a file behind it and one whose file
    /// is gone, which is the row that exists only so its switch can be undone.
    private let settingsLine = #"""
    {"kind":"settings","key":"environment","env":true,"saved":true,"mode":"code","path":"/Users/me/.wei/settings.json","skills":[{"name":"moonbit","description":"How to build and test this project","path":"/Users/me/.wei/skills/moonbit/SKILL.md","enabled":true},{"name":"gone","description":"","path":"","enabled":false}],"instructions":"Run the tests with moon test.","instructions_source":"saved","limits":{"rounds":{"value":"200","source":"default"},"cost":{"value":"0.05","source":"saved"},"seconds":{"value":"1800","source":"flag"}}}
    """#

    func testSettingsNameTheKeySourceAndTheMode() throws {
        let event = try XCTUnwrap(ShellEvent.decode(line: settingsLine))
        guard case let .settings(settings) = event else {
            return XCTFail("expected settings, got \(event)")
        }
        XCTAssertEqual(settings.key, "environment")
        XCTAssertTrue(settings.env)
        XCTAssertTrue(settings.saved)
        XCTAssertEqual(settings.mode, "code")
        XCTAssertEqual(settings.path, "/Users/me/.wei/settings.json")
        XCTAssertTrue(settings.savedKeyIsOverruled)
        XCTAssertEqual(settings.keySummary, "In use, from DEEPSEEK_API_KEY")
        // The skills list carries a switched-off name with no file, because that is the row a reader
        // needs in order to turn it back on.
        XCTAssertEqual(settings.skills.map(\.name), ["moonbit", "gone"])
        XCTAssertTrue(settings.skills[0].enabled)
        XCTAssertFalse(settings.skills[1].enabled)
        XCTAssertTrue(settings.skills[1].path.isEmpty)
        // The instructions and where they came from: the two disagreeing is the case the panel has to
        // explain, and it cannot explain what it was not told.
        XCTAssertEqual(settings.instructions, "Run the tests with moon test.")
        XCTAssertEqual(settings.instructionsSource, "saved")
        // Each limit carries its own source, because one flag can set one of the three.
        XCTAssertEqual(settings.limits.rounds.value, "200")
        XCTAssertEqual(settings.limits.cost.value, "0.05")
        XCTAssertFalse(settings.limits.rounds.isFromFlag)
        XCTAssertTrue(settings.limits.seconds.isFromFlag)
        XCTAssertEqual(settings.limits.seconds.source, "flag")
    }

    /// A machine with nothing saved and nothing in the environment: the state the panel exists to get
    /// a person out of, and the one that has to be legible rather than empty.
    func testNoKeyIsAStateAndNotAnAbsence() throws {
        let line = #"{"kind":"settings","key":"none","env":false,"saved":false,"mode":"tools","path":"/tmp/settings.json","skills":[],"instructions":"","instructions_source":"none","limits":{"rounds":{"value":"200","source":"default"},"cost":{"value":"1","source":"default"},"seconds":{"value":"1800","source":"default"}}}"#
        let event = try XCTUnwrap(ShellEvent.decode(line: line))
        guard case let .settings(settings) = event else {
            return XCTFail("expected settings, got \(event)")
        }
        XCTAssertEqual(settings.key, "none")
        XCTAssertEqual(settings.keySummary, "No key: the first turn will fail")
        XCTAssertFalse(settings.savedKeyIsOverruled)
        // Nothing discovered and nothing saved is a state, not an absence: the panel says so rather
        // than drawing an empty box where a list should be.
        XCTAssertTrue(settings.skills.isEmpty)
        XCTAssertEqual(settings.instructionsSource, "none")
    }

    /// The panel's facts do not disturb the transcript, for the same reason the sidebar's do not.
    func testSettingsDoNotTouchTheTranscript() throws {
        let event = try XCTUnwrap(ShellEvent.decode(line: settingsLine))
        var conversation = Conversation()
        conversation.apply(.user(text: "hi", continued: false, images: []))
        conversation.apply(event)
        XCTAssertEqual(conversation.rows.count, 1)
    }
}

/// The markdown the shell parses, from the side that draws it.
///
/// The literals here are the ones `macos/appffi/app_wbtest.mbt` asserts, and that is the point of the
/// package bounds: the shell parses with cmark, the host draws from this shape, and neither can rename
/// a field without the other's build failing.
///
/// These are the cases `AttributedString(markdown:)` — what the app used before `md/` existed — gets
/// wrong, which is why the parse crosses as data rather than as source.
final class BlockTests: XCTestCase {
    private func decode(_ line: String) -> ShellEvent? {
        ShellEvent.decode(line: line)
    }

    /// The three shapes a native markdown implementation gets wrong, and the one it has no answer for.
    func testTheFourShapesThatMadeThisNecessary() throws {
        // A fence keeps its language, which is what a host uses to pick a highlight or at least a label.
        let code = try XCTUnwrap(
            decode(#"{"kind":"blocks","id":"reply-1","blocks":[{"t":"code","lang":"moonbit","text":"fn main {}"}]}"#)
        )
        guard case let .blocks(_, blocks, _) = code else { return XCTFail("expected blocks") }
        guard case let .code(lang, text) = blocks[0] else { return XCTFail("expected a fence") }
        XCTAssertEqual(lang, "moonbit")
        XCTAssertEqual(text, "fn main {}")

        // A table, with its alignments — a thing `AttributedString` does not parse at all.
        let table = try XCTUnwrap(
            decode(
                #"{"kind":"blocks","id":"reply-2","blocks":[{"t":"table","header":[[{"t":"text","text":"a"}],[{"t":"text","text":"b"}]],"rows":[[[{"t":"text","text":"1"}],[{"t":"text","text":"2"}]]],"align":["left","right"]}]}"#
            )
        )
        guard case let .blocks(_, tableBlocks, _) = table else { return XCTFail("expected blocks") }
        guard case let .table(header, rows, align) = tableBlocks[0] else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(align, [.left, .right])

        // A heading, whose level is a number rather than six font sizes the host has to guess at.
        let heading = try XCTUnwrap(
            decode(#"{"kind":"blocks","id":"reply-3","blocks":[{"t":"h","level":3,"spans":[{"t":"text","text":"Title"}]}]}"#)
        )
        guard case let .blocks(_, headings, _) = heading else { return XCTFail("expected blocks") }
        guard case let .heading(level, spans) = headings[0] else { return XCTFail("expected a heading") }
        XCTAssertEqual(level, 3)
        XCTAssertEqual(spans, [.text("Title")])

        // And a nested list item, which the host has to draw as a container: the parse keeps an item's
        // second block inside that item.
        let list = try XCTUnwrap(
            decode(
                #"{"kind":"blocks","id":"reply-4","blocks":[{"t":"ul","items":[[{"t":"p","spans":[{"t":"text","text":"one"}]}],[{"t":"p","spans":[{"t":"text","text":"two"}]},{"t":"ul","items":[[{"t":"p","spans":[{"t":"text","text":"nested"}]}]]}]]}]}"#
            )
        )
        guard case let .blocks(_, lists, _) = list else { return XCTFail("expected blocks") }
        guard case let .bullets(items) = lists[0] else { return XCTFail("expected a list") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1].count, 2, "the nested list belongs to the second item")
    }

    /// The styles, which is the part of markdown that nests.
    ///
    /// A flat span list with the nesting *inside* each case: `***both***` arrives as `strong` holding
    /// `emph`, and the host applies one on top of the other as it descends rather than walking a tree it
    /// cannot see.
    func testSpansCarryTheirOwnNesting() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"blocks","id":"reply-5","blocks":[{"t":"p","spans":[{"t":"text","text":"a "},{"t":"strong","spans":[{"t":"em","spans":[{"t":"text","text":"both"}]}]},{"t":"code","text":"x"},{"t":"link","url":"https://x.y","spans":[{"t":"text","text":"here"}]}]}]}"#
            )
        )
        guard case let .blocks(_, blocks, _) = event else { return XCTFail("expected blocks") }
        guard case let .paragraph(spans) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[0], .text("a "))
        XCTAssertEqual(spans[1], .strong([.emph([.text("both")])]))
        XCTAssertEqual(spans[2], .code("x"))
        XCTAssertEqual(spans[3], .link(url: "https://x.y", spans: [.text("here")]))
    }

    /// A picture, which is the one span the host does not draw as text.
    ///
    /// The field name is what this pins: `md/json.mbt` writes `url` and `alt`, and a rename on either
    /// side of the boundary is two builds that disagree about the same answer. The producer asserts the
    /// same literal in `md/json_test.mbt`.
    func testAPictureArrivesWithItsAltText() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"blocks","id":"reply-6","blocks":[{"t":"p","spans":[{"t":"image","url":"/tmp/shot.png","alt":"a chart"}]}]}"#
            )
        )
        guard case let .blocks(_, blocks, _) = event else { return XCTFail("expected blocks") }
        guard case let .paragraph(spans) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans, [.image(url: "/tmp/shot.png", alt: "a chart")])
    }

    /// A parse lands in the row it names, and the row keeps its text.
    func testABlockParseIsPatchedIntoTheRowItNames() {
        var conversation = Conversation()
        conversation.apply(.reply(id: "reply-1", delta: "| a | b |"))
        XCTAssertNil(conversation.rows[0].blocks, "a row that is still arriving is drawn as text")

        conversation.apply(
            .blocks(
                id: "reply-1",
                blocks: [.table(header: [[.text("a")], [.text("b")]], rows: [], align: [.left, .right])],
                from: 0
            )
        )
        XCTAssertNotNil(conversation.rows[0].blocks)
        XCTAssertEqual(conversation.rows[0].text, "| a | b |", "the text is what the parse is of")

        // A parse for a row that is not here is dropped rather than appended: it describes text that
        // this conversation does not have.
        conversation.apply(.blocks(id: "reply-99", blocks: [.rule], from: 0))
        XCTAssertEqual(conversation.rows.count, 1)
    }

    /// A history arrives with its parses already in it, which is the whole point of sending them.
    func testAHistoryRowCarriesItsParse() throws {
        let line = #"""
        {"kind":"history","rows":[{"kind":"reply","id":"h-1","text":"# Title","complete":true,"blocks":[{"t":"h","level":1,"spans":[{"t":"text","text":"Title"}]}],"name":"","detail":"","output":"","error":false}]}
        """#
        let event = try XCTUnwrap(decode(line))
        guard case let .history(rows, _, _) = event else { return XCTFail("expected history") }
        XCTAssertTrue(rows[0].complete)
        guard case let .heading(level, spans)? = rows[0].blocks?[0] else {
            return XCTFail("the row's parse did not survive decoding")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(spans, [.text("Title")])
    }

    /// A row with nothing to parse says so with `null`, and one that is still arriving says nothing —
    /// both are `nil` here, which is why the view's rule is "blocks if they are here, text otherwise".
    func testNoParseIsNilRatherThanEmpty() throws {
        let row = try XCTUnwrap(
            decode(
                #"{"kind":"history","rows":[{"kind":"tool","id":"h-1","text":"","complete":true,"blocks":null,"name":"bash","detail":"ls","output":"","error":false}]}"#
            )
        )
        guard case let .history(rows, _, _) = row else { return XCTFail("expected history") }
        XCTAssertNil(rows[0].blocks)
    }

    /// A live frame names the block it starts at, and it is the one field a host has to understand to
    /// render an answer while it arrives: the head is what it already holds, the tail is the new part.
    func testALiveFrameNamesWhereItsBlocksStart() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"blocks","id":"reply-1-1","from":2,"blocks":[{"t":"p","spans":[{"t":"text","text":"more"}]}]}"#
            )
        )
        guard case let .blocks(id, blocks, from) = event else { return XCTFail("expected blocks") }
        XCTAssertEqual(id, "reply-1-1")
        XCTAssertEqual(from, 2)
        XCTAssertEqual(blocks.count, 1)
    }

    /// A shell that predates the field sends a block whole, and the host reads that as `from: 0` —
    /// being wrong about the default here would append a whole document to the head of itself.
    func testAFrameWithoutFromIsTheWholeBlock() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"blocks","id":"reply-1","blocks":[{"t":"hr"}]}"#
            )
        )
        guard case let .blocks(_, _, from) = event else { return XCTFail("expected blocks") }
        XCTAssertEqual(from, 0)
    }

    /// The head the host already has and the tail it is just being sent are **one document** again.
    func testALiveFrameIsAppendedToTheBlocksAlreadyHeld() {
        var conversation = Conversation()
        conversation.apply(.reply(id: "reply-1-1", delta: "one\n\ntwo"))
        conversation.apply(.blocks(id: "reply-1-1", blocks: [paragraph("one")], from: 0))
        conversation.apply(.blocks(id: "reply-1-1", blocks: [paragraph("two")], from: 1))
        XCTAssertEqual(conversation.rows[0].blocks, [paragraph("one"), paragraph("two")])
    }

    /// A **last** live frame can also correct a block that was sent too early — the text of the block
    /// it names is replaced, which is what makes a half-arrived table become a table.
    func testALiveFrameCanReplaceTheBlockItNames() {
        var conversation = Conversation()
        conversation.apply(.reply(id: "reply-1-1", delta: "| a |"))
        conversation.apply(.blocks(id: "reply-1-1", blocks: [paragraph("| a |")], from: 0))
        conversation.apply(
            .blocks(
                id: "reply-1-1",
                blocks: [.table(header: [[.text("a")]], rows: [[[.text("1")]]], align: [.left])],
                from: 0
            )
        )
        guard case .table? = conversation.rows[0].blocks?[0] else {
            return XCTFail("a finished block is sent whole and replaces what was there")
        }
    }

    /// A tail for a row the host has no head of is dropped rather than guessed at: appending it would
    /// draw half a document as if it were the whole one.
    func testATailWithoutAHeadIsDropped() {
        var conversation = Conversation()
        conversation.apply(.reply(id: "reply-1-1", delta: "two"))
        conversation.apply(.blocks(id: "reply-1-1", blocks: [paragraph("two")], from: 3))
        XCTAssertNil(conversation.rows[0].blocks)
    }

    /// The text that was arriving is over the moment a tool is asked for, not the moment it answers.
    ///
    /// This is what the shell does — it closes the block and parses it there — and the host has to
    /// agree, because `complete` is what decides whether a reasoning block is drawn as a three-line
    /// peek or as one folded line. Getting it wrong leaves a block peeking at its tail for as long as
    /// a `bash` call takes.
    func testAToolCallEndsTheTextThatWasArriving() {
        var conversation = Conversation()
        conversation.apply(.thinking(id: "thinking-1-1", delta: "thinking about it"))
        XCTAssertFalse(conversation.rows[0].complete)
        conversation.apply(
            .tool(id: "tool-1-1", name: "bash", detail: "ls", done: false, output: "", isError: false)
        )
        XCTAssertTrue(conversation.rows[0].complete, "the reasoning block ended when the tool started")
        XCTAssertFalse(conversation.rows[1].complete, "and the tool itself is still running")
    }

    private func paragraph(_ text: String) -> Block {
        .paragraph([.text(text)])
    }
}
