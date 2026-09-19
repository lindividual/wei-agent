import AppKit
import WeiModel
import SwiftUI

/// The design system, as SwiftUI spends it: an extension of the same `Wei` whose values live in
/// `WeiModel/Design.swift`.
///
/// An `extension` rather than a second `enum Wei`, because a second one would *shadow* the first: inside it,
/// `Wei.Space.page` would resolve to the view module's type and not find it, and every view would have to
/// write `WeiModel.Wei.Space.page` — which is how a design system becomes something people route around.
/// Extending one type means `Wei.Size.body` and `Wei.Font.body()` are the same namespace, spelled the same
/// way, in every file.
///
/// The *values* are in `WeiModel` because they are facts that can be checked, and a check has to live where it
/// can link them. This half is `Color`, `Font`, `Path` and a surface, and nothing here is a literal: if a size
/// or a radius appears as a number in this file rather than as a reference to a token, it is a value that
/// escaped the system.
extension Wei {

    /// The palette, by the job each colour does.
    public enum Palette {
        /// The interactive colour: selection, the send button, focus rings, links. Applied to the whole window
        /// with `.tint`, which is the platform's own mechanism for "this app has a brand colour" — so the
        /// system draws its selection, its focus rings and its default button in the brand rather than in the
        /// reader's own accent, and every control agrees without being told separately.
        public static let accent = dynamic(Ink.accent)

        /// Text and glyphs drawn *on* an accent fill.
        public static let onAccent = dynamic(Ink.onAccent)

        /// The fill hue, for the places a brand colour is a background rather than a foreground.
        public static let highlight = dynamic(Ink.highlight)

        /// Text drawn on a highlight.
        public static let onHighlight = dynamic(Ink.onHighlight)

        /// A highlight let down to a wash: a chip's or a badge's background.
        public static let highlightWash = dynamic(Ink.highlightWash)

        /// The brand as a **selected row's** background — the wash's step up, because a row of a list is
        /// something the reader scans rather than glances at. See `Wei.Ink.selection`.
        public static let selection = dynamic(Ink.selection)

        /// The mark's own two colours: the container `mint` and the strokes `pine`, **the same in both
        /// appearances**.
        ///
        /// Deliberately not `highlight` and `accent`, which is what the mark was drawn with first. Those two
        /// swap lightness between appearances — the accent is pine on light and mint on dark — and the mark is
        /// one picture in two fixed colours (`wei-logo.svg`): in the dark appearance its strokes were painted
        /// in the same mint as the container they sit on and the mark came out a plain green blob. A brand that
        /// changes shape with the appearance is not a brand; the *interface* re-decides which of the two is
        /// readable where, and that re-decision is exactly what these two must not do.
        ///
        /// Through `dynamic` anyway, with the same value twice: the appearance still has to be asked, because
        /// these two are drawn over a window that changes colour (`NSColor` would otherwise resolve once, in
        /// whichever appearance happened to be current).
        public static let markFill = dynamic((light: Brand.mint, dark: Brand.mint))
        public static let markInk = dynamic((light: Brand.pine, dark: Brand.pine))

        /// A hairline. The platform's separator, which answers to contrast settings.
        public static let separator = Color(nsColor: .separatorColor)

        /// Text, in three weights of importance. Borrowed, never invented — see `WeiModel/Design.swift`.
        public static let label = Color(nsColor: .labelColor)
        public static let secondary = Color(nsColor: .secondaryLabelColor)
        public static let tertiary = Color(nsColor: .tertiaryLabelColor)

        /// The surface the window is drawn on, and the one a control sits on. Named so that "the window" and
        /// "a control" are one decision each rather than a colour per call site.
        public static let window = Color(nsColor: .windowBackgroundColor)
        public static let control = Color(nsColor: .controlBackgroundColor)

