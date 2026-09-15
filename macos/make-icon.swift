// The app icon, drawn rather than committed.
//
// A repository with a `.icns` in it has a binary nobody can review and nobody can edit: the next person who
// wants a different colour opens a design tool, and the diff is "different file". So the icon is this program,
// and `make-app.sh` runs it. What it costs is `swift` at packaging time, which the packaging step already
// needs.
//
// The mark is `wei-logo.svg`, **drawn**: the same file the design system names, read at packaging time. Before
// this, the SVG's path commands were copied into this file as `CGPoint` arithmetic — the icon is made *before*
// the app is built and cannot import `Wei.Mark` — and the copy drifted. A pair of rounded rectangles that the
// SVG does not contain ended up filling the space between the two strokes, so the Dock icon was a *different
// mark* from the one the window draws and from the one the file describes. Nothing caught it, because the two
// were only ever compared by eye, at 16 pixels. Reading the file removes the class of bug, not the instance.
//
// One thing about drawing an SVG with AppKit, and it cost an attempt: `NSImage.cgImage(forProposedRect:)`
// hands back a **cached bitmap**. The mark came out with 9-pixel soft edges at 1024, because that bitmap had
// been rasterised at the SVG's own 52×32 and scaled up from there. `NSGraphicsContext` is what asks the rep
// to draw itself *at the destination size*; the same edge is one pixel wide, at 1024 and at 16.
//
//     swift macos/make-icon.swift <output.iconset>

import AppKit
import CoreGraphics
import Foundation

/// One file of the `.iconset`: the pixels, and the name macOS looks for them under.
///
/// The `@2x` entries are not optional. An `.iconset` without them produces an `.icns` whose Retina
/// representation is missing, and the icon then looks soft on every modern display — which is the
/// sort of thing that survives review because nobody looks at a small icon closely.
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

/// `wei-logo.svg`, at the repository root. From `#filePath` rather than the working directory, so the script
/// can be run from anywhere — `make-app.sh` is the caller, but `swift macos/make-icon.swift /tmp/x.iconset`
/// by hand is the way to look at a change to the icon.
let logo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("wei-logo.svg")

func drawIcon(pixels: Int, mark: NSImage) -> CGImage? {
    let size = CGFloat(pixels)
    // Premultiplied, because that is what an icon needs when it is drawn over a wallpaper and what
    // `CGImageDestination` writes PNG from without a second pass.
    guard
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }

    // Inset and radius, as fractions of the canvas — the platform's own proportions, which is what
    // makes a drawn icon look like it belongs next to a system one.
    let inset = size * 0.09
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.225

    // The tile: the platform's rounded square, filled with the brand's container colour. This is the only
    // colour the file knows — the mark brings its own two (`#78E5A4` container, `#30714A` strokes, both in the
    // SVG). Mint rather than white because that *is* the mark's ground: the logo's own container is the same
    // mint, so tile and container merge and the two strokes stand on it. `WEI_ICON_TILE=white` draws the mark
    // on paper instead, which is how it reads in a document.
    let tileIsMint = ProcessInfo.processInfo.environment["WEI_ICON_TILE"] != "white"
    context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(
        tileIsMint
            ? CGColor(srgbRed: 0x78 / 255, green: 0xE5 / 255, blue: 0xA4 / 255, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    )
    context.fillPath()

    // The mark, sized to the tile: 78% of the tile's width, the margin being a fraction of the *tile* — which
    // is what keeps the mark's optical size the same at 16 pixels and at 1024. The height comes from the SVG's
    // own aspect ratio rather than a second number here, so the file is the only thing that says how tall the
    // mark is.
    let markWidth = tile.width * 0.78
    let markHeight = markWidth * mark.size.height / mark.size.width
    let destination = CGRect(
        x: tile.midX - markWidth / 2,
        y: tile.midY - markHeight / 2,
        width: markWidth,
        height: markHeight
    )
    // No flip: the SVG's y axis grows downwards and `NSImage` draws it that way. An earlier version replayed
    // the paths through CoreGraphics, which grows upwards, and needed one.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    mark.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage()
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
guard let mark = NSImage(contentsOf: logo) else {
    FileHandle.standardError.write(Data("could not read \(logo.path)\n".utf8))
    exit(1)
}
let directory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for entry in sizes {
    guard let image = drawIcon(pixels: entry.pixels, mark: mark) else {
        FileHandle.standardError.write(Data("could not draw \(entry.name)\n".utf8))
        exit(1)
    }
    let destination = directory.appendingPathComponent(entry.name)
    guard
        let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else {
        FileHandle.standardError.write(Data("could not write \(entry.name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else {
        FileHandle.standardError.write(Data("could not finish \(entry.name)\n".utf8))
        exit(1)
    }
}

print(directory.path)
