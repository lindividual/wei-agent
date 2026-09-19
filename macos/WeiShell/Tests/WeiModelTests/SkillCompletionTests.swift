import XCTest

@testable import WeiModel

/// When the composer offers to finish a skill, and what it offers.
///
/// The rule lives in `SkillCompletion` rather than in the view, and this is the reason: the two ways to
/// get it wrong are both about *timing*, not about the list. A menu that opens over `/usr/local/bin`
/// interrupts somebody writing a path, and one that stays shut for `/sk` hides the thing it exists to
/// show. Neither is visible in a screenshot taken at a convenient moment, so both are asserted here.
final class SkillCompletionTests: XCTestCase {
    private func skills() -> [SkillEntry] {
        [
            SkillEntry(name: "moonbit", description: "MoonBit help", path: "/s/moonbit/SKILL.md", enabled: true),
            SkillEntry(name: "demo", description: "A demo skill", path: "/s/demo/SKILL.md", enabled: true),
            SkillEntry(name: "muted", description: "Switched off", path: "/s/muted/SKILL.md", enabled: false),
        ]
    }

    private func names(_ draft: String) -> [String] {
        SkillCompletion.matches(draft: draft, skills: skills()).map(\.name)
    }

    /// The feature: a bare slash is a question, and every enabled skill is an answer to it.
    func testABareSlashOffersEveryEnabledSkill() {
        XCTAssertEqual(names("/"), ["moonbit", "demo"])
        XCTAssertEqual(names("/s"), ["moonbit", "demo"])
    }

    /// A switched-off skill is not offered, because invoking it does nothing — the shell refuses to
    /// expand it and the model was never told it exists.
    func testASwitchedOffSkillIsNotOffered() {
        XCTAssertEqual(names("/skill:"), ["moonbit", "demo"])
        XCTAssertTrue(names("/skill:mut").isEmpty)
    }

    /// The partial spelling is matched whole, so the menu narrows as the reader types the command
    /// rather than the name.
    func testAPartialCommandNarrows() {
        XCTAssertEqual(names("/sk"), ["moonbit", "demo"])
        XCTAssertEqual(names("/skill:mo"), ["moonbit"])
        XCTAssertEqual(names("/skill:de"), ["demo"])
    }

    /// What has been typed out in full is not a suggestion: a one-row menu offering the reader their own
    /// text is noise in the way of pressing Return.
    func testAnExactMatchOffersNothing() {
        XCTAssertTrue(names("/skill:demo").isEmpty)
        XCTAssertTrue(names("/skill:moonbit").isEmpty)
    }

    /// A finished command with an argument is not a command being typed. The space is the whole test,
    /// and it is also what keeps a path and a division out of the menu.
    func testASpaceEndsTheCommand() {
        XCTAssertTrue(names("/skill:demo do the thing").isEmpty)
        XCTAssertTrue(names("/usr/local/bin").isEmpty)
        XCTAssertTrue(names("2 / 3").isEmpty)
        XCTAssertTrue(names("hello").isEmpty)
        XCTAssertTrue(names("").isEmpty)
    }

    /// Whitespace around the draft is not a decision the reader made, so it is trimmed before the test.
    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(names("  /skill:mo  "), ["moonbit"])
        XCTAssertEqual(names("\n/"), ["moonbit", "demo"])
    }

    /// The name is matched case-insensitively — `/skill:MO` is somebody reaching for `moonbit` — while the
    /// inserted text keeps the skill's own spelling, because that is what the shell expands.
    func testTheNameIsMatchedCaseInsensitivelyAndInsertedAsWritten() {
        let skills = [
            SkillEntry(name: "MoonBit", description: "", path: "/s/SKILL.md", enabled: true)
        ]
        XCTAssertEqual(SkillCompletion.matches(draft: "/skill:mo", skills: skills).map(\.name), ["MoonBit"])
        XCTAssertEqual(SkillCompletion.spelling(skills[0]), "/skill:MoonBit")
    }

    /// The row's text and the text the row inserts are the same spelling, so the menu cannot show one
    /// command and insert another.
    func testTheRowAndTheInsertionAgree() {
        XCTAssertEqual(SkillCompletion.spelling(skills()[0]), "/skill:moonbit")
    }

    /// The ends of the menu are the ends: a held arrow key stops rather than coming round again.
    func testTheHighlightStopsAtBothEnds() {
        XCTAssertEqual(SkillCompletion.move(from: 2, by: 1, count: 3), 2)
        XCTAssertEqual(SkillCompletion.move(from: 0, by: -1, count: 3), 0)
        XCTAssertEqual(SkillCompletion.move(from: 1, by: 1, count: 3), 2)
        XCTAssertEqual(SkillCompletion.move(from: 1, by: -1, count: 3), 0)
    }

    /// An empty menu has no row to be on, and the arithmetic still has to answer — it is asked on every
    /// keystroke, including the ones that narrow the last match away.
    func testAnEmptyMenuHasNoRowOne() {
        XCTAssertEqual(SkillCompletion.move(from: 3, by: 1, count: 0), 0)
        XCTAssertEqual(SkillCompletion.move(from: 3, by: -1, count: 0), 0)
    }
}
