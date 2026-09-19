import XCTest

@testable import WeiModel

/// How a row of pictures is cut into lines.
///
/// The failure this exists to prevent is silent: a row that overflows does not wrap, it squeezes — so
/// the reader's own screenshot shrinks to nothing with no error and nothing to click. The other half is
/// that the height and the placement have to agree, which is why the two are one function.
final class PictureFlowTests: XCTestCase {
    /// A thumbnail is 64 and the gap 6, which is what the view draws with.
    private let item: CGFloat = 64
    private let gap: CGFloat = 6

    /// Ten fit on a line of the widest column; eleven do not.
    ///
    /// Ten is 640 + 54 = 694 of 740. Eleven is 704 + 60 = 764, which is past it — and the eleventh goes
    /// on its own line rather than being squeezed in beside the others.
    func testAsManyAsFitGoOnTheFirstLine() {
        XCTAssertEqual(
            PictureFlow.rows(count: 10, available: 740, item: item, spacing: gap),
            [0..<10]
        )
        XCTAssertEqual(
            PictureFlow.rows(count: 11, available: 740, item: item, spacing: gap),
            [0..<10, 10..<11]
        )
    }

    /// A line that exactly fills the width is a fit — the gap is *between* items, not after the last.
    func testALineThatExactlyFillsTheWidthIsAFit() {
        // Three items and two gaps: 3 × 64 + 2 × 6 = 204.
        let rows = PictureFlow.rows(count: 3, available: 204, item: item, spacing: gap)
        XCTAssertEqual(rows, [0..<3])
        XCTAssertEqual(
            PictureFlow.rows(count: 3, available: 203, item: item, spacing: gap),
            [0..<2, 2..<3]
        )
    }

    /// Past the width, the rest goes on the next line — in order, with nothing dropped.
    func testMoreThanFitWrap() {
        let rows = PictureFlow.rows(count: 25, available: 740, item: item, spacing: gap)
        XCTAssertEqual(rows, [0..<10, 10..<20, 20..<25])
        // Every item is on exactly one line, in order: a wrapping rule that loses one is a picture
        // that is not drawn.
        XCTAssertEqual(rows.flatMap { Array($0) }, Array(0..<25))
    }

    /// No pictures is no lines, and no height.
    func testNoPicturesIsNoLines() {
        XCTAssertEqual(PictureFlow.rows(count: 0, available: 740, item: item, spacing: gap), [])
        XCTAssertEqual(PictureFlow.height(lines: 0, item: item, spacing: gap), 0)
    }

    /// The height is the lines plus the gaps between them, and it is what the `Layout` reports — a
    /// height that disagrees with the placement is content drawn on top of the next row.
    func testTheHeightIsTheLinesItDrew() {
        XCTAssertEqual(PictureFlow.height(lines: 1, item: 64, spacing: 6), 64)
        XCTAssertEqual(PictureFlow.height(lines: 3, item: 64, spacing: 6), 64 * 3 + 6 * 2)
    }

    /// **A width of zero still answers.** A view is measured before it has a width (the first proposal
    /// of a fresh layout pass is often `0`), and the answer has to be a list of lines all the same size
    /// as the items: nothing may be squeezed out of existence in the meantime, and the lines do not have
    /// to be recomputed when the real width arrives — only their placement.
    func testNoWidthYetStillGivesEveryPictureALine() {
        let rows = PictureFlow.rows(count: 4, available: 0, item: item, spacing: gap)
        XCTAssertEqual(rows, [0..<1, 1..<2, 2..<3, 3..<4])
        XCTAssertEqual(rows.flatMap { Array($0) }.count, 4)
    }

    /// A thumbnail wider than the space it is in gets its own line rather than disappearing: it will be
    /// clipped by whatever constrains it, which is visible, instead of being squeezed to nothing.
    func testAnItemWiderThanTheSpaceStillGetsALine() {
        XCTAssertEqual(
            PictureFlow.rows(count: 2, available: 40, item: item, spacing: gap),
            [0..<1, 1..<2]
        )
    }
}
