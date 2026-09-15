// The app icon, drawn rather than committed.
//
// A repository with a `.icns` in it has a binary nobody can review and nobody can edit: the next
// person who wants a different colour opens a design tool, and the diff is "different file". So the
// icon is this program, and `make-app.sh` runs it. What it costs is `swift` at packaging time, which
// the packaging step already needs.
//
// The shape is the platform's: a rounded square inset from the canvas, the way every Mac app is drawn
// since Big Sur. The glyph is pi, in white, on a gradient — the name of the thing, and nothing else
// competing for it.
//
//     swift macos/make-icon.swift <output.iconset>

import AppKit
import CoreGraphics
import CoreText
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

func drawIcon(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    let space = CGColorSpaceCreateDeviceRGB()
    // Premultiplied, because that is what an icon needs when it is drawn over a wallpaper and what
    // `CGImageDestination` writes PNG from without a second pass.
    guard
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }

    // Inset and radius, as fractions of the canvas — the platform's own proportions, which is what
    // makes a drawn icon look like it belongs next to a system one.
    let inset = size * 0.09
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.225

    // A vertical gradient rather than a flat fill: at 32 pixels a flat square reads as a placeholder,
    // and this is the cheapest thing that reads as a drawing.
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        CGColor(red: 0.20, green: 0.22, blue: 0.42, alpha: 1.0),
        CGColor(red: 0.36, green: 0.42, blue: 0.78, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: colors,
        locations: [0.0, 1.0]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.minX, y: tile.maxY),
            end: CGPoint(x: tile.maxX, y: tile.minY),
            options: []
        )
    }
    context.restoreGState()

    // The glyph: "π" in the system font, centred on its own ink rather than on its line box, which is
    // what keeps it looking centred in a rounded square.
    let font = CTFontCreateWithName("SFProRounded-Bold" as CFString, tile.width * 0.56, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let glyph = NSAttributedString(string: "π", attributes: attributes)
    let line = CTLineCreateWithAttributedString(glyph)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(
        x: tile.midX - bounds.width / 2 - bounds.origin.x,
        y: tile.midY - bounds.height / 2 - bounds.origin.y
    )
    CTLineDraw(line, context)

    return context.makeImage()
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for entry in sizes {
    guard let image = drawIcon(pixels: entry.pixels) else {
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
