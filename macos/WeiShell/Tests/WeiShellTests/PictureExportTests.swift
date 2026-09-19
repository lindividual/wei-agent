import AppKit
import XCTest

import WeiModel
@testable import WeiShell

/// The bytes a sheet produces — the half of the picture sheet that can be checked without a window.
///
/// The sheet on screen would look right even if the file were wrong, so this is the only place the
/// export can be wrong and be *seen* being wrong: how big the file is, whether the picture the reader
/// marked up is under the ink or missing from it, and whether the ink landed where it was drawn.
/// `macos/README.md` has the same rule for the blank sketch ("屏幕和 PNG 是同一个 `SketchCanvas` 的两次
/// 渲染") and this is what holds it to it.
@MainActor
final class PictureExportTests: XCTestCase {

    private func png(_ paper: Sketch.Paper, _ strokes: [Sketch.Stroke], under: NSImage? = nil) throws
        -> NSBitmapImageRep
    {
        let data = try XCTUnwrap(PictureExport.png(paper: paper, strokes: strokes, under: under))
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    /// A picture of one color, at a known size, standing in for a screenshot.
    private func swatch(_ color: NSColor, _ width: Int, _ height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    /// A picture shaped like a real capture: `pixels` big, `scale` times its size in points.
    ///
    /// Which is what the system's tool writes — a full screen of a 2× display is 2940×1912 pixels and
    /// 1470×956 points, because the file carries 144 dpi — and it is the reason `NSImage.size` is not
    /// the answer to "how many pixels is this" (`WeiShell.NSImage.pixelSize` is).
    private func capture(pixels: CGSize, scale: CGFloat) -> NSImage {
        let points = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: points.width, height: points.height)
        let image = NSImage(size: NSSize(width: points.width, height: points.height))
        image.addRepresentation(rep)
        return image
    }

    /// Whether this pixel is ink.
    ///
    /// Sampled at the **middle of an edge**, never at a corner: the ink is a 2.5-point stroke centred on
    /// the path, so a corner pixel is a quarter covered and comes back grey — a number this test would
    /// then be squinting at. Half of a stroke's width is inside the path, which is why the marks used
    /// here are inset from the paper's edge.
    private func isInk(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let color = rep.colorAt(x: x, y: y) else { return false }
        return color.brightnessComponent < 0.5
    }

    // ── how big the file is ───────────────────────────────────────────────

    /// A blank sketch is still 2× its points, which is the size the model was always shown.
    func testABlankSketchIsExportedAtTwiceItsPoints() throws {
        let rep = try png(Sketch.Paper(size: CGSize(width: 640, height: 420), scale: 2), [])
        XCTAssertEqual(rep.pixelsWide, 1280)
        XCTAssertEqual(rep.pixelsHigh, 840)
    }

    /// A shrunk capture is exported at **the capture's own pixels**, which is the whole reason the paper
    /// keeps its points and its pixels apart: the sheet is 440 points tall, and the file is 1912 pixels.
    ///
    /// The assertion has a pixel of slack in it, and that is a fact rather than politeness: the export
    /// is a re-render, and the renderer rounds the pixel size *up*, so a 2940-pixel-wide capture comes
    /// back 2941. What matters — and what the window's own scale would get wrong by a factor of two — is
    /// that the file is the capture's resolution and not the sheet's.
    func testAShrunkCaptureIsExportedAtItsOwnPixels() throws {
        let capture = self.capture(pixels: CGSize(width: 2940, height: 1912), scale: 2)
        XCTAssertEqual(capture.size, CGSize(width: 1470, height: 956))
        XCTAssertEqual(capture.pixelSize, CGSize(width: 2940, height: 1912))
        let paper = Sketch.Paper.fitting(
            pixels: capture.pixelSize,
            points: capture.size,
            into: CGSize(width: 680, height: 440)
        )
        let rep = try png(paper, [], under: capture)
        XCTAssertEqual(Double(rep.pixelsWide), 2940, accuracy: 1)
        XCTAssertEqual(Double(rep.pixelsHigh), 1912, accuracy: 1)
    }

    /// A capture that already fits the sheet is exported **one pixel per pixel**, which is the case the
    /// sheet must not spoil: a 300-point window screenshot goes out as the 600 pixels it is.
    func testACaptureThatFitsIsExportedOneToOne() throws {
        let capture = self.capture(pixels: CGSize(width: 600, height: 400), scale: 2)
        let paper = Sketch.Paper.fitting(
            pixels: capture.pixelSize,
            points: capture.size,
            into: CGSize(width: 680, height: 440)
        )
        XCTAssertEqual(paper.size, CGSize(width: 300, height: 200))
        let rep = try png(paper, [], under: capture)
        XCTAssertEqual(rep.pixelsWide, 600)
        XCTAssertEqual(rep.pixelsHigh, 400)
    }

    // ── where the ink is ──────────────────────────────────────────────────

    /// **The ink lands where it was drawn**, in the file as on the screen.
    ///
    /// Three pixels, because one cannot tell the mistakes apart: the top edge is where a correct export
    /// puts it, the same column well below the shape is empty (so the mark was not stretched), and the
    /// *mirrored* row is empty too (so nothing was flipped on the way out — the one mistake that would
    /// send a model a picture with the arrow upside down).
    ///
    /// Measured, so the numbers are the rendering's: a rectangle drawn at (5, 5)–(25, 25) points is ink
    /// at pixel row 10 and row 50 of a 200-pixel-tall file (2× the 100 points of paper), and its middle
    /// is white.
    func testAMarkIsExportedWhereItWasDrawn() throws {
        let rep = try png(
            Sketch.Paper(size: CGSize(width: 100, height: 100), scale: 2),
            [.rectangle(CGRect(x: 5, y: 5, width: 20, height: 20))]
        )
        XCTAssertTrue(isInk(rep, 30, 10), "expected the top edge where it was drawn")
        XCTAssertTrue(isInk(rep, 30, 50), "expected the bottom edge where it was drawn")
        XCTAssertFalse(isInk(rep, 30, 30), "expected the middle of the rectangle to be empty")
        XCTAssertFalse(isInk(rep, 30, 190), "expected nothing mirrored into the bottom of the file")
    }

    // ── the picture underneath ────────────────────────────────────────────

    /// **The picture is in the file**, not just on the screen: a red capture comes back red.
    ///
    /// This is the one bug the sheet could have that nothing else would catch — a `render` that drew the
    /// marks and forgot the picture would still show the reader their screenshot, and would send the
    /// model a blank white rectangle with an arrow on it. Compared as components rather than against an
    /// exact value, because the renderer is entitled to colour-manage what it draws.
    func testThePictureUnderneathIsExported() throws {
        let rep = try png(
            Sketch.Paper(size: CGSize(width: 50, height: 50), scale: 1),
            [],
            under: swatch(.red, 50, 50)
        )
        let middle = try XCTUnwrap(rep.colorAt(x: 25, y: 25))
        XCTAssertGreaterThan(middle.redComponent, middle.greenComponent + 0.3)
        XCTAssertGreaterThan(middle.redComponent, middle.blueComponent + 0.3)
    }

    /// The ink is **over** the picture: a mark on a red capture is the ink, and the picture is what is
    /// left where there is no mark.
    func testTheInkIsDrawnOverThePicture() throws {
        let rep = try png(
            Sketch.Paper(size: CGSize(width: 50, height: 50), scale: 1),
            [.rectangle(CGRect(x: 5, y: 5, width: 30, height: 30))],
            under: swatch(.red, 50, 50)
        )
        XCTAssertTrue(isInk(rep, 20, 5), "expected the mark's stroke over the picture")
        let inside = try XCTUnwrap(rep.colorAt(x: 20, y: 25))
        XCTAssertGreaterThan(
            inside.redComponent, inside.blueComponent + 0.3,
            "expected the picture where there is no mark"
        )
    }

    /// **The picture is the right way up in the file.**
    ///
    /// The marks live in a top-left-origin space (a `Canvas`) and a picture read from bytes is drawn in
    /// the bottom-left-origin space a `CGImage` lives in, so "which way up is this" is a question both
    /// halves answer — and one of the answers can be wrong. A screenshot exported upside down would be
    /// a whole class of bug that is *invisible on screen*: the sheet draws the picture the way the export
    /// does, so the reader would see the same flipped picture and have nothing to compare it against.
    ///
    /// A picture painted two different corners is the cheapest thing that can tell:
    /// `NSBitmapImageRep.colorAt` counts `y` from the top, exactly as the marks do.
    func testThePictureIsNotUpsideDown() throws {
        let corner = NSImage(size: NSSize(width: 100, height: 100))
        corner.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 60, width: 40, height: 40).fill()
        NSColor.blue.setFill()
        NSRect(x: 60, y: 0, width: 40, height: 40).fill()
        corner.unlockFocus()

        let rep = try png(
            Sketch.Paper(size: CGSize(width: 100, height: 100), scale: 1),
            [],
            under: corner
        )
        let topLeft = try XCTUnwrap(rep.colorAt(x: 20, y: 20))
        let bottomRight = try XCTUnwrap(rep.colorAt(x: 80, y: 80))
        XCTAssertGreaterThan(topLeft.redComponent, topLeft.blueComponent + 0.3, "expected red at the top left")
        XCTAssertGreaterThan(
            bottomRight.blueComponent, bottomRight.redComponent + 0.3,
            "expected blue at the bottom right"
        )
    }
}
