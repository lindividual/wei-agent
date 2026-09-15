import XCTest

@testable import PiModel

/// The sidebar and the history, from the side that reads them.
///
/// The literals here are the ones `macos/appffi/app_wbtest.mbt` asserts from the side that writes them
/// — the same arrangement as `EventTests`, and for the same reason: a field renamed on one side and
/// not the other stops a build here rather than producing a sidebar that never fills.
final class SidebarTests: XCTestCase {
    /// A session list, exactly as `sessions_event` writes it.
    private let sessionsLine = #"""
    {"kind":"sessions","workspaces":[{"cwd":"/home/me/project","label":"project","current":true,"sessions":[{"path":"/store/--home-me-project--/2026-08-23T06-26-15.210Z_01a02d4c.jsonl","id":"01a02d4c","label":"set up the project","modified":1787466378656,"current":true,"running":false}]}]}
    """#

    func testSessionsCarryTheirWorkspacesAndTheirRows() throws {
        let event = try XCTUnwrap(PiEvent.decode(line: sessionsLine))
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

    /// A row's identity is its path: the label can change under a rename and a list must not then
    /// treat the same session as two. The eight hex characters are a name the shell sends, not the
    /// identity — two workspaces could hold sessions whose ids collide.
    func testTheIdentityOfARowIsItsPath() throws {
        let event = try XCTUnwrap(PiEvent.decode(line: sessionsLine))
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
        let event = try XCTUnwrap(PiEvent.decode(line: line))
        guard case let .history(rows) = event else {
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

    /// A switch says which session is open. It does not say what is in it — that is the history that
    /// follows — and it does not disturb the transcript in between.
    func testASwitchNamesTheSessionWithoutTouchingTheTranscript() throws {
        let event = try XCTUnwrap(
            PiEvent.decode(
                line: #"{"kind":"session","path":"/store/s2.jsonl","cwd":"/tmp","model":"DeepSeek V4 Flash"}"#
            )
        )
        guard case let .session(path, cwd, model) = event else {
            return XCTFail("expected session, got \(event)")
        }
        XCTAssertEqual(path, "/store/s2.jsonl")
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(model, "DeepSeek V4 Flash")

        var conversation = Conversation()
        conversation.apply(.user(text: "the old session's question"))
        conversation.apply(event)
        XCTAssertEqual(conversation.rows.count, 1)
    }
}

/// The settings, from the side that reads them.
///
/// The literal is the shape `Shell::say_settings` writes. Two facts about it are asserted separately
/// because they are the ones a reader is affected by: a key from the environment overruling a saved
/// one, and the path of the file to edit by hand.
final class SettingsTests: XCTestCase {
    private let settingsLine = #"""
    {"kind":"settings","key":"environment","env":true,"saved":true,"mode":"code","path":"/Users/me/.pi-mb/settings.json"}
    """#

    func testSettingsNameTheKeySourceAndTheMode() throws {
        let event = try XCTUnwrap(PiEvent.decode(line: settingsLine))
        guard case let .settings(settings) = event else {
            return XCTFail("expected settings, got \(event)")
        }
        XCTAssertEqual(settings.key, "environment")
        XCTAssertTrue(settings.env)
        XCTAssertTrue(settings.saved)
        XCTAssertEqual(settings.mode, "code")
        XCTAssertEqual(settings.path, "/Users/me/.pi-mb/settings.json")
        XCTAssertTrue(settings.savedKeyIsOverruled)
        XCTAssertEqual(settings.keySummary, "In use, from DEEPSEEK_API_KEY")
    }

    /// A machine with nothing saved and nothing in the environment: the state the panel exists to get
    /// a person out of, and the one that has to be legible rather than empty.
    func testNoKeyIsAStateAndNotAnAbsence() throws {
        let line = #"{"kind":"settings","key":"none","env":false,"saved":false,"mode":"tools","path":"/tmp/settings.json"}"#
        let event = try XCTUnwrap(PiEvent.decode(line: line))
        guard case let .settings(settings) = event else {
            return XCTFail("expected settings, got \(event)")
        }
        XCTAssertEqual(settings.key, "none")
        XCTAssertEqual(settings.keySummary, "No key: the first turn will fail")
        XCTAssertFalse(settings.savedKeyIsOverruled)
    }

    /// The panel's facts do not disturb the transcript, for the same reason the sidebar's do not.
    func testSettingsDoNotTouchTheTranscript() throws {
        let event = try XCTUnwrap(PiEvent.decode(line: settingsLine))
        var conversation = Conversation()
        conversation.apply(.user(text: "hi"))
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
    private func decode(_ line: String) -> PiEvent? {
        PiEvent.decode(line: line)
    }

    /// The three shapes a native markdown implementation gets wrong, and the one it has no answer for.
    func testTheFourShapesThatMadeThisNecessary() throws {
        // A fence keeps its language, which is what a host uses to pick a highlight or at least a label.
        let code = try XCTUnwrap(
            decode(#"{"kind":"blocks","id":"reply-1","blocks":[{"t":"code","lang":"moonbit","text":"fn main {}"}]}"#)
        )
        guard case let .blocks(_, blocks) = code else { return XCTFail("expected blocks") }
        guard case let .code(lang, text) = blocks[0] else { return XCTFail("expected a fence") }
        XCTAssertEqual(lang, "moonbit")
        XCTAssertEqual(text, "fn main {}")

        // A table, with its alignments — a thing `AttributedString` does not parse at all.
        let table = try XCTUnwrap(
            decode(
                #"{"kind":"blocks","id":"reply-2","blocks":[{"t":"table","header":[[{"t":"text","text":"a"}],[{"t":"text","text":"b"}]],"rows":[[[{"t":"text","text":"1"}],[{"t":"text","text":"2"}]]],"align":["left","right"]}]}"#
            )
        )
        guard case let .blocks(_, tableBlocks) = table else { return XCTFail("expected blocks") }
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
        guard case let .blocks(_, headings) = heading else { return XCTFail("expected blocks") }
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
        guard case let .blocks(_, lists) = list else { return XCTFail("expected blocks") }
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
        guard case let .blocks(_, blocks) = event else { return XCTFail("expected blocks") }
        guard case let .paragraph(spans) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[0], .text("a "))
        XCTAssertEqual(spans[1], .strong([.emph([.text("both")])]))
        XCTAssertEqual(spans[2], .code("x"))
        XCTAssertEqual(spans[3], .link(url: "https://x.y", spans: [.text("here")]))
    }

    /// A parse lands in the row it names, and the row keeps its text.
    func testABlockParseIsPatchedIntoTheRowItNames() {
        var conversation = Conversation()
        conversation.apply(.reply(id: "reply-1", delta: "| a | b |"))
        XCTAssertNil(conversation.rows[0].blocks, "a row that is still arriving is drawn as text")

        conversation.apply(
            .blocks(
                id: "reply-1",
                blocks: [.table(header: [[.text("a")], [.text("b")]], rows: [], align: [.left, .right])]
            )
        )
        XCTAssertNotNil(conversation.rows[0].blocks)
        XCTAssertEqual(conversation.rows[0].text, "| a | b |", "the text is what the parse is of")

        // A parse for a row that is not here is dropped rather than appended: it describes text that
        // this conversation does not have.
        conversation.apply(.blocks(id: "reply-99", blocks: [.rule]))
        XCTAssertEqual(conversation.rows.count, 1)
    }

    /// A history arrives with its parses already in it, which is the whole point of sending them.
    func testAHistoryRowCarriesItsParse() throws {
        let line = #"""
        {"kind":"history","rows":[{"kind":"reply","id":"h-1","text":"# Title","complete":true,"blocks":[{"t":"h","level":1,"spans":[{"t":"text","text":"Title"}]}],"name":"","detail":"","output":"","error":false}]}
        """#
        let event = try XCTUnwrap(decode(line))
        guard case let .history(rows) = event else { return XCTFail("expected history") }
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
        guard case let .history(rows) = row else { return XCTFail("expected history") }
        XCTAssertNil(rows[0].blocks)
    }
}
