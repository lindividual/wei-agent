import Foundation

/// The project column's own rules: how much of the list is on screen, and the order the reader has put it
/// in — whether they dragged a row or asked the toolbar to move the project it is listing.
///
/// All of it is *this window's* fact rather than the store's. The store has no order to ask for — it
/// sorts by "most recently written first", which `stableSidebarOrder` then holds still (see
/// `Sidebar.swift`) — and no idea of how much of it a reader wants to see at once. So it lives here, as
/// arithmetic, and the view is only the thing that draws the answer.

/// How many projects the column lists before it folds the rest away.
///
/// **Five, because this column is short and two live sections sit under it.** The projects are what the
/// reader aims at; a column of twenty of them is a wall that pushes the register — the running sessions
/// and the running tool calls — below the fold, and "is anything running" then costs a scroll. Five
/// leaves room for both sections and for the reader's own window.
public let workspaceFoldLimit = 5

/// The projects the column draws, and how large the fold is.
///
/// `hidden` is what is *behind* the fold, whether or not it is open: that is what lets the fold row say
/// how many it is covering while folded and still be the row that folds them back. Zero means there is
/// no fold — the list fits, which is the common case for a reader with a few projects — and the caller
/// draws no row at all rather than a control over nothing.
public func workspaceColumn(
    _ groups: [SessionGroup],
    expanded: Bool
) -> (shown: [SessionGroup], hidden: Int) {
    let hidden = groups.count - workspaceFoldLimit
    guard hidden > 0 else { return (groups, 0) }
    return expanded ? (groups, hidden) : (Array(groups.prefix(workspaceFoldLimit)), hidden)
}

/// What the fold row says.
///
/// The count is the point of the folded label: "Show More" over a list the reader cannot count tells
/// them a row goes somewhere without telling them whether what they are looking for is behind it. The
/// open label drops it: there is nothing left to count, and the number would only repeat the list they
/// are already reading.
public func workspaceFoldLabel(hidden: Int, expanded: Bool) -> String {
    expanded ? "Show Less" : "Show \(hidden) More"
}

/// Whether the fold is hiding this project — the list holds it, and it is not among the rows drawn.
///
/// The case this exists for is the reader *arriving* somewhere behind the fold: clicking a search result
/// in another project, or `⌃⇥` opening a session in one. The middle column follows them and lists that
/// project's sessions, so the column they left would otherwise be the only one that says nothing about
/// where they are — the mark on a project row is the whole reason the row carries a dot (`WorkspaceRow`).
///
/// Asked through `workspaceColumn` rather than by comparing against `workspaceFoldLimit` a second time, so
/// the rows the fold draws and the answer here cannot drift apart.
///
/// Also false for a project the list does not hold — a store that has not listed a folder the reader just
/// added. There is no row for it to be behind yet, and a mark over a fold that does not contain what it
/// claims would be worse than no mark.
public func workspaceIsBehindFold(_ groups: [SessionGroup], cwd: String, expanded: Bool) -> Bool {
    guard !cwd.isEmpty, groups.contains(where: { $0.cwd == cwd }) else { return false }
    return !workspaceColumn(groups, expanded: expanded).shown.contains { $0.cwd == cwd }
}

/// Which way a project moves: the two items in the column's toolbar menu, and nothing else — there is no
/// "move to top", and an `Int` that means "one place" for any non-zero value is the kind of parameter that
/// quietly ignores what it was handed.
public enum WorkspaceMove {
    /// Toward the top of the column.
    case up
    /// Toward the bottom.
    case down
}

/// Whether moving this project would move it at all.
///
/// The toolbar menu's enabled state is drawn from this, and `movingWorkspace` refuses the same moves, so an
/// item that cannot act and the move that follows it cannot disagree. An item that is there and does
/// nothing is worse than an item that is not there.
///
/// Asked of the whole list rather than of the drawn rows, unlike the drag: this is a command about a
/// project, and one behind the fold still has somewhere to go.
public func canMoveWorkspace(_ groups: [SessionGroup], cwd: String, _ move: WorkspaceMove) -> Bool {
    workspaceMoveTarget(groups, cwd: cwd, move) != nil
}

/// The order after the reader drags rows: `source` was lifted out and dropped at `destination`.
///
/// **`destination` is a gap in the list as it was *before* the rows were lifted**: the index of the row the
/// lifted ones are to be inserted *before*, with `count` meaning "at the end". So one place down from row
/// `i` is `i + 2`, not `i + 1` — the gap under a row counts that row itself, because the row is still in the
/// list the gap was measured against. (`i + 1` is the gap *above* row `i + 1`, where the row already is,
/// so it is no move at all.) That is the convention `List.onMove` hands over, and it is the platform's own
/// `move(fromOffsets:toOffset:)` behaviour, measured rather than assumed — `WorkspaceMoveTests` in
/// `WeiShellTests` walks a matrix through both and asserts they agree.
///
/// A drag out of range, or of an index the list does not hold, changes nothing: a drop the list cannot
/// carry out must not be able to scramble the list it could not carry it out in.
public func movingWorkspace(
    _ groups: [SessionGroup],
    from source: IndexSet,
    to destination: Int
) -> [SessionGroup] {
    guard !source.isEmpty,
          source.allSatisfy({ groups.indices.contains($0) }),
          (0...groups.count).contains(destination)
    else { return groups }
    let lifted = source.sorted()
    var out = groups
    let moved = lifted.map { groups[$0] }
    // Descending, because every removal shifts the ones above it.
    for index in lifted.reversed() { out.remove(at: index) }
    let insertion = destination - lifted.filter { $0 < destination }.count
    out.insert(contentsOf: moved, at: min(max(insertion, 0), out.count))
    return out
}

/// The order after the reader moves one project, from the column's own `Move Up` / `Move Down`.
///
/// `groups` comes back untouched when the move has nowhere to go, which is the last project asked to go
/// down or the first asked to go up: no clamping to the ends, because a move the reader asked for and
/// the list ignored is a control that lied about what it did.
///
/// One place, expressed the way the drag expresses it — up is the gap `from − 1`, down is the gap
/// `from + 2` (see the note above) — so the menu and the drag ask one question and cannot drift into two
/// answers. The off-by-one that mapping needs is not hidden in a guard: it is written once, here, next to
/// the sentence that explains it, and a test drags the equivalent gap and compares.
public func movingWorkspace(
    _ groups: [SessionGroup],
    cwd: String,
    _ move: WorkspaceMove
) -> [SessionGroup] {
    guard let from = groups.firstIndex(where: { $0.cwd == cwd }) else { return groups }
    return movingWorkspace(
        groups, from: IndexSet(integer: from), to: from + (move == .up ? -1 : 2)
    )
}

/// Where a move lands, or `nil` when it is not a move: no such project, or the end of the list.
private func workspaceMoveTarget(
    _ groups: [SessionGroup],
    cwd: String,
    _ move: WorkspaceMove
) -> Int? {
    guard let from = groups.firstIndex(where: { $0.cwd == cwd }) else { return nil }
    let target = from + (move == .up ? -1 : 1)
    return groups.indices.contains(target) ? target : nil
}
