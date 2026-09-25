import SwiftUI
import XCTest

@testable import WeiModel

/// The drag's arithmetic, pinned against the platform's.
///
/// `List.onMove` hands over an `IndexSet` and an `Int`, and the one interesting thing about them is the
/// convention: the destination counts the lifted rows, so dropping a row in the gap below its neighbour is
/// **not** the same number as that neighbour's index. Getting it wrong by one is invisible in review and
/// obvious in the app (the row lands one place off, every time, in one direction).
///
/// So this file does not assert what the numbers "should" be. It takes the platform's own
/// `move(fromOffsets:toOffset:)` — the function SwiftUI's `onMove` is documented to be handed to — and
/// asserts that `WeiModel.movingWorkspace` agrees with it over every source and destination a four-row
/// list can produce. The note above `movingWorkspace` is then a description of a behaviour that is checked,
/// not a guess about one.
///
/// It lives in `WeiShellTests` rather than beside the other column tests because `move(fromOffsets:toOffset:)`
/// is SwiftUI's: `WeiModel` has no business importing a UI framework to reorder an array.
final class WorkspaceMoveTests: XCTestCase {
    private func rows(_ count: Int) -> [SessionGroup] {
        (0..<count).map { index in
            SessionGroup(
                cwd: "/work/\(index)", label: "\(index)", current: false,
                sessions: [
                    SessionRow(
                        path: "/store/\(index)/s.jsonl", shortID: "\(index)", label: "\(index)",
                        modified: 0, current: false, running: false
                    )
                ]
            )
        }
    }

    /// Every single-row drag a four-row list can be asked to carry out, against the platform.
    func testOneRowDragsAgreeWithThePlatform() {
        let four = rows(4)
        for from in 0..<4 {
            for destination in 0...4 {
                var platform = four
                platform.move(fromOffsets: IndexSet(integer: from), toOffset: destination)
                let mine = movingWorkspace(
                    four, from: IndexSet(integer: from), to: destination
                )
                XCTAssertEqual(
                    mine.map(\.label), platform.map(\.label),
                    "dragging row \(from) to \(destination) disagreed with the platform"
                )
            }
        }
    }

    /// And a multi-row drag, which is what a reader gets by selecting a run of rows — the platform allows
    /// it, so the arithmetic has to as well.
    func testARunOfRowsAgreesWithThePlatform() {
        let five = rows(5)
        for start in 0..<4 {
            for length in 1...(5 - start) {
                let source = IndexSet(integersIn: start..<(start + length))
                for destination in 0...5 {
                    var platform = five
                    platform.move(fromOffsets: source, toOffset: destination)
                    let mine = movingWorkspace(five, from: source, to: destination)
                    XCTAssertEqual(
                        mine.map(\.label), platform.map(\.label),
                        "moving \(Array(source)) to \(destination) disagreed with the platform"
                    )
                }
            }
        }
    }

    /// What the one-step menu does is one gap of the drag, so the two cannot drift apart — and the gap is
    /// the interesting part: **down one place is `from + 2`, not `from + 1`**, because the destination is
    /// measured against the list the row was still in. `from + 1` is the gap above the next row, where the
    /// row already is, and the platform's own `move` leaves the list alone for it.
    func testTheMenuStepsAreDrags() {
        let four = rows(4)
        for from in 0..<4 {
            for move: WorkspaceMove in [.up, .down] {
                let menu = movingWorkspace(four, cwd: "/work/\(from)", move)
                let gap = from + (move == .up ? -1 : 2)
                let drag = movingWorkspace(four, from: IndexSet(integer: from), to: gap)
                XCTAssertEqual(
                    menu.map(\.label), drag.map(\.label),
                    "\(move) at \(from) is the drag to gap \(gap)"
                )
            }
        }
        // The two moves a reader makes most, spelled out: neighbours trade places.
        XCTAssertEqual(movingWorkspace(four, cwd: "/work/1", .down).map(\.label), ["0", "2", "1", "3"])
        XCTAssertEqual(movingWorkspace(four, cwd: "/work/2", .up).map(\.label), ["0", "2", "1", "3"])
        // And the two that cannot happen, which is what the menus' disabled state promises.
        XCTAssertEqual(movingWorkspace(four, cwd: "/work/0", .up).map(\.label), ["0", "1", "2", "3"])
        XCTAssertEqual(movingWorkspace(four, cwd: "/work/3", .down).map(\.label), ["0", "1", "2", "3"])
    }

    /// The gap convention itself, measured from the platform rather than assumed: dropping a row in the gap
    /// *under its neighbour* — the gesture that means "one place down" — is `from + 2`.
    func testOnePlaceDownIsTheGapUnderTheNextRow() {
        let four = rows(4)

        XCTAssertEqual(
            movingWorkspace(four, from: IndexSet(integer: 1), to: 3).map(\.label),
            ["0", "2", "1", "3"],
            "one place down"
        )
        XCTAssertEqual(
            movingWorkspace(four, from: IndexSet(integer: 1), to: 2).map(\.label),
            ["0", "1", "2", "3"],
            "the gap above a row the row already sits in is no move"
        )
        XCTAssertEqual(
            movingWorkspace(four, from: IndexSet(integer: 0), to: 4).map(\.label),
            ["1", "2", "3", "0"],
            "the destination `count` is the end of the list"
        )
    }

    /// A drag the list cannot carry out leaves the list alone: an index it does not hold, and a destination
    /// outside the list it would be inserted into. The second is the shape the ends produce —
    /// `List.onMove` can hand over `count` — and a list that clamped it instead would move a row to the end
    /// when the reader dropped it on nothing.
    func testADragOutOfRangeChangesNothing() {
        let four = rows(4)
        let same = four.map(\.label)

        XCTAssertEqual(movingWorkspace(four, from: IndexSet(integer: 7), to: 1).map(\.label), same)
        XCTAssertEqual(movingWorkspace(four, from: IndexSet(), to: 1).map(\.label), same)
        XCTAssertEqual(movingWorkspace(four, from: IndexSet(integer: 1), to: 9).map(\.label), same)
        XCTAssertEqual(movingWorkspace([], from: IndexSet(integer: 0), to: 0).map(\.label), [])
    }
}
