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
