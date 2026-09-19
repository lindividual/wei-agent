import XCTest

@testable import WeiModel

/// The wire, from the side that reads it — and against **the producer's own output**.
///
/// Every other decoding test in this directory carries its own JSON literal. That pins the field names
/// this side expects, but it cannot notice a rename only the *producer* made: two hand-written literals
/// cannot disagree with each other, so both builds stay green while the app stops working.
///
/// `macos/wire-fixtures.jsonl` is written by the shell's own emitters
/// (`macos/appffi/wire_fixture_wbtest.mbt`), so this asks the question the literals cannot: can the host
/// read what the shell actually sends, today.
///
/// Regenerate it with `WEI_UPDATE_FIXTURES=1 moon test -p macos/appffi`. If this test then fails, the
/// change to the wire is one the host has not learned yet.
final class WireFixtureTests: XCTestCase {

    /// The kinds the host must be able to name, in the order the shell emits them.
    ///
    /// Written out rather than derived from `ShellEvent`, so that adding a case to the enum is not
    /// silently satisfied by itself: the fixture is a fact about two sides agreeing, and this is one
    /// side's half of it.
    private static let expectedKinds = [
        "ready", "session", "elsewhere", "history", "earlier", "sessions", "deleted",
        "blocks", "settings", "user", "reply", "thinking", "images", "usage", "models",
        "think", "jobs", "tool", "status", "note", "end", "error",
    ]

    /// The three events that are about the **process** rather than about a conversation.
    ///
    /// They carry no routing field at all, which is the fact this test exists to keep honest: a `sessions`
    /// or `settings` or `jobs` event with an empty `session` is not "the one on screen", it is a fact with
    /// nowhere to be filed.
    private static let processWide: Set<String> = ["sessions", "settings", "jobs"]

    /// The fixture, found by walking up from this file to the repository root.
    ///
    /// Walked rather than hard-coded so that the test does not care where the checkout is, and skipped
    /// rather than failed when it cannot be found: this file is a cross-language contract, and a lone
    /// `swift test` outside a checkout has nothing to say about it.
    private func fixtureLines() throws -> [String] {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("macos/wire-fixtures.jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let text = try String(contentsOf: candidate, encoding: .utf8)
                return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
        }
        throw XCTSkip("no macos/wire-fixtures.jsonl above \(#filePath)")
    }

    /// **Every line the shell produces decodes, and it is the line the shell meant to produce.**
    func testEveryEventTheShellSendsCanBeDecoded() throws {
        let lines = try fixtureLines()
        XCTAssertEqual(
            lines.count,
            Self.expectedKinds.count,
            "the fixture should hold one line per kind"
        )

        var kinds: [String] = []
        for line in lines {
            guard let envelope = Envelope.decode(line: line) else {
                // Not a `XCTAssert` with a message: the failure that matters is *which* line, and a
                // truncated line is the only way to see it in a terminal.
                return XCTFail("the host cannot decode a line the shell sends: \(line.prefix(160))")
            }
            let kind = kindName(of: envelope.event)
            kinds.append(kind)

            // Routing: a conversation's events name the conversation. This is what keeps a background
            // turn's deltas out of the transcript on screen, and it is only real if the producer puts it
            // there — which is what the fixture proves.
            if Self.processWide.contains(kind) {
                XCTAssertEqual(
                    envelope.session,
                    "",
                    "\(kind) is about the process and should carry no session"
                )
            } else {
                XCTAssertFalse(
                    envelope.session.isEmpty,
                    "\(kind) names no session, so there is nowhere to file it"
                )
            }
        }

        XCTAssertEqual(kinds, Self.expectedKinds)
    }

    /// The name of a decoded event, for comparing against the fixture.
    ///
    /// A switch rather than a stored property on `ShellEvent`: naming events is a fact about *this test*
    /// (it is how the fixture is ordered), not something the app needs. It is exhaustive on purpose —
    /// a new case stops compiling here until somebody says what it is called, and then the fixture has
    /// to grow a line for it, because `testEveryEventTheShellSendsCanBeDecoded` counts them.
    private func kindName(of event: ShellEvent) -> String {
        switch event {
        case .ready: return "ready"
        case .session: return "session"
        case .elsewhere: return "elsewhere"
        case .history: return "history"
        case .earlier: return "earlier"
        case .sessions: return "sessions"
        case .deleted: return "deleted"
        case .blocks: return "blocks"
        case .settings: return "settings"
        case .user: return "user"
        case .reply: return "reply"
        case .thinking: return "thinking"
        case .images: return "images"
        case .usage: return "usage"
        case .models: return "models"
        case .think: return "think"
        case .jobs: return "jobs"
        case .tool: return "tool"
        case .status: return "status"
        case .note: return "note"
        case .end: return "end"
        case .error: return "error"
        }
    }
}