        /// A colour that resolves differently in light and dark mode, through AppKit rather than through an
        /// `if` in a view: `NSColor(name:dynamicProvider:)` is the platform's own mechanism, and it also gets
        /// the increase-contrast and reduce-transparency variants for free.
        private static func dynamic(_ pair: (light: RGB, dark: RGB)) -> Color {
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return nsColor(dark ? pair.dark : pair.light)
                }
            )
        }

        private static func nsColor(_ rgb: RGB) -> NSColor {
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }

    /// The type scale as `Font`s, each built from the size token of the same name.
    public enum Font {
        /// A column heading, or a window's subtitle.
        public static func title() -> SwiftUI.Font { .system(size: Size.title, weight: .semibold) }

        /// Content: the transcript, a notice, a paragraph.
        public static func body(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: Size.body, weight: weight)
        }

        /// Controls and list rows.
        public static func control(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: Size.control, weight: weight)
        }

        /// Supporting text: counts, times, a chip.
        public static func caption(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: Size.caption, weight: weight)
        }

        /// A figure against a glyph.
        public static func micro() -> SwiftUI.Font { .system(size: Size.micro) }

        /// Code, in the transcript and in a chip: monospaced at the content size by default, so a line of code
        /// and a line of prose in one message carry the same weight on the page.
        public static func code(_ size: CGFloat = Size.control) -> SwiftUI.Font {
            .system(size: size, design: .monospaced)
        }
    }

    /// The mark, as a shape: the logo's own path commands, built into a `Path`.
    ///
    /// Absolute commands in the SVG's coordinate space, and **no flip here** — SwiftUI's `Path` has its origin
    /// at the top left with y growing downwards, exactly like the SVG, so the numbers are used as they are
    /// written. (CoreGraphics, on the icon side, is the one that needs flipping; see `make-icon.swift`.)
    ///
    /// Shape-generic in what it draws: `part` selects the container or the strokes, because the logo is two
    /// colours and one filled path cannot be two.
    public struct MarkShape: Shape {
        public enum Part {
            case container
            case strokes
        }

        let part: Part

        public init(_ part: Part) {
            self.part = part
        }

        public func path(in rect: CGRect) -> Path {
            let scale = min(rect.width / Mark.box.width, rect.height / Mark.box.height)
            let origin = CGPoint(
                x: rect.minX + (rect.width - Mark.box.width * scale) / 2,
                y: rect.minY + (rect.height - Mark.box.height * scale) / 2
            )
            func place(_ point: CGPoint) -> CGPoint {
                CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
            }

            let commands: [[Mark.Segment]]
            switch part {
            case .container:
                commands = [Mark.container]
            case .strokes:
                commands = [Mark.stroke, Mark.mirrored(Mark.stroke)]
            }

            var path = Path()
            for command in commands {
                for segment in command {
                    switch segment {
                    case let .move(point):
                        path.move(to: place(point))
                    case let .line(point):
                        path.addLine(to: place(point))
                    case let .curve(to, control1, control2):
                        path.addCurve(to: place(to), control1: place(control1), control2: place(control2))
                    case .close:
                        path.closeSubpath()
                    }
                }
            }
            return path
        }
    }

    /// The logo, in the brand's colours. The one view the app draws the mark with.
    public struct MarkView: View {
        let height: CGFloat

        public init(height: CGFloat = 18) {
            self.height = height
        }

        public var body: some View {
            let width = height * Mark.box.width / Mark.box.height
            ZStack {
                MarkShape(.container).fill(Palette.markFill)
                MarkShape(.strokes).fill(Palette.markInk)
            }
            .frame(width: width, height: height)
        }
    }

    /// The one way this app draws a floating surface.
    ///
    /// Liquid Glass — the system's own material, which samples what is behind it and carries the platform's
    /// current idea of how much a floating thing should lift. Everything hand-rolled is deliberately absent:
    /// a stroke of ours over glass is a second edge, and a shadow of ours under it is a second lift, which is
    /// what makes an app look like it is imitating the platform.
    ///
    /// This used to be a two-branch modifier — glass on 26, and a thin material plus a hairline plus a shadow
    /// on 14 and 15, for a deployment target of 14. The target is 26 now (see `Package.swift`), so the second
    /// branch was unreachable code that no one could ever have run on this machine, and it is gone: one
    /// surface, the platform's.
    ///
    /// Shape-generic rather than taking a radius, because a floating control is not always a rounded
    /// rectangle — the search field is a capsule, and it is the same surface as the composer.
    public static func surface<S: Shape & InsettableShape>(in shape: S) -> some ViewModifier {
        Surface(shape: shape)
    }

    private struct Surface<S: Shape & InsettableShape>: ViewModifier {
        let shape: S

        func body(content: Content) -> some View {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// Draw this view on the app's floating surface. The call site the views use.
    public func weiSurface<S: Shape & InsettableShape>(in shape: S) -> some View {
        modifier(Wei.surface(in: shape))
    }
}
