import CoreGraphics
import Foundation

/// The design system's facts: colour, type sizes, spacing, radii, and the geometry of the mark.
///
/// Here rather than beside the views, and the reason is the same one `WeiModel` exists for: a palette makes
/// *claims* — this text is readable, this step is bigger than that one — and a claim that cannot be checked
/// is a claim that is wrong in one of the two appearances without anybody noticing. These values are plain
/// numbers, so a test can compute contrast ratios and assert an order. The SwiftUI that spends them
/// (`Color`, `Font`, the glass surface, the mark's `Path`) is in `WeiShell/Design.swift`, which is a thin
/// wrapper over this.
///
/// What is deliberately **not** here: the greys. Every neutral in this app is one of macOS's own semantic
/// colours (`labelColor`, `secondaryLabelColor`, `separatorColor`, …), because they are the ones that answer
/// to dark mode, to Increase Contrast, and to the difference between an active and an inactive window — none
/// of which a hard-coded grey can do. The brand is specified here; the greys are borrowed.
public enum Wei {

    // ── colour ─────────────────────────────────────────────────────────────

    /// An sRGB triple, kept as numbers so that contrast can be *computed* rather than eyeballed — and so that
    /// the palette has a second reader (the test) which can disagree with it.
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// WCAG relative luminance: the channels linearised, then weighted by how the eye sees them.
        public var luminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// The WCAG contrast ratio between two colours: 1 for identical, 21 for black on white.
        ///
        /// Worth having as code because "does this pass" is the one design question with a numeric answer, and
        /// because the answer changes when either colour moves.
        public func contrast(with other: RGB) -> Double {
            let one = luminance
            let two = other.luminance
            return (max(one, two) + 0.05) / (min(one, two) + 0.05)
        }

