import AppKit
import SwiftUI
import XCTest

@testable import WeiShell
@testable import WeiModel

/// The brand tokens **as AppKit resolves them**, which is the half `WeiModel`'s tests cannot see.
///
/// `WeiModel`'s `DesignTests` check the numbers — the palette's claims about contrast, order and geometry. What
/// they cannot check is whether a `Color` built by `WeiShell/Design.swift` actually hands those numbers to the
/// renderer in each appearance: every token there is an `NSColor` with a dynamic provider, so "which value comes
/// out" depends on an appearance being asked, and a token built from the wrong one of the two halves still looks
/// fine in whichever appearance the person checking happens to be in.
///
/// That is how the mark lost its logo: its strokes were built from `accent` (which swaps lightness between
/// appearances) instead of a fixed colour, so in the dark appearance the strokes came out the same mint as the
/// container they sit on. This is the test that would have caught it, and it checks both directions — the tokens
/// that must not change, and the ones whose whole job is to.
final class PaletteResolutionTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// The components of a `Color` as the given appearance resolves it, in sRGB.
    private func components(_ color: Color, _ appearance: NSAppearance.Name) -> (Double, Double, Double) {
        var out: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            out = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }
        return out
    }

    private func assertResolves(
        _ color: Color,
        to expected: Wei.RGB,
        _ appearance: NSAppearance.Name,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let (red, green, blue) = components(color, appearance)
        let tolerance = 0.001
        XCTAssertEqual(red, expected.red, accuracy: tolerance, "\(what): red", file: file, line: line)
        XCTAssertEqual(green, expected.green, accuracy: tolerance, "\(what): green", file: file, line: line)
        XCTAssertEqual(blue, expected.blue, accuracy: tolerance, "\(what): blue", file: file, line: line)
    }

    /// **The mark's two colours do not change with the appearance.**
    ///
    /// `wei-logo.svg` is one picture in two fixed colours — a mint container and pine strokes — and the app's
    /// identity should not be a different picture at night. Worth a test because the wrong build looks correct in
    /// one appearance and wrong in the other, which is exactly the appearance nobody is looking at.
    func testTheMarkIsTheSameTwoColoursInBothAppearances() {
        for appearance in appearances {
            assertResolves(
                Wei.Palette.markFill, to: Wei.Brand.mint, appearance,
                "the mark's container in \(appearance.rawValue)"
            )
            assertResolves(
                Wei.Palette.markInk, to: Wei.Brand.pine, appearance,
                "the mark's strokes in \(appearance.rawValue)"
            )
        }
    }

    /// The tokens that *are* meant to swap between appearances still swap. Without this, "the mark does not
    /// change" could be satisfied by making nothing change.
    func testTheAppearancesSwapTheTokensThatShouldSwap() {
        for appearance in appearances {
            let dark = appearance == .darkAqua
            assertResolves(
                Wei.Palette.accent, to: dark ? Wei.Ink.accent.dark : Wei.Ink.accent.light,
                appearance, "the accent in \(appearance.rawValue)"
            )
            assertResolves(
                Wei.Palette.selection, to: dark ? Wei.Ink.selection.dark : Wei.Ink.selection.light,
                appearance, "the selection fill in \(appearance.rawValue)"
            )
            assertResolves(
                Wei.Palette.onHighlight, to: dark ? Wei.Ink.onHighlight.dark : Wei.Ink.onHighlight.light,
                appearance, "the ink drawn on a highlight in \(appearance.rawValue)"
            )
        }
    }
}

/// The mark, **rendered** rather than described: the tokens above can be right while the picture is wrong.
///
/// This is the check the user's report needed. `MarkView` fills two shapes — the container and the strokes — and
/// the bug was that the *strokes'* colour was the accent, which swaps between appearances, so in dark mode the
/// strokes were painted in the same mint as the container they sit on. Nothing in the palette's numbers says
/// that; it is a fact about what comes out of the renderer, so it is read from the renderer.
///
/// `ImageRenderer` is used rather than a window because there is nothing else to ask: no window means no
/// vibrancy, no desktop behind it and no appearance of anyone's choosing but the two below.
@MainActor
final class MarkRenderTests: XCTestCase {
    /// The mark at 18 points, as the app draws it.
    private func render(_ appearance: NSAppearance.Name) -> CGImage? {
        let renderer = ImageRenderer(content: Wei.MarkView(height: 18))
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    private func isNear(_ color: (Int, Int, Int), _ rgb: Wei.RGB) -> Bool {
        abs(Double(color.0) / 255 - rgb.red) < 0.03
            && abs(Double(color.1) / 255 - rgb.green) < 0.03
            && abs(Double(color.2) / 255 - rgb.blue) < 0.03
    }

    func testTheRenderedMarkIsMintAndPineInBothAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let image = try XCTUnwrap(render(appearance), "no image in \(appearance.rawValue)")
            // Coordinates in the mark's own 18-point box, ×2 for the renderer's scale. The container fills the
            // bottom band; the strokes are the two tall verticals, and at y=8pt both are inside the container,
            // so what is read there is the strokes' own ink.
            let container = pixel(image, x: 12, y: 34)
            let leftStroke = pixel(image, x: 16, y: 16)
            let rightStroke = pixel(image, x: 44, y: 16)
            XCTAssertTrue(
                isNear(container, Wei.Brand.mint),
                "\(appearance.rawValue): the container is \(container), not mint"
            )
            for (where_, stroke) in [("left", leftStroke), ("right", rightStroke)] {
                XCTAssertTrue(
                    isNear(stroke, Wei.Brand.pine),
                    "\(appearance.rawValue): the \(where_) stroke is \(stroke), not pine — the mark's "
                        + "strokes are built from a token that changes with the appearance"
                )
            }
        }
    }
}
