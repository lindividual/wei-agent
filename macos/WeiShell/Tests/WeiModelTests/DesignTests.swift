import AppKit
import XCTest

import WeiModel

/// The design system's claims, where they are claims about the world rather than restatements.
///
/// A design document that says "readable" is an opinion. A palette that says it is a set of numbers, and
/// "does this text pass" has an answer: WCAG's contrast ratio, and the 4.5:1 the guidelines put on body
/// text. These tests are the palette arguing with itself — which is the only way a colour scheme stays
/// honest, because the failure mode of a palette is not being ugly, it is being unreadable in one of the two
/// appearances while everyone's Mac is in the other one.
final class DesignTests: XCTestCase {
    /// WCAG AA for text below 18 points.
    private let aa = 4.5

    /// The brand, pinned to the logo's own two colours. Everything else is derived from them: if the mark's
    /// colours change, this is the line that changes with it and the rest of the palette is re-checked.
    func testTheBrandIsTheLogosColours() {
        XCTAssertEqual(Wei.Brand.mint, Wei.RGB(0x78E5A4))
        XCTAssertEqual(Wei.Brand.pine, Wei.RGB(0x30714A))
    }

    /// **A one-hue brand puts everything on lightness**, and this is that claim as arithmetic.
    ///
    /// Mint and pine are one green at two lightnesses: pine is dark enough to be text on white, mint is light
    /// enough to be text on near-black. So the accent swaps *lightness* between appearances rather than hue —
    /// and the mint, which cannot be text on white at all (1.6:1), is the fill there. Both facts are asserted,
    /// the failure included: if someone "fixes" the palette by using the mint as a light-mode accent, the test
    /// says why that cannot work.
    func testOneHueCoversBothAppearancesByLightness() {
        XCTAssertGreaterThanOrEqual(
            Wei.Brand.pine.contrast(with: Wei.Backdrop.light), aa,
            "the light appearance's accent is not readable on white"
        )
        XCTAssertGreaterThanOrEqual(
            Wei.Brand.mint.contrast(with: Wei.Backdrop.dark), aa,
            "the dark appearance's accent is not readable on a dark background"
        )
        XCTAssertLessThan(
            Wei.Brand.mint.contrast(with: Wei.Backdrop.light), aa,
            "the mint now passes on white, which changes what it may be used for: it is a fill there"
        )
        XCTAssertLessThan(
            Wei.Brand.pine.contrast(with: Wei.Backdrop.dark), aa,
            "pine now passes on dark, which changes what it may be used for"
        )
    }

