import Foundation

/// How a row of pictures is cut into lines when there is not room for all of them.
///
/// Here rather than in the view for the reason `TableLayout` is: this is arithmetic, it is easy to get
/// wrong in a way that is **invisible** — a row that overflows squeezes its items to nothing rather
/// than wrapping, so the failure looks like "the pictures are missing" — and arithmetic is worth
/// testing without a window.
///
/// **One rule for two callers, and that is the real argument for it being a function at all.** A
/// SwiftUI `Layout` is asked the same question twice, in two places: `sizeThatFits` (how tall is this,
/// given this width) and `placeSubviews` (where does each one go). Two loops that must agree about how
/// many items are on each line are two loops that will disagree, and the symptom is a height that does
/// not match the thing drawn in it — content overlapping what comes after it, or a gap. One rule,
/// called by both.
public enum PictureFlow {

    /// The items on each line, as ranges into the original list.
    ///
    /// Greedy and in order: as many as fit on a line, then the next line. Never empty (an empty line
    /// is a line of blank space nobody asked for), and never zero items for a positive `count` — an
    /// item wider than the space it has still gets a line of its own, where it will be drawn at the
    /// size it was given rather than vanished.
    ///
    /// `spacing` is taken *between* items and not after the last one, so a line whose items exactly
    /// fill the width is a fit rather than an overflow by one gap.
    public static func rows(
        count: Int,
        available: CGFloat,
        item: CGFloat,
        spacing: CGFloat,
    ) -> [Range<Int>] {
        guard count > 0 else { return [] }
        // A width of zero (or less) is a view that has not been laid out yet, and one item per line is
        // the answer that stays true whatever the width later turns out to be: the lines will not need
        // recalculating, only the placement, and nothing can be squeezed out of existence in the
        // meantime.
        guard available > 0, item > 0 else {
            return (0..<count).map { $0..<($0 + 1) }
        }
        var out: [Range<Int>] = []
        var start = 0
        while start < count {
            var end = start + 1
            var used = item
            while end < count, used + spacing + item <= available {
                used += spacing + item
                end += 1
            }
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// How tall `rows` of this size come to, gaps between the lines included.
    ///
    /// The other half of the same question, and the reason it is here rather than at the `Layout`: the
    /// height has to be the sum of the lines the placement actually drew.
    public static func height(lines: Int, item: CGFloat, spacing: CGFloat) -> CGFloat {
        guard lines > 0 else { return 0 }
        return CGFloat(lines) * item + CGFloat(lines - 1) * spacing
    }
}
