import CoreGraphics
import Foundation

/// A drawing, as the marks it is made of.
///
/// Here rather than beside the view, for the reason `TableLayout` is: the parts of a drawing that can
/// be *wrong* are arithmetic on numbers, and arithmetic is worth testing without a window. Which corner
/// a drag started from, whether a two-point drag was a shape or a slip of the hand, where an
/// arrowhead's two arms land — all three are answered here, and `SketchTests` answers them again.
///
/// What is deliberately **not** here: the paper, the ink, and the glyphs on the tools. A picture is
/// pixels, and pixels are drawing; this is what a drawing *is*. The two halves meet at `Stroke`, which
/// is the only thing the view's `Canvas` and the PNG it exports both read — so the picture that gets
/// sent cannot be a second rendering that disagrees with the one on screen.
public enum Sketch {

    // ── the tools ─────────────────────────────────────────────────────────

    /// What a drag with the pointer draws.
    ///
    /// One enumeration rather than a case per tool kind, because every tool's whole life is the same
    /// three moments — press, drag, release — and the only difference is what the two ends become.
    public enum Tool: String, CaseIterable, Identifiable, Sendable {
        /// Freehand: every point the pointer passed through.
        case pen
        /// A straight line, from where the drag started to where it ended.
        case line
        /// A line with an arrowhead at the end that was dragged to, for "this leads to that".
        case arrow
        /// An outline, however it was dragged.
        case rectangle
        /// An outline of an ellipse inscribed in the drag.
        case ellipse

        public var id: String { rawValue }
    }

    // ── the ink ───────────────────────────────────────────────────────────

    /// The width of the ink, in points. Fixed rather than a choice: a picture the model is shown wants
    /// one weight that is always legible, not a slider nobody can judge at a glance.
    public static let ink: CGFloat = 2.5

    /// The smallest drag that is a mark rather than a slip of the hand.
    ///
    /// A click with the pen is a dot, which is a mark; a *rectangle* one point wide is not a rectangle,
    /// it is the button being pressed on the way to clicking somewhere else — and it would be an
    /// unremovable smudge on the paper, since nothing here tells a deliberate 40×1 rectangle from that.
    public static let minimumShape: CGFloat = 4

    /// How long each arm of an arrowhead is, and how far it is turned off the shaft.
    public static let barbLength: CGFloat = 11
    public static let barbAngle: Double = .pi / 7

    // ── the marks ─────────────────────────────────────────────────────────

    /// One mark on the paper, in the paper's own coordinates.
    public enum Stroke: Equatable, Sendable {
        case freehand([CGPoint])
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
    }

