import XCTest

@testable import WeiModel

/// A markdown table's shape, from the side that has to draw it.
///
/// The parse is pinned in `md/json_test.mbt` and by `SidebarTests`; what is pinned here is the step the
/// screenshot found — turning a ragged parse into a grid whose columns are vertical lines.
///
/// `measure` is injected rather than real font metrics, because the properties worth asserting are
/// arithmetic: the widest cell wins, the clamps hold, every row ends up the same length. A test that
/// measured real text would be asserting a font's numbers instead.
final class TableLayoutTests: XCTestCase {
    /// A deterministic stand-in for measuring: ten points a character, one per span.
    private func measure(_ spans: [Block.Span]) -> CGFloat {
        CGFloat(spans.reduce(0) { total, span in
            switch span {
            case let .text(text), let .code(text): return total + text.count
            case let .emph(inner), let .strong(inner), let .strike(inner): return total + inner.count
            case let .link(_, inner): return total + inner.count
            // A picture in a cell measures as wide as the word that stands in for it: what a table
            // cell ends up drawing is that word, so that is the width the column is laid out for.
            case let .image(_, alt): return total + alt.count
            }
        }) * 10
    }

    private func layout(
        header: [[Block.Span]],
        rows: [[[Block.Span]]],
        align: [Block.Align] = []
    ) -> TableLayout {
        tableLayout(
            header: header, rows: rows, align: align,
            padding: 10, minimum: 60, maximum: 300, measure: measure
        )
    }

    private func text(_ value: String) -> [Block.Span] { [.text(value)] }

    /// The property that makes a table a table: one width per column, shared by every row.
    func testAColumnIsAsWideAsItsWidestCell() {
        let laid = layout(
            header: [text("a"), text("header")],
            rows: [[text("a long cell here"), text("x")]]
        )
        // 16 characters → 160, plus 10 padding each side.
        XCTAssertEqual(laid.widths[0], 180)
        // "header" is 6 → 60, plus padding.
        XCTAssertEqual(laid.widths[1], 80)
    }

    /// The bug a screenshot found, as arithmetic: a row laid out on its own has no idea how wide the
    /// other rows made a column, so the rules land in different places.
    func testEveryRowIsDrawnAtTheSameColumnWidths() {
        let laid = layout(
            header: [text("h"), text("h")],
            rows: [[text("much longer"), text("b")], [[], text("b")]]
        )
        // The header's own cells are narrow, and the widths are not: they came from the rows below.
        XCTAssertEqual(laid.widths[0], 130)
        XCTAssertEqual(laid.widths.count, laid.columns)
        XCTAssertEqual(laid.header.count, laid.columns)
        XCTAssertTrue(laid.rows.allSatisfy { $0.count == laid.columns })
    }

    /// A ragged row is padded with empty cells rather than left short: a missing rule in the middle of a
    /// column is a column that looks like a merged cell in that row.
    func testARaggedRowIsPaddedToTheNumberOfColumns() {
        let laid = layout(
            header: [text("a"), text("b"), text("c")],
            rows: [[text("1")], [text("1"), text("2")], [text("1"), text("2"), text("3")]]
        )
        XCTAssertEqual(laid.columns, 3)
        XCTAssertEqual(laid.rows.map(\.count), [3, 3, 3])
        XCTAssertEqual(laid.rows[0][1], [])
        XCTAssertEqual(laid.rows[0][2], [])
    }

    /// The column count is the widest row's, not the header's. `cmark` never produces this, but a table
    /// typed by hand or pasted from somewhere else can have a stray `|`, and the alternative — dropping
    /// the cell — silently loses what someone wrote. Past the last column there is no column to draw it
    /// in, so it is dropped rather than given one of its own.
    func testAStrayCellWidensTheTableAndOnePastTheEndIsDropped() {
        let laid = layout(
            header: [text("a"), text("b"), text("c")],
            rows: [[text("1"), text("2"), text("3"), text("4")]]
        )
        XCTAssertEqual(laid.columns, 4)
        XCTAssertEqual(laid.rows[0].count, 4)
        XCTAssertEqual(laid.align.count, 4, "a widened table has no alignment for its new column")
        XCTAssertEqual(laid.rows[0][3], text("4"))
    }

