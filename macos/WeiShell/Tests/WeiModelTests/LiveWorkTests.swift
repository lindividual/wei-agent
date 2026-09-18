import XCTest

@testable import WeiModel

/// A live turn's work, from the side that draws it.
///
/// The rule is `liveWork`'s, and the cases here are the ones it was written for: only the newest tool
/// call is on screen, the finished ones are behind one fold, and the reasoning and prose between them
/// are not hidden. The last two are the parts that are easy to get wrong in a way that looks like a
/// working page — a fold that swallowed the model's explanation leaves a page that shows nothing but
/// a spinner, and a fold pushed to the end of the turn puts the middle of it under the end.
final class LiveWorkTests: XCTestCase {
    private func thinking(_ text: String, _ id: String, complete: Bool = true) -> Row {
        Row(id: id, kind: .thinking, text: text, complete: complete)
    }

    private func reply(_ text: String, _ id: String, complete: Bool = true) -> Row {
        Row(id: id, kind: .reply, text: text, complete: complete)
    }

    private func tool(_ name: String, _ id: String, running: Bool = false) -> Row {
        var row = Row(id: id, kind: .tool, text: "", complete: !running)
        row.name = name
        row.output = running ? "" : "ok"
        return row
    }

    /// What got drawn, as ids — the fold as its own name, so its position in the list is asserted too.
    private func drawn(_ work: [Row]) -> [String] {
        liveWork(work).items.map { $0.id }
    }

    /// The everyday case, and the whole point: three finished calls, one line of them, and the call
    /// the reader is waiting on.
    func testOnlyTheNewestCallIsShown() {
        let plan = liveWork([tool("bash", "x1"), tool("read", "x2"), tool("bash", "x3")])
        XCTAssertEqual(plan.items.map(\.id), ["live-fold", "x3"])
        XCTAssertEqual(plan.folded.map(\.id), ["x1", "x2"])
        XCTAssertEqual(plan.label, "2 finished tool calls")
    }

    /// One call is not a fold. A disclosure standing over a single row is one more thing to read than
    /// the row itself, and a live turn spends most of its time here — one call, then the next.
    func testATurnWithOneCallFoldsNothing() {
        let plan = liveWork([tool("bash", "x1")])
        XCTAssertEqual(plan.items.map(\.id), ["x1"])
        XCTAssertTrue(plan.folded.isEmpty)
    }

    /// Nothing to fold: the rows are drawn where they are, in order.
    func testWorkWithoutToolsIsEveryRowInOrder() {
        let work = [thinking("hmm", "t1"), reply("let me look", "r1")]
        XCTAssertEqual(drawn(work), ["t1", "r1"])
        XCTAssertTrue(liveWork(work).folded.isEmpty)
    }

    /// **Reasoning and the prose between calls stay outside the fold.** A page that hides them has
    /// hidden the model saying why it is calling the tool — which is the thing a reader watching an
    /// agent most often wants to see.
    func testReasoningAndProseStayOutsideTheFold() {
        let plan = liveWork([
            thinking("the logs first", "t1"),
            tool("bash", "x1"),
            reply("nothing there, trying the config", "r1"),
            tool("read", "x2"),
        ])
        XCTAssertEqual(plan.items.map(\.id), ["t1", "live-fold", "r1", "x2"])
        XCTAssertEqual(plan.folded.map(\.id), ["x1"])
    }

    /// The fold takes the place of the first call it holds, not the last one — otherwise a call that
    /// came *before* a piece of prose ends up drawn after it, and the transcript stops being a record
    /// of what happened when.
    func testTheFoldSitsWhereTheFirstFoldedCallWas() {
        let plan = liveWork([
            tool("bash", "x1"),
            reply("that worked", "r1"),
            tool("read", "x2"),
            tool("bash", "x3"),
            reply("done", "r2"),
        ])
        XCTAssertEqual(plan.items.map(\.id), ["live-fold", "r1", "x3", "r2"])
        XCTAssertEqual(plan.folded.map(\.id), ["x1", "x2"], "the fold holds them oldest first")
    }

    /// A call that has not reported is never folded, even when it is not the newest one. Nothing runs
    /// two tools at once today; this is the guard so that folding can never hide a running command.
    func testARunningCallIsNeverFolded() {
        let plan = liveWork([tool("bash", "x1", running: true), tool("read", "x2")])
        XCTAssertEqual(plan.items.map(\.id), ["x1", "x2"])
        XCTAssertTrue(plan.folded.isEmpty)
    }

    /// The fold's own label counts, including the singular — "1 finished tool calls" is the kind of
    /// line that makes a reader stop trusting the UI.
    func testTheLabelCountsWhatItHolds() {
        XCTAssertEqual(liveWork([tool("a", "x1"), tool("b", "x2")]).label, "1 finished tool call")
        XCTAssertEqual(
            liveWork([tool("a", "x1"), tool("b", "x2"), tool("c", "x3")]).label,
            "2 finished tool calls"
        )
    }

    /// The rows the fold holds are the same rows the turn would show opened: one view of one turn,
    /// not two that can disagree about what happened.
    func testTheFoldHoldsTheRowsThemselvesNotCopiesOfTheirNames() {
        let work = [tool("bash", "x1"), tool("read", "x2"), tool("bash", "x3")]
        let plan = liveWork(work)
        XCTAssertEqual(plan.folded, Array(work.prefix(2)))
    }

    /// The peek is the **end** of the reasoning, which is the whole reason the box is anchored to its
    /// bottom: what a model is thinking now is at the end of what it has written so far.
    func testThePeekIsTheEndOfTheText() {
        XCTAssertEqual(reasoningPeek("one two three", characters: 5), "three")
    }

    /// Short reasoning is not padded or truncated into three lines: the box shows what there is.
    func testAShortBlockIsPeekedWhole() {
        XCTAssertEqual(reasoningPeek("short", characters: 100), "short")
        XCTAssertEqual(reasoningPeek("", characters: 100), "")
    }

    /// What crosses to the view is bounded, which is the point of the slice rather than the whole
    /// text: a block that reached forty kilobytes would otherwise be laid out on every frame.
    func testThePeekIsBounded() {
        let long = String(repeating: "x", count: 50_000)
        XCTAssertEqual(reasoningPeek(long).count, 1200)
        XCTAssertEqual(reasoningPeek(long, characters: 10).count, 10)
    }

    /// The one number the view owns is how many lines the box shows; a slice of zero characters is a
    /// box that cannot be filled, and it is answered rather than crashed.
    func testAPeekOfNothingIsEmpty() {
        XCTAssertEqual(reasoningPeek("anything", characters: 0), "")
    }
}
