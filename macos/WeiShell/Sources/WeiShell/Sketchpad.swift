import AppKit
import SwiftUI

import WeiModel

/// The sheet a sketch is drawn in: paper, five tools, and one button that puts it on the composer.
///
/// It exists because some things are shorter to say as a picture — a box, an arrow, three circles and
/// a label — and the alternative was leaving the app for it (draw somewhere else, screenshot, drag the
/// screenshot back) to make a picture the reader could have drawn in three seconds.
///
/// Where it stops is the point of it: **this is a way to make a picture, not a drawing app.** No
/// layers, no colours, no selection, no fill, no text tool. Each of those would be a feature nobody
/// asked for on the way to "draw a box and send it", and every one of them is a thing to learn before
/// the first box. Five tools, undo, clear, done.
///
/// What it produces is an image on the next prompt, through the same path the clipboard uses: a
/// temporary file the shell reads, sniffs and deletes (`attachTemporary`). So nothing here has to know
/// what an attachment is, and the bytes never have to be understood twice.
struct Sketchpad: View {
    /// The picture, once the reader has decided it says what they meant.
    let insert: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The tool in hand.
    @State private var tool: Sketch.Tool = .pen
    /// The marks already made, oldest first — which is also the order they are drawn in, so the last
    /// one drawn is on top.
    @State private var strokes: [Sketch.Stroke] = []
    /// The drag in progress, if the pointer is down.
    @State private var draft: Sketch.Draft?
    /// What the last Clear took away, so that it can be undone.
    ///
    /// One slot rather than a stack of operations, and one is enough: the only thing in this sheet that
    /// takes away more than it just added is Clear. Until something is drawn *after* a clear, undoing
    /// walks back through the marks and then puts the whole drawing back — which is the order a real undo
    /// history would produce — and after that the clear is behind a mark the reader chose to keep, so it
    /// is history rather than a mistake still waiting to be fixed.
    @State private var cleared: [Sketch.Stroke] = []

    /// The paper, in points. Fixed, and that is the decision: the strokes are in this coordinate space
    /// and the PNG is this rectangle, so a sketch drawn in a small window and one drawn in a large
    /// window are the same picture, and nothing has to be re-laid-out on the way out.
    ///
    /// 640 × 420 is the shape of a window and a little narrower than the composer: room for two boxes
    /// and an arrow between them, which is what the first sketch anybody draws is.
    private static let paper = CGSize(width: 640, height: 420)

    /// Twice the points, because the reader of this picture has no screen. At 1× the ink is two and a
    /// half pixels and every diagonal is a staircase, which is the difference between a diagram and a
    /// smudge — the model is being asked to read shapes, and it should not have to squint.
    private static let exportScale: CGFloat = 2

    var body: some View {
        VStack(spacing: Wei.Space.regular) {
            paper
            controls
        }
        .padding(Wei.Space.regular)
        // One column, the paper's width: a sheet that resized would give the reader a second question
        // ("how big is this picture?") with no useful answer, since the answer is decided on the way out.
        .frame(width: Self.paper.width + Wei.Space.regular * 2)
    }

    // ── the paper ─────────────────────────────────────────────────────────

    private var paper: some View {
        SketchCanvas(strokes: strokes, draft: draft)
            .frame(width: Self.paper.width, height: Self.paper.height)
            // White whatever the appearance is. Paper is paper: the marks are made in black, and a
            // canvas that followed dark mode would be a hole in the ink rather than a place to draw.
            //
            // Rounded at the radius the transcript rounds a picture with (`Picture`,
            // `Wei.Radius.panel`), because those two should be one shape: a square card drawn inside a
            // rounded sheet, and then shown again as a rounded card after sending, was the one place in
            // this flow where the reader drew in something other than what they got back.
            .background(
                .white,
                in: RoundedRectangle(cornerRadius: Wei.Radius.panel, style: .continuous)
            )
            .contentShape(Rectangle())
            .gesture(drawing)
            // A crosshair over it, because the pointer is a pen here and not a pointer. `set()` rather
            // than the push/pop pair, which has to be balanced across every way a hover can end and is a
            // cursor stuck as a crosshair over the whole app the one time it is not.
            .onHover { inside in
                if inside { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
            // A hairline, not the app's glass: this is a *document*, the one surface in the window that
            // stands in for a sheet of paper, and a material would make it read as another control.
            //
            // The ink is deliberately **not** clipped to this shape, and the reason is the export: the
            // picture that goes out is a plain rectangle, so a clip here would take a mark off the
            // screen that is still in the file — a stroke drawn into a corner would come back as one
            // the reader never saw. Unclipped, a mark is in the same place on both sides, and all the
            // rounding hides is twelve points of white.
            .overlay(
                RoundedRectangle(cornerRadius: Wei.Radius.panel, style: .continuous)
                    .strokeBorder(Wei.Palette.separator, lineWidth: 1)
            )
            .accessibilityLabel("Sketch paper")
    }

    /// Press, drag, release — the whole life of every mark.
    private var drawing: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // The draft starts on the first move rather than from a separate press gesture:
                // `onChanged` is the first thing that runs, and `startLocation` is where the press was.
                if draft == nil { draft = Sketch.Draft(tool: tool, at: value.startLocation) }
                draft?.drag(to: value.location)
            }
            .onEnded { value in
                // The position the gesture ended at, which can be a point past the last `onChanged` —
                // and for a shape it is the end the reader let go at.
                var finished = draft
                finished?.drag(to: value.location)
                if let finished, finished.isMeaningful { strokes.append(finished.stroke) }
                draft = nil
                // `cleared` is deliberately left alone: a mark drawn after a clear sits *after* it in
                // history, so undoing the marks first and the clear last is the order they were made
                // in — see the note on `cleared`.
            }
    }