    /// The floor and the ceiling, both of which exist so that the table stays readable: a one-character
    /// column is still a column, and one long cell does not push the table off the screen.
    func testAColumnIsClampedAtBothEnds() {
        let laid = layout(
            header: [text("x"), text("this cell is far too long to fit in a column of a table")],
            rows: []
        )
        XCTAssertEqual(laid.widths[0], 60, "a narrow column was not held at the floor")
        XCTAssertEqual(laid.widths[1], 300, "a long column was not held at the ceiling")
    }

    /// A source that names fewer alignments than it has columns — written by hand, or by a model —
    /// reads as left, and one alignment per column always comes back so the view never indexes past the
    /// end of the list.
    func testAlignmentIsOnePerColumn() {
        let laid = layout(
            header: [text("a"), text("b"), text("c")],
            rows: [[text("1"), text("2"), text("3")]],
            align: [.right]
        )
        XCTAssertEqual(laid.align, [.right, .left, .left])
    }

    /// Nothing to draw is not a crash, and not a table with a phantom column either.
    func testAnEmptyTableIsEmpty() {
        let laid = layout(header: [], rows: [])
        XCTAssertEqual(laid.columns, 0)
        XCTAssertTrue(laid.widths.isEmpty)
        XCTAssertTrue(laid.header.isEmpty)
    }

    /// The header counts towards the width, which is not a detail: a header wider than every data cell
    /// used to overflow its column, because the header was drawn as its own row with its own widths.
    func testTheHeaderIsMeasuredToo() {
        let laid = layout(
            header: [text("a very long header"), text("h")],
            rows: [[text("1"), text("2")]]
        )
        // 18 characters at ten points each, plus ten points of padding on both sides.
        XCTAssertEqual(laid.widths[0], 200)
    }

    // ── the memo ───────────────────────────────────────────────────────────
    //
    // A table's layout is a measurement per cell and the view asks for it from its `body`, which is
    // re-evaluated on every frame of a block that is still arriving. The memo is what keeps an
    // unchanged table from being measured again on each of those frames, so what is asserted here is
    // the *count* of measurements rather than the widths — the widths are asserted everywhere above.

    /// The case the memo exists for: the same table, laid out again, measures nothing the second time.
    func testTheSameTableIsOnlyMeasuredOnce() {
        let memo = TableMemo()
        var calls = 0
        let measure: CellMeasure = { spans in
            calls += 1
            return CGFloat(spans.count) * 10
        }
        let args = (padding: 10, minimum: 60, maximum: 300) as (CGFloat, CGFloat, CGFloat)
        _ = memo.layout(
            header: [text("a"), text("b")],
            rows: [[text("1"), text("2")]],
            align: [],
            padding: args.0, minimum: args.1, maximum: args.2, measure: measure
        )
        let first = calls
        XCTAssertGreaterThan(first, 0, "the first layout has to measure something")
        let again = memo.layout(
            header: [text("a"), text("b")],
            rows: [[text("1"), text("2")]],
            align: [],
            padding: args.0, minimum: args.1, maximum: args.2, measure: measure
        )
        XCTAssertEqual(calls, first, "the second layout of the same table measures nothing")
        XCTAssertEqual(again.widths.count, 2)
        XCTAssertEqual(memo.computed, 1)
    }

    /// A changed table is a new layout — the memo is a memo, not a cache of the first thing it saw.
    func testAChangedTableIsLaidOutAgain() {
        let memo = TableMemo()
        let measure: CellMeasure = { spans in CGFloat(spans.count) * 10 }
        let first = memo.layout(
            header: [text("a")], rows: [[text("1")]], align: [],
            padding: 10, minimum: 60, maximum: 300, measure: measure
        )
        let grown = memo.layout(
            header: [text("a")], rows: [[text("1")], [text("2")]], align: [],
            padding: 10, minimum: 60, maximum: 300, measure: measure
        )
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertEqual(grown.rows.count, 2, "the new row is in the layout")
        XCTAssertEqual(memo.computed, 2)
        // And the alignment counts as content: a table whose columns changed alignment is re-laid out,
        // because the alignment is what the view draws the cells against.
        _ = memo.layout(
            header: [text("a")], rows: [[text("1")], [text("2")]], align: [.right],
            padding: 10, minimum: 60, maximum: 300, measure: measure
        )
        XCTAssertEqual(memo.computed, 3)
    }
}
