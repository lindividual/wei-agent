import XCTest

@testable import WeiModel

/// A drawing, from the side that has to draw it.
///
/// The screenshot-free half of `Sketch`: which corner a drag was started from, what a release keeps,
/// and where an arrowhead's arms land. All three are arithmetic, so they are asserted here rather
/// than looked at — a shape that came out the wrong way round is a rectangle of the wrong sign, not a
/// picture to squint at.
final class SketchTests: XCTestCase {

    // ── the rectangle a drag covers ───────────────────────────────────────

    /// A rectangle is the same rectangle whichever corner the drag started from.
    ///
    /// The four directions are four separate cases in the code that are one case here, which is the
    /// point: `CGRect` cannot hold a negative size, so the naive version works in the direction that
    /// increases and silently collapses in the other three.
    func testTheRectangleOfADragIsTheSameFromEveryCorner() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(Sketch.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60)), expected)
        XCTAssertEqual(Sketch.rect(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)), expected)
        XCTAssertEqual(Sketch.rect(from: CGPoint(x: 40, y: 20), to: CGPoint(x: 10, y: 60)), expected)
        XCTAssertEqual(Sketch.rect(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 40, y: 20)), expected)
    }

    // ── what a release keeps ──────────────────────────────────────────────

    /// A dot is a mark; a shape with no width is not.
    ///
    /// A click with the pen is a dot the reader meant to put there. A `40 × 1` rectangle is the button
    /// going down on the way to clicking somewhere else — and keeping it would be an unremovable
    /// smudge, because the finished mark does not remember that it was an accident.
    func testADotIsAMarkAndAOnePointShapeIsNot() {
        XCTAssertTrue(Sketch.isMeaningful(.freehand([CGPoint(x: 5, y: 5)])))
        XCTAssertTrue(Sketch.isMeaningful(.line(CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0))))
        XCTAssertTrue(Sketch.isMeaningful(.rectangle(CGRect(x: 0, y: 0, width: 40, height: 20))))
        XCTAssertTrue(Sketch.isMeaningful(.ellipse(CGRect(x: 0, y: 0, width: 20, height: 40))))

        XCTAssertFalse(Sketch.isMeaningful(.line(CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0))))
        XCTAssertFalse(Sketch.isMeaningful(.arrow(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 3))))
        // The flat one, in both directions: the short side is the one that says "this was a slip".
        XCTAssertFalse(Sketch.isMeaningful(.rectangle(CGRect(x: 0, y: 0, width: 40, height: 1))))
        XCTAssertFalse(Sketch.isMeaningful(.ellipse(CGRect(x: 0, y: 0, width: 1, height: 40))))
    }

    // ── a drag in progress ────────────────────────────────────────────────

    /// The pen keeps every point it was given; a shape keeps the two ends.
    func testThePenAccumulatesAndAShapeReplacesItsSecondEnd() {
        var pen = Sketch.Draft(tool: .pen, at: CGPoint(x: 0, y: 0))
        pen.drag(to: CGPoint(x: 10, y: 0))
        pen.drag(to: CGPoint(x: 20, y: 0))
        XCTAssertEqual(pen.points, [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0),
        ])
        XCTAssertEqual(pen.stroke, .freehand([
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0),
        ]))

        // A shape that wandered: the ends are the start and wherever it is *now*, so the draft is two
        // points however long the drag was — and it is the last position, not the one before it.
        var box = Sketch.Draft(tool: .rectangle, at: CGPoint(x: 0, y: 0))
        box.drag(to: CGPoint(x: 50, y: 30))
        box.drag(to: CGPoint(x: 40, y: 20))
        XCTAssertEqual(box.stroke, .rectangle(CGRect(x: 0, y: 0, width: 40, height: 20)))
    }

    /// A press and release in one place is a dot with the pen and nothing at all with a shape.
    func testADragThatGoesNowhereIsADotForThePenAndNothingElse() {
        let press = CGPoint(x: 7, y: 7)

        var dot = Sketch.Draft(tool: .pen, at: press)
        dot.drag(to: press)
        XCTAssertEqual(dot.points, [press], "an unchanged point is the same point")
        XCTAssertTrue(dot.isMeaningful)

        var box = Sketch.Draft(tool: .rectangle, at: press)
        box.drag(to: CGPoint(x: 8, y: 8))
        XCTAssertFalse(box.isMeaningful)
    }

    /// An arrow drawn back onto its own start is not an arrow.
    func testAnArrowDraggedBackOntoItsStartIsNotKept() {
        let start = CGPoint(x: 100, y: 100)
        var arrow = Sketch.Draft(tool: .arrow, at: start)
        arrow.drag(to: CGPoint(x: 200, y: 100))
        XCTAssertTrue(arrow.isMeaningful)
        arrow.drag(to: start)
        XCTAssertFalse(arrow.isMeaningful, "the two ends met, so there is no direction left to point in")
    }

    // ── the arrowhead ─────────────────────────────────────────────────────

    /// Both arms are the same length, land behind the tip, and are mirror images of each other.
    ///
    /// This is the calculation most likely to be quietly wrong, because an arm on the wrong side still
    /// *looks* like an arrowhead — it points backwards, or it opens the wrong way, and nothing about
    /// the picture says which. So the three properties are asserted as numbers.
    func testTheArrowheadIsBehindTheTipAndSymmetrical() {
        let tip = CGPoint(x: 100, y: 100)
        let start = CGPoint(x: 0, y: 100)
        let (left, right) = Sketch.barbs(from: start, to: tip)

        for arm in [left, right] {
            XCTAssertEqual(hypot(arm.x - tip.x, arm.y - tip.y), Sketch.barbLength, accuracy: 0.001)
            XCTAssertLessThan(arm.x, tip.x, "the arm is drawn behind the tip, not past it")
        }
        // Mirrored about a shaft that runs along x, so the two y values are equal and opposite and the
        // two x values are the same.
        XCTAssertEqual(left.y - tip.y, -(right.y - tip.y), accuracy: 0.001)
        XCTAssertEqual(left.x, right.x, accuracy: 0.001)
        // The arms open away from the direction of travel: the shaft is along +x, so both arms are
        // where the arrow came *from* in x, and they spread in y.
        XCTAssertGreaterThan(abs(left.y - tip.y), 0)
    }

    /// The arrowhead follows the shaft, whichever way it points.
    func testTheArrowheadTurnsWithTheShaft() {
        let tip = CGPoint(x: 50, y: 50)
        // Pointing up: the arms sit below the tip, mirrored about the vertical.
        let (left, right) = Sketch.barbs(from: CGPoint(x: 50, y: 150), to: tip)
        XCTAssertEqual(left.y, right.y, accuracy: 0.001)
        XCTAssertEqual(left.x - tip.x, -(right.x - tip.x), accuracy: 0.001)
        XCTAssertGreaterThan(left.y, tip.y)
    }

    /// A drag with no length has no direction, so the arms come back at the tip rather than at `NaN`.
    ///
    /// Reachable: the draft is drawn on every move, so a press with the arrow tool renders an arrowhead
    /// before there is a shaft. A `NaN` here is a drawn path that nothing can fix later.
    func testAZeroLengthArrowheadCollapsesOntoTheTip() {
        let tip = CGPoint(x: 12, y: 34)
        let (left, right) = Sketch.barbs(from: tip, to: tip)
        XCTAssertEqual(left, tip)
        XCTAssertEqual(right, tip)
    }
}