    /// The rectangle a drag covers, whichever corner it started from and whichever way it went.
    ///
    /// Normalised here because `CGRect` refuses a negative size rather than storing one: building it
    /// from `(to.x - from.x, to.y - from.y)` works for one quadrant of eight and silently gives a zero
    /// rectangle for the rest, which is a shape the reader drew and cannot see.
    public static func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        )
    }

    /// Whether a finished drag should be kept.
    public static func isMeaningful(_ stroke: Stroke) -> Bool {
        switch stroke {
        case .freehand:
            // Including a single point: a click with the pen is a dot, and a dot is a mark.
            return true
        case let .line(from, to), let .arrow(from, to):
            return distance(from, to) >= minimumShape
        case let .rectangle(rect), let .ellipse(rect):
            // Both sides, not the diagonal: a wide flat rectangle is not a thin rectangle, it is a drag
            // that went sideways before the reader meant to start drawing.
            return min(rect.width, rect.height) >= minimumShape
        }
    }

    /// The two far ends of the arrowhead for an arrow that ends at `to`.
    ///
    /// Returned as points rather than as an angle, because the arrow is drawn as a path and a path
    /// wants points. A drag of zero length has no direction to point in, so both arms come back at the
    /// tip — not a rotation by an undefined angle, which is a NaN that spreads into the drawn path.
    public static func barbs(from: CGPoint, to: CGPoint) -> (CGPoint, CGPoint) {
        let back = distance(from, to)
        guard back > 0 else { return (to, to) }
        // The shaft, reversed and normalised: the direction each arm leaves the tip in, before it is
        // turned off by `barbAngle` in either direction.
        let ux = (from.x - to.x) / back
        let uy = (from.y - to.y) / back
        let cos = CGFloat(cos(barbAngle))
        let sin = CGFloat(sin(barbAngle))
        let left = CGPoint(
            x: to.x + barbLength * (ux * cos - uy * sin),
            y: to.y + barbLength * (ux * sin + uy * cos)
        )
        let right = CGPoint(
            x: to.x + barbLength * (ux * cos + uy * sin),
            y: to.y + barbLength * (-ux * sin + uy * cos)
        )
        return (left, right)
    }

    // ── the paper ─────────────────────────────────────────────────────────

    /// A sheet of paper: how big it is in the sheet, and how many pixels that is worth.
    ///
    /// Two numbers rather than one, because they are two different questions and neither answers the
    /// other. The **points** are the coordinate space every mark is made in and the size the sheet
    /// takes of the window; the **scale** is pixels per point on the way out. A sheet drawn at 2× is
    /// the same picture on screen as one drawn at 1× and twice the file underneath.
    ///
    /// The blank sketch is a constant on both axes (640×420 at 2×) and that is not a coincidence to
    /// preserve — but a **screenshot is not**, which is why this is a type. The system's capture
    /// arrives with its own size and its own resolution (a 2× display's full screen is 1470×956 points
    /// and 2940×1912 pixels), and the paper that shows it has to be right about *both*: the reader has
    /// to see the whole picture, and the model has to be handed the picture that was taken. The rule
    /// that makes those two agree is `fitting` below.
    public struct Paper: Equatable, Sendable {
        public let size: CGSize
        public let scale: CGFloat

        public init(size: CGSize, scale: CGFloat) {
            self.size = size
            self.scale = scale
        }

        /// What the drawn picture is worth, in pixels.
        public var pixels: CGSize {
            CGSize(width: size.width * scale, height: size.height * scale)
        }

        /// The paper for a picture of `pixels` that is `points` big, no bigger than `limit` points.
        ///
        /// The shape is kept, the picture is **not enlarged**, and what does not fit is shrunk to fit
        /// — those three are the whole rule. A 200-pixel-wide capture blown up to fill the sheet would
        /// be a blur of itself, and the reader would be marking up something the model will never see:
        /// a picture smaller than the limit therefore keeps its own size, and its export stays 1:1.
        ///
        /// `scale` is then whatever makes the export the picture's own pixels — **not the window's or
        /// the screen's idea of a scale.** That is the point of taking `points` and `pixels` as two
        /// separate answers: a shrunk sheet renders at a *larger* scale than the screen it came from,
        /// which is what puts 2940×1912 in the file instead of the 1360×880 a 680-point sheet at the
        /// screen's own 2× would hold. The resample on the way is one the renderer does at whatever
        /// ratio `points` and `pixels` imply, and no rule here has to know what it is.
        ///
        /// Both inputs come from outside this file and neither is checkable here — one is what a decoder
        /// reports for the picture's own resolution, the other what it reports for its size — so both are
        /// floored at a pixel. Without that floor a picture that decoded to nothing divides by zero:
        /// `limit / 0` is an infinite shrink, and an infinite shrink of a zero-sized picture is a `NaN`
        /// in a value that is used as a frame.
        public static func fitting(
            pixels: CGSize,
            points: CGSize,
            into limit: CGSize,
        ) -> Paper {
            let drawn = CGSize(width: max(points.width, 1), height: max(points.height, 1))
            let real = CGSize(width: max(pixels.width, 1), height: max(pixels.height, 1))
            let fit = min(1, limit.width / drawn.width, limit.height / drawn.height)
            let size = CGSize(width: drawn.width * fit, height: drawn.height * fit)
            // The two share an aspect by construction — they are one picture at two resolutions — so
            // one axis is the answer for both. Taking the width is a choice, and a mismatched pair
            // would come out stretched rather than silently cropped.
            return Paper(size: size, scale: real.width / size.width)
        }
    }

    // ── a drag in progress ────────────────────────────────────────────────

    /// The mark being drawn right now.
    ///
    /// A type rather than a handful of `@State` in the view, because "what has this drag drawn so far"
    /// is a question with one answer per tool and the view should not be the place that knows it — the
    /// same draft is read by the canvas on every move and by the release that decides whether to keep
    /// it.
    public struct Draft: Equatable, Sendable {
        public let tool: Tool
        public let origin: CGPoint
        /// Always at least the origin: a press is a draft of one point, which is what a pen dot is.
        public private(set) var points: [CGPoint]

        public init(tool: Tool, at point: CGPoint) {
            self.tool = tool
            self.origin = point
            self.points = [point]
        }

        /// The pointer moved, or was lifted.
        public mutating func drag(to point: CGPoint) {
            switch tool {
            case .pen:
                // Two identical points in a row are one point. The gesture reports moves the reader
                // cannot see, and a stroke *is* its points, so they would be paid for twice: once in
                // the array and once in every pass that draws it.
                if points.last != point { points.append(point) }
            case .line, .arrow, .rectangle, .ellipse:
                // A shape is where the drag started and where it is now — the second end is replaced,
                // never accumulated. It is also why dragging back onto the start leaves nothing: a
                // shape with no extent is not a mark (see `isMeaningful`).
                points = [origin, point]
            }
        }

        /// What it has drawn, for drawing it — in progress or finished.
        public var stroke: Stroke {
            let end = points.last ?? origin
            switch tool {
            case .pen: return .freehand(points)
            case .line: return .line(origin, end)
            case .arrow: return .arrow(origin, end)
            case .rectangle: return .rectangle(Sketch.rect(from: origin, to: end))
            case .ellipse: return .ellipse(Sketch.rect(from: origin, to: end))
            }
        }

        /// Whether letting go should keep it.
        public var isMeaningful: Bool { Sketch.isMeaningful(stroke) }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