        /// This colour laid over another at an alpha, as a solid triple.
        ///
        /// Solid rather than translucent on purpose: the result is a *token* — written down, tested for
        /// contrast, used as a fill — and a token whose value depends on what is behind it is not a token.
        /// The layer behind these washes is the window background and nothing else.
        public func opacityBlended(over background: RGB, alpha: Double) -> RGB {
            RGB(
                red: red * alpha + background.red * (1 - alpha),
                green: green * alpha + background.green * (1 - alpha),
                blue: blue * alpha + background.blue * (1 - alpha)
            )
        }
    }

    /// The brand: the logo's own two colours, and they are one hue family.
    ///
    /// `#78E5A4` mint and `#30714A` pine are the same green at two lightnesses — the mint is the container,
    /// the pine is the two strokes. That is a *single*-hue brand, which puts the whole weight of "make this
    /// readable in both appearances" on **lightness** rather than on having a second hue to swap in: pine is
    /// the light appearance's accent (it is the dark one, so it reads on white) and mint is the dark
    /// appearance's (it is the light one, so it reads on near-black). Same rule as before, one hue.
    ///
    /// The mint is a *fill* on light backgrounds and the accent only on dark ones: at 1.6:1 on white it is
    /// invisible as a letter. That is not a flaw in the choice, it is the constraint the choice implies, and
    /// `DesignTests` asserts it so nobody has to remember it.
    public enum Brand {
        /// `#78E5A4` — the logo's container. A fill on light backgrounds, the accent on dark ones.
        public static let mint = RGB(0x78E5A4)
        /// `#30714A` — the logo's two strokes. The accent on light backgrounds (5.9:1 on white).
        public static let pine = RGB(0x30714A)
        /// The ink drawn on a mint fill in dark mode: a near-black green, so it belongs to the same family as
        /// the mint behind it rather than being a neutral that happens to be dark.
        public static let forest = RGB(0x0E2A1B)
    }

    /// The two appearances' backgrounds, as the palette's arithmetic sees them.
    ///
    /// The app does not paint these — the window background is the platform's. They exist so that a wash can
    /// be computed as a solid colour, and so that contrast can be checked against what is actually behind the
    /// text.
    public enum Backdrop {
        public static let light = RGB(0xFFFFFF)
        /// Not black: a window background on macOS in dark mode is a very dark grey, and a contrast ratio
        /// computed against pure black is optimistic by a few percent.
        public static let dark = RGB(0x1E1E1E)
    }

    /// The palette, by the job each colour does. Light and dark side by side, because that is the only way
    /// to see that a colour has *two* values — which is the thing a single hex code hides.
    public enum Ink {
        /// The interactive colour: selection, the send button, focus rings, a link. The dark end of the hue on
        /// light backgrounds, the light end on dark ones — lightness is the only axis a single-hue brand has.
        public static let accent = (light: Brand.pine, dark: Brand.mint) as (light: RGB, dark: RGB)
        /// Text and glyphs drawn *on* an accent fill.
        public static let onAccent = (light: RGB(0xFFFFFF), dark: Brand.forest) as (light: RGB, dark: RGB)

        /// The colour a wash is made of: the mint, both appearances.
        public static let highlight = (light: Brand.mint, dark: Brand.mint) as (light: RGB, dark: RGB)
        /// Text drawn on a highlight wash. Pine on light, mint on dark — the accent in each appearance, which
        /// is what makes a chip's label read.
        public static let onHighlight = accent
        /// The wash itself, written down as the solid colour it comes out as: a token whose value depends on
        /// what is behind it is not a token, and this is the one a test checks text against.
        public static let highlightWash = (
            light: Brand.mint.opacityBlended(over: Backdrop.light, alpha: 0.15),
            dark: Brand.mint.opacityBlended(over: Backdrop.dark, alpha: 0.22)
        ) as (light: RGB, dark: RGB)

        /// The brand as the background of a **selected row** — the wash's step up, and it is a separate
        /// value because of the size of the thing it fills.
        ///
        /// A chip and a bubble are small and glanced at; a selected row is one row among forty that the
        /// reader scans, and at the wash's 15% the row it marks is a tint they have to hunt for. This is the
        /// one place where *how much* of the brand is the thing that makes it work, and 30% is where the row
        /// reads as chosen without becoming the loudest thing in the window.
        ///
        /// It replaces the platform's own selection fill, which is a solid saturated colour (the system's
        /// accent, not this app's — see `Palette.selection` in `WeiShell/Design.swift` for what was measured).
        /// The second line of such a row is drawn in `onHighlight`, and `DesignTests` checks that pairing
        /// against *this* colour: `onHighlight` on `highlightWash` is the Running chip's, but a row of type is
        /// not a chip and has to hold up on its own numbers.
        public static let selection = (
            light: Brand.mint.opacityBlended(over: Backdrop.light, alpha: 0.30),
            dark: Brand.mint.opacityBlended(over: Backdrop.dark, alpha: 0.30)
        ) as (light: RGB, dark: RGB)
    }

    // ── size ───────────────────────────────────────────────────────────────

    /// The type scale: five sizes, each with a job, each with a number.
    ///
    /// Five because the window has five kinds of text in it, and because the alternative — the eleven distinct
    /// sizes this had before the system existed (5, 8, 9, 10, 11, 11.5, 12, 13, 13.5, 15, 22) — is not a
    /// scale, it is a history.
    ///
    /// **Larger than the platform's own body size, deliberately.** `NSFont.systemFontSize` is 13 and that is
    /// what a Mac control uses; this app is a *reader* — a transcript is paragraphs of prose read for minutes
    /// at a time — and 13 is a control's size, not a reading size. So the anchor for "matches the platform" is
    /// `control`, which is 13, and `body` is a step above it at 15. The rule is not "copy the platform"; it is
    /// "know which of these two things you are drawing".
    public enum Size {
        /// A figure that sits against a glyph — a badge count — where the caption size would unbalance the
        /// icon it is attached to. Not for prose.
        public static let micro: CGFloat = 11
        /// Supporting text: counts, times, the status line, a chip. The floor for anything that has to be
        /// *read* rather than glanced at.
        public static let caption: CGFloat = 12
        /// Controls and list rows: a label, a search field, a button in a column. **The platform's own control
        /// size**, which is what keeps a text field here the same height as one in any other Mac app.
        ///
        /// A list row's *label* is one step up from this (`body`), because a row is content the reader picks
        /// from rather than a control they operate — and because a two-line row whose first line is the same
        /// size as the second has no first line.
        public static let control: CGFloat = 13
        /// Content: the transcript, a notice, a paragraph. One step above the platform's control size, because
        /// this text is read rather than scanned.
        public static let body: CGFloat = 15
        /// The heading of a list column, a transcript's title, and a window's subtitle. Two steps above body,
        /// which is what makes a column read as *headed* rather than as a list that starts with a bold row —
        /// the first version of the three-column layout put the column titles at 15 next to 15-point content
        /// and the hierarchy disappeared.
        public static let title: CGFloat = 20
    }

    /// Glyph sizes, for the places a symbol stands on its own rather than inside a run of text.
    public enum Icon {
        /// Inline with caption text — a magnifier in a field, a dot in a chip.
        public static let inline: CGFloat = 12
        /// Inline with control text — a row's leading glyph.
        public static let control: CGFloat = 14
        /// Larger than the text beside it, which is what a toolbar-ish glyph needs not to read as punctuation.
        public static let emphasis: CGFloat = 15
        /// A bare mark with no text at all: the dot that says which project is open.
        public static let mark: CGFloat = 6
    }

    /// The spacing scale, on a 4-point rhythm.
    ///
    /// The grid is 4, with 2 available for optical adjustments (the gap between two lines of one row, a dot
    /// against its label) — and every value is even, which is what makes "8" a value from a system rather than
    /// a number somebody liked. Before this existed the window used 0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 14,
    /// 16, 24: fourteen values for a window with four kinds of gap in it.
    public enum Space {
        /// Between two lines of one row, or a glyph and its label.
        public static let tiny: CGFloat = 2
        /// Within a control: icon to text, a dot to its word.
        public static let tight: CGFloat = 4
        /// Between stacked items in a card, and the gap inside a chip.
        public static let cozy: CGFloat = 8
        /// The default gap, and the inset of a dense surface.
        public static let regular: CGFloat = 12
        /// Between groups, and the inset of a column.
        public static let loose: CGFloat = 16
        /// Between sections, and the padding of a panel.
        public static let section: CGFloat = 24
        /// Around a dialog or an empty state.
        public static let page: CGFloat = 32
    }

    /// Corner radii, by the size of the thing being rounded.
    ///
    /// The rule is Apple's: the radius grows with the container, and a small element never gets a large one —
    /// a 8-point radius on a 26-point chip and on a 400-point card are both wrong, in opposite directions.
    public enum Radius {
        /// A chip, a badge, a small inline surface.
        public static let chip: CGFloat = 8
        /// A field or a button: the size of a control.
        public static let control: CGFloat = 10
        /// A notice or a grouped block inside content.
        public static let panel: CGFloat = 12
        /// A row's highlight.
        public static let row: CGFloat = 14
        /// The floating composer, the biggest thing in the window.
        public static let surface: CGFloat = 28
    }

    /// Control heights and hairlines, from the platform's own metrics.
    public enum Control {
        /// The toolbar control height: what the search field and the titlebar's buttons are matched to.
        public static let regular: CGFloat = 32
        /// The small control height, for a control inside a row.
        public static let small: CGFloat = 24
        /// A list row that carries two lines of text. Tall enough that the two lines are a group rather than
        /// two things that happen to be adjacent.
        public static let row: CGFloat = 40
        /// The hairline under a divider or around a floating surface.
        public static let hairline: CGFloat = 0.5
        /// The window's toolbar. The one control height the platform fixes rather than a view choosing:
        /// a unified titlebar and toolbar are 52 points on every Mac that draws one, whatever the window
        /// is showing. It is a number here because the transcript runs *under* the toolbar, so something
        /// has to say how far the content must start below the top for its first row to be readable — and
        /// the toolbar itself is not a view that can be asked.
        public static let toolbar: CGFloat = 52
    }

    // ── the mark ───────────────────────────────────────────────────────────

    /// The mark, as data: the logo's own path commands, so that the icon (CoreGraphics) and the app (SwiftUI)
    /// draw the same shape from one source.
    ///
    /// Path commands rather than parameters, because the logo is *drawn* — its container has a curved top edge
    /// that dips in the middle, and each stroke ends in a tail that sweeps down and left into it. An earlier
    /// version of this expressed the mark as "two capsules in a rounded square" and lost exactly those two
    /// features, which are the mark: the tails are what make the two strokes read as a **w**.
    ///
    /// The numbers are the SVG's, in its own 52×32 box, and the y axis is the SVG's (growing downwards) — the
    /// `CGPath` side flips the context once rather than converting points, because that conversion is where
    /// two earlier attempts went wrong. See `Wei.MarkShape` and `make-icon.swift`.
    public enum Mark {
        public static let box = CGSize(width: 52, height: 32)

        /// One path command, in the mark's coordinate space.
        public enum Segment: Equatable {
            case move(CGPoint)
            case line(CGPoint)
            case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
            case close
        }

        /// The container: a flat-bottomed shape whose **top edge curves down** in the middle. Drawn from the
        /// left edge round the bottom and back, because the top is one continuous curve through the middle.
        public static let container: [Segment] = [
            .move(CGPoint(x: 52, y: 7)),
            .line(CGPoint(x: 52, y: 20.4138)),
            .curve(
                to: CGPoint(x: 40, y: 32),
                control1: CGPoint(x: 52, y: 26.8127),
                control2: CGPoint(x: 46.6274, y: 32)
            ),
            .line(CGPoint(x: 12, y: 32)),
            .curve(
                to: CGPoint(x: 0, y: 20.4138),
                control1: CGPoint(x: 5.37258, y: 32),
                control2: CGPoint(x: 0, y: 26.8127)
            ),
            .line(CGPoint(x: 0, y: 7)),
            .curve(
                to: CGPoint(x: 26, y: 10),
                control1: CGPoint(x: 0, y: 7),
                control2: CGPoint(x: 15.7808, y: 9.80708)
            ),
            .curve(
                to: CGPoint(x: 52, y: 7),
                control1: CGPoint(x: 36.1818, y: 10.1922),
                control2: CGPoint(x: 52, y: 7)
            ),
            .close,
        ]

        /// The left stroke: a capsule with a **tail** sweeping down and left, which is what suggests a "w".
        /// The right stroke is this mirrored about `mirrorAxis`, so the two cannot drift apart.
        public static let stroke: [Segment] = [
            .move(CGPoint(x: 14.5, y: 0)),
            .curve(
                to: CGPoint(x: 23, y: 8.5),
                control1: CGPoint(x: 19.1944, y: 0),
                control2: CGPoint(x: 23, y: 3.80558)
            ),
            .line(CGPoint(x: 23, y: 17.5)),
            .curve(
                to: CGPoint(x: 14.5, y: 26),
                control1: CGPoint(x: 23, y: 22.1944),
                control2: CGPoint(x: 19.1944, y: 26)
            ),
            .curve(
                to: CGPoint(x: 6, y: 17.5),
                control1: CGPoint(x: 9.80558, y: 26),
                control2: CGPoint(x: 6, y: 22.1944)
            ),
            .line(CGPoint(x: 6, y: 10)),
            .line(CGPoint(x: 0, y: 7)),
            .curve(
                to: CGPoint(x: 8.20312, y: 2.48633),
                control1: CGPoint(x: 3.14084, y: 7.52347),
                control2: CGPoint(x: 6.0084, y: 4.7933)
            ),
            .curve(
                to: CGPoint(x: 14, y: 0),
                control1: CGPoint(x: 9.66048, y: 0.954598),
                control2: CGPoint(x: 11.7188, y: 0)
            ),
            .line(CGPoint(x: 14.5, y: 0)),
            .close,
        ]

        /// The two strokes are symmetric about this x. Asserted by a test rather than checked by eye, because
        /// "the right one is the mirror of the left" is the property that makes them a pair.
        public static let mirrorAxis: CGFloat = 26

        /// A path mirrored about `mirrorAxis`.
        public static func mirrored(_ segments: [Segment]) -> [Segment] {
            func flip(_ point: CGPoint) -> CGPoint {
                CGPoint(x: 2 * mirrorAxis - point.x, y: point.y)
            }
            return segments.map { segment in
                switch segment {
                case let .move(point): return .move(flip(point))
                case let .line(point): return .line(flip(point))
                case let .curve(to, control1, control2):
                    return .curve(to: flip(to), control1: flip(control1), control2: flip(control2))
                case .close: return .close
                }
            }
        }
    }
}
