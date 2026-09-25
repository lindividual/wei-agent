import XCTest

@testable import WeiModel

/// The project column: what it draws, and the order the reader has put it in.
///
/// A test file of its own because these are the column's *own* rules — the fold and the reader's
/// order — where `SidebarTests` is about what the shell sent. Both are arithmetic on the same
/// `SessionGroup` list, and neither needs a window to be wrong.
final class WorkspaceColumnTests: XCTestCase {
    /// A list of named projects, in the order given, with one session each so that they are groups
    /// rather than bare names — the same shape the shell sends for a store with one conversation per
    /// project.
    private func workspaces(_ names: String...) -> [SessionGroup] {
        workspaces(names)
    }

    private func workspaces(_ names: [String]) -> [SessionGroup] {
        names.map { name in
            SessionGroup(
                cwd: "/work/\(name)", label: name, current: false,
                sessions: [
                    SessionRow(
                        path: "/store/\(name)/s.jsonl", shortID: name, label: name,
                        modified: 0, current: false, running: false
                    )
                ]
            )
        }
    }

    /// Six is where the fold appears: five is what the column lists, and the sixth row is the fold
    /// rather than a project.
    func testTheColumnFoldsWhatIsPastTheLimit() {
        let six = workspaces("a", "b", "c", "d", "e", "f")

        let folded = workspaceColumn(six, expanded: false)

        XCTAssertEqual(folded.shown.map(\.label), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(folded.hidden, 1, "the row says how much is behind it")
    }

    /// Five and fewer are left alone, and `hidden` is zero: that is how the caller knows not to draw a
    /// fold row at all, which is the difference between "no fold" and "a fold over nothing".
    func testAListThatFitsHasNoFold() {
        for count in 0...workspaceFoldLimit {
            let some = workspaces(Array("abcde").prefix(count).map(String.init))
            let column = workspaceColumn(some, expanded: false)
            XCTAssertEqual(column.shown.count, count)
            XCTAssertEqual(column.hidden, 0, "\(count) projects should not fold")
        }
    }

    /// Opening the fold shows everything and *keeps the count*: the row is still the control that
    /// closes it again, and once the list is open the count is the only thing left that says how many
    /// rows that will take away.
    func testOpeningTheFoldShowsEveryProjectAndKeepsTheCount() {
        let eight = workspaces("a", "b", "c", "d", "e", "f", "g", "h")

        let open = workspaceColumn(eight, expanded: true)

        XCTAssertEqual(open.shown.map(\.label), ["a", "b", "c", "d", "e", "f", "g", "h"])
        XCTAssertEqual(open.hidden, 3)
    }

    /// The two labels, and the count in the folded one: "Show More" over a list the reader cannot
    /// count says a row goes somewhere without saying whether what they are looking for is behind it.
    func testTheFoldRowSaysHowMuchItIsCovering() {
        XCTAssertEqual(workspaceFoldLabel(hidden: 1, expanded: false), "Show 1 More")
        XCTAssertEqual(workspaceFoldLabel(hidden: 17, expanded: false), "Show 17 More")
        XCTAssertEqual(workspaceFoldLabel(hidden: 17, expanded: true), "Show Less")
    }

    /// A project the fold is hiding is reported as hidden, and one that is drawn is not — which is what
    /// the fold row's mark is drawn from.
    func testTheFoldKnowsWhichProjectsItIsHiding() {
        let eight = workspaces("a", "b", "c", "d", "e", "f", "g", "h")

        XCTAssertFalse(workspaceIsBehindFold(eight, cwd: "/work/c", expanded: false))
        XCTAssertTrue(workspaceIsBehindFold(eight, cwd: "/work/g", expanded: false))
        XCTAssertFalse(workspaceIsBehindFold(eight, cwd: "/work/g", expanded: true))
    }

    /// A list that fits hides nothing, and a project the list does not hold is not "hidden" either: there
    /// is no row for it to be behind, and a mark over a fold that does not contain what it claims would be
    /// worse than no mark.
    func testNothingIsHiddenWithoutAFoldOrWithoutTheProject() {
        let three = workspaces("a", "b", "c")

        XCTAssertFalse(workspaceIsBehindFold(three, cwd: "/work/c", expanded: false))
        XCTAssertFalse(workspaceIsBehindFold(three, cwd: "/work/gone", expanded: false))
        XCTAssertFalse(workspaceIsBehindFold([], cwd: "/work/a", expanded: false))
        XCTAssertFalse(workspaceIsBehindFold(three, cwd: "", expanded: false))
    }

    /// The move the reader asked for, in both directions: the project takes the place of the one it
    /// passed, and that one moves up — a trade, not a rotation of the list.
    func testAProjectMovesUpAndDownOnePlace() {
        let five = workspaces("a", "b", "c", "d", "e")

        XCTAssertEqual(
            movingWorkspace(five, cwd: "/work/c", .up).map(\.label),
            ["a", "c", "b", "d", "e"]
        )
        XCTAssertEqual(
            movingWorkspace(five, cwd: "/work/c", .down).map(\.label),
            ["a", "b", "d", "c", "e"]
        )
    }

    /// Twice is two moves — the menu has one place at a time and no "move to top", so a project that has
    /// to travel three rows is asked three times, and each ask works on the *result* of the last rather
    /// than on an index the menu's own drawing has already moved past.
    func testTwoMovesAreTwoMoves() {
        let four = workspaces("a", "b", "c", "d")

        // `d` is the last of four: one place up is third, and the second ask takes it to second.
        let once = movingWorkspace(four, cwd: "/work/d", .up)
        XCTAssertEqual(once.map(\.label), ["a", "b", "d", "c"])
        XCTAssertEqual(
            movingWorkspace(once, cwd: "/work/d", .up).map(\.label),
            ["a", "d", "b", "c"]
        )
    }

    /// A move with nowhere to go is refused rather than clamped, and the menu item that would ask for
    /// it is not drawn: `canMoveWorkspace` is the same question, so the two cannot disagree.
    func testTheEndsOfTheListDoNotMove() {
        let three = workspaces("a", "b", "c")

        XCTAssertFalse(canMoveWorkspace(three, cwd: "/work/a", .up))
        XCTAssertFalse(canMoveWorkspace(three, cwd: "/work/c", .down))
        XCTAssertTrue(canMoveWorkspace(three, cwd: "/work/b", .up))
        XCTAssertTrue(canMoveWorkspace(three, cwd: "/work/b", .down))

        XCTAssertEqual(
            movingWorkspace(three, cwd: "/work/a", .up).map(\.label), ["a", "b", "c"],
            "the first project stayed put"
        )
        XCTAssertEqual(
            movingWorkspace(three, cwd: "/work/c", .down).map(\.label), ["a", "b", "c"],
            "the last project stayed put"
        )
    }

    /// A project the list does not hold: nothing happens, rather than an index out of range. The row's own
    /// `cwd` is what a menu item carries, and a row that has left the list between the menu being drawn and
    /// the click landing is the way in — a removal lands while a menu is open.
    func testAProjectThatIsNoLongerThereIsNotMoved() {
        let three = workspaces("a", "b", "c")

        XCTAssertFalse(canMoveWorkspace(three, cwd: "/work/gone", .up))
        XCTAssertFalse(canMoveWorkspace(three, cwd: "/work/gone", .down))
        XCTAssertEqual(movingWorkspace(three, cwd: "/work/gone", .down).map(\.label), ["a", "b", "c"])
        XCTAssertEqual(movingWorkspace(three, cwd: "/work/gone", .up).map(\.label), ["a", "b", "c"])
        XCTAssertEqual(movingWorkspace([], cwd: "/work/a", .down).map(\.label), [])
    }

    /// **The order the reader set is the order the next event keeps.** Moving a row is only useful if it
    /// survives the shell's own sorting: `list_workspaces` re-sends "most recently written first" on
    /// every `sessions` event, and `stableSidebarOrder` is what holds the column still under it — so the
    /// move has to come out of that pass unchanged. It does, because the order it returns is the order it
    /// was given.
    func testTheMovedOrderSurvivesTheNextSessionList() {
        let before = workspaces(["a", "b", "c", "d"])
        // `d` two places up, which is the move the menu makes twice.
        let moved = movingWorkspace(
            movingWorkspace(before, cwd: "/work/d", .up), cwd: "/work/d", .up
        )
        XCTAssertEqual(moved.map(\.label), ["a", "d", "b", "c"])

        // The next event, with the store's own order: the project written to last leads.
        let incoming = workspaces(["c", "a", "d", "b"])

        XCTAssertEqual(
            stableSidebarOrder(incoming: incoming, previous: moved).map(\.label),
            ["a", "d", "b", "c"],
            "the order the reader moved to, with every value refreshed from the wire"
        )
    }

    /// A project the reader did not reorder is still the shell's to place, and a project the list has
    /// never seen still joins at the top — moving a row does not change either rule.
    func testANewProjectStillJoinsAtTheTopOfAMovedList() {
        let before = workspaces(["a", "b", "c"])
        let moved = movingWorkspace(
            movingWorkspace(before, cwd: "/work/c", .up), cwd: "/work/c", .up
        )
        XCTAssertEqual(moved.map(\.label), ["c", "a", "b"])

        let incoming = workspaces(["a", "b", "c"]) + workspaces(["new"])

        XCTAssertEqual(
            stableSidebarOrder(incoming: incoming, previous: moved).map(\.label),
            ["new", "c", "a", "b"]
        )
    }
}
