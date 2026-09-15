import Foundation

/// One turn of a conversation: what was asked, the work that went into it, the answer, and the figures.
///
/// This is the host's version of the web UI's *exchange*, and it is here — in `PiModel`, tested — because it
/// is a rule rather than a fact about the wire: the transcript arrives as a flat list of rows, and a turn is
/// the shape a reader sees in it.
///
/// The rule, taken from `html/render.mbt`'s `render_exchange` so that the two front ends agree:
///
/// - the **answer** is the *last* text the model wrote in the turn. Not the first, not all of them: a turn is
///   not shaped like one answer — it writes something, calls a tool, writes again — and the last thing it
///   wrote is the one it wants read;
/// - everything else is **work** — reasoning, tool calls, and the intermediate replies — and it folds;
/// - the **figures** are the line the turn ends with.
///
/// The one distortion the web UI admits to and this inherits: a turn that ended in a tool call rather than in
/// prose — a round limit, or a stop — has no answer to point at, so the last thing said before the
/// interruption is shown in its place. That is better than showing nothing, and it is not a claim that the
/// turn finished.
public struct Turn: Identifiable, Equatable {
    /// Stable across redraws: the question's own row id, so a fold that is open stays open.
    public let id: String
    /// What the reader asked, if it is in the transcript. Absent for rows that arrived before any question —
    /// a resumed session whose first rows are the tail of a turn.
    public let question: Row?
    /// Reasoning, tool rows, and any replies that were not the last one.
    public let work: [Row]
    /// The last text of the turn, which is the part to read.
    public let answer: Row?
    /// The turn's figures as the shell wrote them ("3 model calls · 2 tool calls · $0.01"), when the turn has
    /// ended. `nil` for a turn still running, and for one replayed from a log the shell did not price.
    public let figures: String?

    /// Whether there is anything to fold. A turn that was one answer would otherwise open with a fold
    /// standing between the reader and the thing they came for.
    public var hasWork: Bool { !work.isEmpty }

    /// What the fold says: the web UI's label, with its own fallback — "what it did" when there are no figures
    /// to count, which is the case for a replayed session.
    public var workLabel: String {
        // The figures line is "3 model calls · 2 tool calls · $0.01"; the label wants the first two, and
        // nothing about money. Parsed rather than carried separately because the line is already the shell's
        // own sentence and a second field would be a second thing to keep in step.
        let parts = (figures ?? "").split(separator: "·").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.hasPrefix("$") }
        guard !parts.isEmpty else { return "What it did" }
        return "Worked through " + parts.joined(separator: ", ")
    }
}

/// Group a flat transcript into turns.
///
/// A `user` row starts one. Rows before the first question belong to a turn of their own with no question,
/// which is what a transcript that begins mid-turn looks like — a resumed session, or a log whose first
/// entries were compacted away.
public func turns(of rows: [Row]) -> [Turn] {
    var out: [Turn] = []
    var question: Row?
    var body: [Row] = []
    var figures: String?
    var index = 0

    func flush() {
        guard question != nil || !body.isEmpty || figures != nil else { return }
        // The answer is the last reply in the turn, and everything else is work **in the order it happened**.
        // Found by index rather than by appending as we go: the first version pushed each superseded reply onto
        // the end of the work list, which put an answer that came *before* a tool call after it. The transcript's
        // order is the reader's only record of what happened when, and a fold is no reason to lose it.
        let answerAt = body.lastIndex { $0.kind == .reply }
        let work = body.enumerated().compactMap { index, row in
            index == answerAt ? nil : row
        }
        let answer = answerAt.map { body[$0] }
        out.append(
            Turn(
                id: question?.id ?? "turn-\(index)",
                question: question,
                work: work,
                answer: answer,
                figures: figures
            )
        )
        index += 1
    }

    for row in rows {
        switch row.kind {
        case .user:
            flush()
            question = row
            body = []
            figures = nil
        case .note:
            // A labelled note is a compaction: it is part of what happened, so it folds with the work. An
            // unlabelled one is the turn's own figures — the line the shell ends a turn with.
            if row.name.isEmpty {
                figures = row.text
            } else {
                body.append(row)
            }
        default:
            body.append(row)
        }
    }
    flush()
    return out
}
