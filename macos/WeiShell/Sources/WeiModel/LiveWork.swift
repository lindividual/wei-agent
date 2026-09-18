import Foundation

/// How the work of a **live** turn is drawn: one tool call at a time, and the finished ones behind a fold.
///
/// The turn's own fold (`Turn.workLabel`) is the rule for a turn that is over — a reader who opens it
/// has decided to read the working out. A turn that is still running is the other situation: the
/// reader is watching it work, and *everything* open is the version where twenty tool calls of log
/// push the answer off the bottom of the window while the reader tries to follow it. Measured, not
/// imagined: that is what "the answer is somewhere below all that" is.
///
/// So a live turn shows:
///
/// - the **newest** tool call, which is either the one running or the one that just finished — the
///   thing the reader is actually waiting on;
/// - every earlier finished call behind one fold, which says how many there are;
/// - **and nothing else is hidden**: reasoning and the prose between calls stay where they are. A
///   page that shows only the newest tool has hidden the model's own explanation of why it is calling
///   it, and that explanation is the thing a reader of an agent most often wants.
///
/// Two rules that are not obvious, both inherited from the same rule in the web UI
/// (`html/render.mbt`'s `render_work`, pinned by `html/live_fold_test.mbt`):
///
/// - the fold sits where the **first folded call** was, not at the end of the turn. A fold pushed to
///   the end puts the middle of the turn underneath the end of it;
/// - a call that has not reported is **never** folded, even when it is not the newest one. Nothing in
///   the shell runs two tools at once today, and this is the guard so that the day it does, the fold
///   cannot hide a running command.
public struct LiveWork: Equatable {
    /// One thing to draw, in order.
    public enum Item: Equatable, Identifiable {
        case row(Row)
        /// The fold, holding `LiveWork.folded`. One item however many calls it holds: the fold is
        /// one line on screen.
        case fold

        public var id: String {
            switch self {
            case let .row(row): return row.id
            // Cannot collide with a row: the shell names its rows `<kind>-<turn>-<seq>` or `note-N`.
            case .fold: return "live-fold"
            }
        }
    }

    public let items: [Item]
    /// What the fold holds, oldest first — the same rows the turn would show opened, so the two
    /// views of one turn cannot disagree about what happened.
    public let folded: [Row]

    /// What the fold says. The count is the whole point: the reader deciding whether to open it wants
    /// to know how much is in there, and "3 tool calls" is that answer in three words.
    public var label: String {
        let count = folded.count
        return count == 1 ? "1 finished tool call" : "\(count) finished tool calls"
    }
}

/// The end of a block of reasoning, for a box that shows a few lines of it.
///
/// A suffix of the text rather than its last lines, because reasoning is not written in lines — a
/// paragraph arrives as one long one — so "the last three lines" is a distinction the text does not
/// have. What the reader gets is therefore the end of it, clipped to the box; and what the view gets
/// is a bounded string rather than everything that has arrived, which is the other half of the point:
/// a block of reasoning is the one thing in a turn that reaches tens of kilobytes, and it is laid out
/// on every frame of the stream.
///
/// A rule rather than a line in the view for the reason `turns(of:)` is one: it is about what the
/// reader sees, so it is asserted without a window (`LiveWorkTests`).
public func reasoningPeek(_ text: String, characters: Int = 1200) -> String {
    guard characters > 0 else { return "" }
    return String(text.suffix(characters))
}

/// Plan a live turn's work for drawing.
///
/// A pure function over rows, like `turns(of:)`, and for the same reason: it is a rule about what the
/// reader sees, and a rule that can be asserted without a window is a rule that stays put.
public func liveWork(_ work: [Row]) -> LiveWork {
    // The newest call, wherever it is, and anything still running: both stay on screen.
    let newestTool = work.lastIndex { $0.kind == .tool }
    let foldable = work.indices.filter { index in
        work[index].kind == .tool && work[index].complete && index != newestTool
    }
    guard let firstFolded = foldable.first else {
        return LiveWork(items: work.map { .row($0) }, folded: [])
    }
    let folded = foldable.map { work[$0] }
    var items: [LiveWork.Item] = []
    for index in work.indices {
        let row = work[index]
        guard row.kind == .tool, row.complete, index != newestTool else {
            items.append(.row(row))
            continue
        }
        // The fold takes the place of the first call it holds; the rest are inside it.
        if index == firstFolded {
            items.append(.fold)
        }
    }
    return LiveWork(items: items, folded: folded)
}