    // ── the controls ──────────────────────────────────────────────────────

    private var controls: some View {
        HStack(spacing: Wei.Space.tight) {
            ForEach(Sketch.Tool.allCases) { item in
                ToolButton(tool: item, selected: tool == item) { tool = item }
            }
            Divider().frame(height: Wei.Control.small - 6)
            Button("Undo", action: undo)
                .disabled(strokes.isEmpty && cleared.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo the last mark (⌘Z)")
            // The whole drawing at once, for the case Undo is the wrong shape for: the sketch went
            // wrong early and the reader wants the paper back. It does not ask first — ⌘Z puts it
            // back, and a dialog in front of a scratch drawing is friction in front of the common case.
            Button("Clear", action: clear)
                .disabled(strokes.isEmpty)

            Spacer(minLength: Wei.Space.loose)

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Insert", action: insertSketch)
                .buttonStyle(.borderedProminent)
                // The same keystroke the composer sends with, because it is the same decision: this
                // message is done being written.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(strokes.isEmpty)
                .help("Attach this sketch to your message (⌘↩)")
        }
        .font(Wei.Font.control())
    }

    private func undo() {
        if !strokes.isEmpty {
            strokes.removeLast()
        } else {
            strokes = cleared
            cleared = []
        }
    }

    private func clear() {
        cleared = strokes
        strokes = []
    }

    // ── out ───────────────────────────────────────────────────────────────

    /// Send the drawing to the composer, and close.
    private func insertSketch() {
        guard let png = render() else { return }
        insert(png)
        dismiss()
    }

    /// The drawing, as the bytes that go into the composer.
    ///
    /// Rendered from **the same view the paper draws** — the same `SketchCanvas`, at the same size — so
    /// what gets sent cannot drift from what was seen: there is one rendering of a stroke in this file
    /// and the PNG is a second *sizing* of it, not a second implementation of it.
    ///
    /// The paper is fixed, which is what makes this total: the content has a size, the ink is inside it,
    /// and rendering a view that draws cannot come back empty. So a `nil` here is not a case with
    /// anything to say to the reader — the sheet simply stays open, with the drawing still in it.
    private func render() -> Data? {
        let content = SketchCanvas(strokes: strokes, draft: nil)
            .frame(width: Self.paper.width, height: Self.paper.height)
            .background(.white)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.exportScale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        // From the `CGImage` rather than through `NSImage.tiffRepresentation`: the pixel dimensions of
        // the image are the answer here, and a rep built from the bitmap cannot lose the scale on the
        // way to the file.
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// The marks, on the paper.
///
/// One view, used twice: the sheet draws it live and `render` draws it into the PNG. That is the whole
/// reason it is a type of its own rather than a closure inside `Sketchpad` — a second drawing routine
/// for the export would be a second answer to "what does an arrow look like", and the reader would find
/// out about the disagreement only after sending it.
private struct SketchCanvas: View {
    let strokes: [Sketch.Stroke]
    let draft: Sketch.Draft?

    /// The ink. Black rather than the app's text colour, which would be white in dark mode — this is
    /// drawn on paper, not on the window.
    private static let ink = GraphicsContext.Shading.color(.black)
    private static let style = StrokeStyle(
        lineWidth: Sketch.ink,
        lineCap: .round,
        lineJoin: .round
    )

    var body: some View {
        Canvas { context, _ in
            for stroke in strokes { Self.draw(stroke, into: &context) }
            // The draft last, so the mark being made is drawn over the ones already there — the same
            // place it will be in once it is kept.
            if let draft { Self.draw(draft.stroke, into: &context) }
        }
    }

    /// One mark, as a path in the paper's coordinates.
    private static func draw(_ stroke: Sketch.Stroke, into context: inout GraphicsContext) {
        var path = Path()
        switch stroke {
        case let .freehand(points):
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        case let .line(from, to):
            path.move(to: from)
            path.addLine(to: to)
        case let .arrow(from, to):
            let (left, right) = Sketch.barbs(from: from, to: to)
            // The shaft and one arm as a single polyline, so that the corner where they meet is a
            // *join* — a rounded turn — rather than two round caps overlapping at the tip. The other
            // arm is a second segment: it only touches the shaft at that one point, and a path that
            // went back to the tip would draw the shaft's last stretch twice.
            path.move(to: from)
            path.addLine(to: to)
            path.addLine(to: left)
            path.move(to: to)
            path.addLine(to: right)
        case let .rectangle(rect):
            path.addRect(rect)
        case let .ellipse(rect):
            path.addEllipse(in: rect)
        }
        context.stroke(path, with: ink, style: style)
    }
}

/// One tool in the row, drawn as in hand or not.
private struct ToolButton: View {
    let tool: Sketch.Tool
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: Wei.Control.small, height: Wei.Control.small)
                .background(
                    selected ? AnyShapeStyle(Wei.Palette.accent) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: Wei.Radius.chip, style: .continuous)
                )
                .foregroundStyle(selected ? Wei.Palette.onAccent : Color.primary)
        }
        .buttonStyle(.plain)
        .help(tool.name)
        .accessibilityLabel(tool.name)
        // The fill says which tool is in hand to the eye; this says it to VoiceOver, which cannot see a
        // colour. A tool row with no selected state at all is a row VoiceOver reads as five identical
        // buttons.
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// What each tool is called, and the glyph it is drawn as.
///
/// In the view's file rather than in `WeiModel`, because SF Symbols are a fact about this platform's
/// drawing and not about what a drawing is — the model names the tools, and this says how they look.
extension Sketch.Tool {
    var name: String {
        switch self {
        case .pen: return "Pen"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
}