    /// The accent in its own appearance, in both directions: as text, and as a fill behind the ink meant for
    /// it. The send button is the fill case and a link is the text case.
    func testTheAccentCarriesTextBothWays() {
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.accent.light.contrast(with: Wei.Backdrop.light), aa,
            "the light accent is not readable as text"
        )
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.onAccent.light.contrast(with: Wei.Ink.accent.light), aa,
            "white on the light accent is not readable"
        )
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.accent.dark.contrast(with: Wei.Backdrop.dark), aa,
            "the dark accent is not readable as text"
        )
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.onAccent.dark.contrast(with: Wei.Ink.accent.dark), aa,
            "the dark ink on the dark accent is not readable"
        )
    }

    /// A chip is the whole two-hue system in one control: a *fill* in one hue and *text* in the other. The
    /// wash is a token — the solid colour the fill comes out as over the window — which is what makes this
    /// checkable at all.
    func testAChipIsReadableInBothAppearances() {
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.onHighlight.light.contrast(with: Wei.Ink.highlightWash.light), aa,
            "a chip's text is not readable on its own background"
        )
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.onHighlight.dark.contrast(with: Wei.Ink.highlightWash.dark), aa,
            "a chip's text is not readable on its own background in dark mode"
        )
        // And the wash has to be distinguishable from the window it sits on, or the chip is a word with no
        // capsule around it. 1.05 is the floor at which a fill is visible as a fill.
        XCTAssertGreaterThan(Wei.Ink.highlightWash.light.contrast(with: Wei.Backdrop.light), 1.05)
        XCTAssertGreaterThan(Wei.Ink.highlightWash.dark.contrast(with: Wei.Backdrop.dark), 1.05)
    }

    /// A selected row is the chip's claim one size up, and it is checked on its own numbers rather than
    /// inherited: a row is a bigger thing than a chip, so it carries more of the brand (`Ink.selection` is the
    /// wash's step up), and the text on it has to hold up on the fill it is actually drawn on.
    ///
    /// This is the pairing a reader complained about, in the version where the platform drew the fill in the
    /// *system's* blue: the app's own secondary line is a grey, and a grey over a saturated fill is neither
    /// readable nor the same hue as what it sits on.
    func testASelectedRowIsReadableInBothAppearances() {
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.onHighlight.light.contrast(with: Wei.Ink.selection.light), aa,
            "the second line of a selected row is not readable on its fill"
        )
        XCTAssertGreaterThanOrEqual(
            Wei.Ink.onHighlight.dark.contrast(with: Wei.Ink.selection.dark), aa,
            "the second line of a selected row is not readable on its fill in dark mode"
        )
        // The row's *name* is `labelColor`, which is the platform's and is not in this palette, so what is
        // checkable is the direction: a light fill gets the platform's dark label, a dark fill gets its light
        // one. A fill on the wrong side of the midpoint would put the platform's white label on a pale row.
        XCTAssertGreaterThan(Wei.Ink.selection.light.luminance, 0.5, "the light fill is not a light colour")
        XCTAssertLessThan(Wei.Ink.selection.dark.luminance, 0.5, "the dark fill is not a dark colour")
        // A selection has to be visible *as* a selection, which is the claim that makes it a token of its own
        // rather than the chip's wash: it is further from the window than the wash is, in both appearances.
        XCTAssertGreaterThan(
            Wei.Ink.selection.light.contrast(with: Wei.Backdrop.light),
            Wei.Ink.highlightWash.light.contrast(with: Wei.Backdrop.light),
            "the selection fill is no more visible than a chip's wash"
        )
        XCTAssertGreaterThan(
            Wei.Ink.selection.dark.contrast(with: Wei.Backdrop.dark),
            Wei.Ink.highlightWash.dark.contrast(with: Wei.Backdrop.dark),
            "the selection fill is no more visible than a chip's wash in dark mode"
        )
    }

    /// The two brand colours are far enough apart in *lightness* to be told apart, which is the axis a
    /// one-hue palette has. If the mint and the pine ever converge, the mark stops reading as a shape and the
    /// accent stops being distinguishable from its own fill.
    func testTheBrandsTwoLightnessesAreDistinguishable() {
        let ratio = Wei.Brand.mint.contrast(with: Wei.Brand.pine)
        XCTAssertGreaterThanOrEqual(ratio, 3.0, "the mark's two colours are too close to read as a mark")
    }

    /// The type scale is a scale, and its anchor is the platform's **control** size rather than its body size.
    ///
    /// This is the deliberate difference from a stock Mac app, and it is worth a test because the obvious
    /// "fix" is to make `body` equal `NSFont.systemFontSize`: 13 is a control's size, this window is a reader,
    /// and the two are allowed to differ — what is not allowed is for the *control* size to differ, because a
    /// text field that is not the height of every other text field is a text field that looks wrong next to
    /// one.
    func testTheTypeScaleAnchorsOnThePlatformsControlSize() {
        let sizes = [
            Wei.Size.micro, Wei.Size.caption, Wei.Size.control, Wei.Size.body, Wei.Size.title,
        ]
        XCTAssertEqual(sizes, sizes.sorted(), "the type scale is not in order")
        XCTAssertEqual(Set(sizes).count, sizes.count, "two steps of the scale are the same size")
        XCTAssertEqual(Wei.Size.control, NSFont.systemFontSize, "the control size is not the platform's")
        XCTAssertGreaterThan(Wei.Size.body, Wei.Size.control, "content should be larger than a control")
        // The floor for anything that has to be read rather than glanced at.
        XCTAssertGreaterThanOrEqual(Wei.Size.caption, 12)
    }

    /// **Spacing is on the grid; radii are not**, and the difference is the point.
    ///
    /// A gap is a distance between two things and it has to be commensurate with every other gap, or a column
    /// of controls steps in and out. A *radius* is the shape of one corner and it is absolute: 12 points on a
    /// 32-point control is visibly too round, and the right value there is 10 — which is off the 4-point grid
    /// and is still the right value. Forcing radii onto the spacing grid is the kind of tidy rule that makes
    /// corners wrong, and this test previously asserted it: the failure is what produced this comment.
    ///
    /// What radii *do* owe the system is order and distinctness, plus the growth rule — a small element never
    /// gets a large radius.
    func testSpacingIsOnTheGridAndRadiiGrowWithTheirContainer() {
        let space = [
            Wei.Space.tiny, Wei.Space.tight, Wei.Space.cozy, Wei.Space.regular,
            Wei.Space.loose, Wei.Space.section, Wei.Space.page,
        ]
        XCTAssertEqual(space, space.sorted())
        XCTAssertEqual(Set(space).count, space.count)
        for value in space {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 2), 0, "\(value) is not an even step")
        }
        // 2 is the one step available for optical adjustment; everything above it is on the 4-point rhythm.
        for value in space.dropFirst() {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0, "\(value) is off the 4-point grid")
        }

        let radii = [
            Wei.Radius.chip, Wei.Radius.control, Wei.Radius.panel,
            Wei.Radius.row, Wei.Radius.surface,
        ]
        XCTAssertEqual(radii, radii.sorted())
        XCTAssertEqual(Set(radii).count, radii.count)
        // The growth rule, as numbers: the smallest is for a chip-sized thing and the largest for the
        // floating composer, and the ratio between them stays in a range that does not look like a mistake.
        XCTAssertGreaterThanOrEqual(Wei.Radius.chip, 6)
        XCTAssertLessThanOrEqual(Wei.Radius.surface, Wei.Control.regular * 1.5)
        // A control's radius is about a third of its height — the proportion Apple uses for a button.
        XCTAssertEqual(Wei.Radius.control, Wei.Control.regular * 0.31, accuracy: 0.6)
    }

    /// The layout is **loose rather than tight**, which is a claim about the numbers and so can be asserted:
    /// every step that is a gap is at least as large as the text it separates, and a list row is tall enough
    /// to hold two lines with air around them.
    func testTheLayoutIsLoose() {
        XCTAssertGreaterThanOrEqual(Wei.Space.regular, 12, "the default gap is tight")
        XCTAssertGreaterThanOrEqual(Wei.Control.row, Wei.Size.body * 2, "a row cannot hold two lines")
        XCTAssertGreaterThanOrEqual(Wei.Control.regular, Wei.Size.control + 16, "the control is cramped")
        XCTAssertGreaterThanOrEqual(Wei.Radius.surface, 24, "the composer's corners are tight")
    }

    /// The mark's shape, where it is a claim rather than a list of numbers.
    ///
    /// Three properties, and each one is something an earlier version of this drawing got wrong by
    /// generalising the logo instead of copying it:
    ///
    ///   1. the two strokes are **mirror images** about the box's centre;
    ///   2. the container's top edge **dips** in the middle (it is not a flat lid);
    ///   3. each stroke has a **tail** that reaches outside its own capsule — the part that reads as a "w".
    func testTheMarkIsMirroredDippedAndTailed() {
        let box = Wei.Mark.box
        XCTAssertEqual(Wei.Mark.mirrorAxis * 2, box.width, "the mirror axis is not the box's centre")

        let once = Wei.Mark.mirrored(Wei.Mark.stroke)

        // Every point of the mirrored stroke is the reflection of the original's, including the controls —
        // which is the real assertion. "Mirroring twice returns the original" is the same fact said twice and
        // is *not* exactly true in floating point (`2 * 26 - (2 * 26 - 9.80558)` is 9.805579999999999), so the
        // comparison is per point with a tolerance rather than by equality of the whole list.
        func points(_ segments: [Wei.Mark.Segment]) -> [CGPoint] {
            segments.flatMap { segment -> [CGPoint] in
                switch segment {
                case let .move(p), let .line(p): return [p]
                case let .curve(to, c1, c2): return [to, c1, c2]
                case .close: return []
                }
            }
        }
        let original = points(Wei.Mark.stroke)
        let mirror = points(once)
        XCTAssertEqual(original.count, mirror.count)
        for (a, b) in zip(original, mirror) {
            XCTAssertEqual(b.x, 2 * Wei.Mark.mirrorAxis - a.x, accuracy: 0.0001)
            XCTAssertEqual(b.y, a.y, accuracy: 0.0001)
        }

        // Mirroring twice lands back on the original, to within floating point.
        for (a, b) in zip(original, points(Wei.Mark.mirrored(once))) {
            XCTAssertEqual(b.x, a.x, accuracy: 0.0001, "mirroring twice did not return the original")
            XCTAssertEqual(b.y, a.y, accuracy: 0.0001)
        }
        XCTAssertNotEqual(once, Wei.Mark.stroke, "the mirrored stroke is the same as the original")

        // 2. The top edge dips: the curve's middle control point is *below* (larger y than) its endpoints, in
        // the SVG's downward-growing coordinates.
        let dips = Wei.Mark.container.contains { segment in
            if case let .curve(to, control1, control2) = segment {
                return control1.y > to.y && control2.y > to.y
            }
            return false
        }
        XCTAssertTrue(dips, "the container's top edge is flat: the mark's dip is gone")

        // 3. The tail: the stroke reaches to the left of its own capsule body, and starts at the top. Without
        // this it is a pill, which is what an earlier version drew.
        let strokePoints = points(Wei.Mark.stroke)
        let bodyLeft = strokePoints.map(\.x).filter { $0 > 1 }.min() ?? 0
        XCTAssertLessThan(
            strokePoints.map(\.x).min() ?? bodyLeft, bodyLeft,
            "the stroke has no tail: it is a capsule, not a stroke of a \"w\""
        )
        XCTAssertEqual(
            strokePoints.map(\.y).min() ?? -1, 0, accuracy: 0.0001,
            "the stroke does not start at the top"
        )
        // And the strokes are taller than the container's top edge, so they rise out of it.
        XCTAssertEqual(
            strokePoints.map(\.y).max() ?? 0, 26, accuracy: 0.0001,
            "the stroke's lower end is not where the logo has it"
        )
    }

    /// The mark is wider than it is tall, which is what makes it a "w" lying down rather than a badge.
    func testTheMarkIsWide() {
        XCTAssertGreaterThan(Wei.Mark.box.width, Wei.Mark.box.height)
        XCTAssertEqual(Wei.Mark.box.width / Wei.Mark.box.height, 52.0 / 32.0, accuracy: 0.001)
    }
}
