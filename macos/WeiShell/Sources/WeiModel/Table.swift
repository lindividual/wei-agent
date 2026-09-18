import CoreGraphics
import Foundation

/// A markdown table, made rectangular and given a width per column.
///
/// The parse hands over what the author wrote, which is ragged: a row may have fewer cells than the
/// header, and a cell may be missing at the end. A *grid* cannot be ragged — the whole point of one is
/// that a column is a vertical line — so the shape is fixed up here, once, and the view draws cells it
/// can rely on the shape of.
///
/// This is here rather than in the view for the reason `WeiModel` exists: it is arithmetic on values, so
/// it can be tested without a window. It was a view concern until a screenshot showed what the view was
/// doing — every row laid out on its own, so the vertical rules landed at a different x on every row and
/// a short cell collapsed to nothing. Nothing in the parse was wrong, which is why no test caught it.
public struct TableLayout: Equatable {
    /// How many cells every row has.
    public let columns: Int
    public let header: [[Span]]
    public let rows: [[[Span]]]
    /// The width of each column, padding included. Every cell in a column is drawn at this width, which
    /// is the only reason the rules line up.
    public let widths: [CGFloat]
    /// One per column, filled in from the parse and defaulted to `.left` where the source named fewer
    /// alignments than the table has columns.
    public let align: [Align]

    public typealias Span = Block.Span
    public typealias Align = Block.Align
}

/// Measure one cell's text.
///
/// Injected so that the arithmetic below can be tested without a font: a test passes a function that
/// returns the character count, and the properties that matter — the widest cell wins, the clamps hold,
/// the rows come out rectangular — are asserted exactly.
public typealias CellMeasure = ([TableLayout.Span]) -> CGFloat

/// Lay a parsed table out: rectangular, with a width per column.
///
/// - Parameters:
///   - padding: horizontal padding *inside* a cell. Included in `widths`, so the view adds none of its
///     own and two cells in a column cannot disagree about their outer width.
///   - minimum: a floor, so a column of one-character cells is still a column.
///   - maximum: a ceiling, so one long cell does not push the rest of the table off the screen. A cell
///     wider than this wraps rather than widening its column further.
public func tableLayout(
    header: [[TableLayout.Span]],
    rows: [[[TableLayout.Span]]],
    align: [TableLayout.Align],
    padding: CGFloat,
    minimum: CGFloat,
    maximum: CGFloat,
    measure: CellMeasure
) -> TableLayout {
    let columns = max(header.count, rows.map(\.count).max() ?? 0)
    guard columns > 0 else {
        return TableLayout(columns: 0, header: [], rows: [], widths: [], align: [])
    }

    // Widest cell per column, over the header and every row alike — the header is a row, and a column
    // that sized itself to the data while the header overflowed would be the same bug in a new place.
    var widths = [CGFloat](repeating: 0, count: columns)
    for row in [header] + rows {
        for (index, cell) in row.enumerated() {
            widths[index] = max(widths[index], measure(cell))
        }
    }

    // Padding is part of the column's width rather than something the view adds, so a cell's box and its
    // column's width are the same number and nothing has to be kept in step.
    widths = widths.map { min(max($0 + padding * 2, minimum), maximum) }

    return TableLayout(
        columns: columns,
        header: rectangle(header, to: columns),
        rows: rows.map { rectangle($0, to: columns) },
        widths: widths,
        // The parse may name fewer alignments than there are columns (a hand-written table), and more
        // cells than it names columns (a row with a stray `|`). Both are answered here rather than by a
        // default in the view, so that "which column is which" has one answer.
        align: (0..<columns).map { $0 < align.count ? align[$0] : .left }
    )
}

/// Pad a row out to `columns` cells, and drop any beyond it.
///
/// A missing cell is drawn as an empty one rather than skipped: a row whose rules were omitted where it
/// ran short would be the one row in the table with no vertical line at that column, which reads as a
/// merged cell.
private func rectangle(_ row: [[TableLayout.Span]], to columns: Int) -> [[TableLayout.Span]] {
    var out = Array(row.prefix(columns))
    while out.count < columns {
        out.append([])
    }
    return out
}

/// One table's layout, kept until the table changes.
///
/// A table's layout is a text **measurement per cell**, and the view asks for it from its own `body` —
/// which is re-evaluated whenever anything in the transcript changes, including every frame of a block
/// that is still arriving. Measured on this machine, a 150-cell table costs about 1.2ms to lay out; a
/// live answer carrying a table would pay that several times a second, on the main thread, for a table
/// that had not changed at all.
///
/// One entry rather than a map, because the workload is "the same table again": each table on screen
/// has its own cache, and a table's own content changes by rewriting it, not by accumulating keys. The
/// comparison is `Equatable` on the parse the host already holds — no strings built, no hashing — and
/// it is a fraction of the measurement it replaces.
///
/// Deliberately **not** an `ObservableObject`: nothing here is state a view redraws on. It is a
/// memo of work already done, held in the view's own storage.
public final class TableMemo {
    private var header: [[Block.Span]]?
    private var rows: [[[Block.Span]]]?
    private var align: [Block.Align]?
    private var laid: TableLayout?
    /// How many times a layout was actually computed. For tests: a cache whose hit rate cannot be
    /// observed is a cache nobody can assert anything about.
    public private(set) var computed = 0

    public init() {}

    public func layout(
        header: [[Block.Span]],
        rows: [[[Block.Span]]],
        align: [Block.Align],
        padding: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        measure: CellMeasure
    ) -> TableLayout {
        if let laid, self.header == header, self.rows == rows, self.align == align {
            return laid
        }
        let fresh = tableLayout(
            header: header,
            rows: rows,
            align: align,
            padding: padding,
            minimum: minimum,
            maximum: maximum,
            measure: measure
        )
        self.header = header
        self.rows = rows
        self.align = align
        laid = fresh
        computed += 1
        return fresh
    }
}
