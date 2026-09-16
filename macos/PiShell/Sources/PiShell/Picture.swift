import AppKit
import SwiftUI

import PiModel

/// A picture in an answer.
///
/// The bytes are read from whatever the target names — a path on this machine, the answer itself, or
/// the network — and drawn to fit the column. What the reader gets when that cannot happen is **the
/// alt text**, on its own line, in the place the picture would have been. That is what every picture
/// got before this view existed (see the note that used to be in `md/walk.mbt`), and it is still the
/// right answer, because a broken-image box is a thing to look at rather than a thing to act on.
///
/// Pictures are kept in `Pictures` by target, because the transcript rebuilds rows as they scroll: a
/// remote picture re-fetched on every pass would be a request per pass over the conversation.
struct Picture: View {
    /// The target exactly as the model wrote it. It is also what a read is cached on, and what the
    /// caption falls back to when there is no alt text — so `![](/tmp/x.png)` still names the file.
    let target: String
    let alt: String

    @State private var image: NSImage?
    @State private var failed = false

    /// One screenshot's worth of points. A picture taller than this is scaled to it, which is the
    /// difference between an answer that can be read and one that can only be scrolled.
    private static let tallest: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: Wei.Space.tight) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // Proportions kept, column width taken, height capped — and **never enlarged past
                    // the size it came in at.** `maxWidth` is a maximum rather than a target, so a
                    // wide picture still shrinks to the column while a small one is drawn at its own
                    // size instead of being blown up to it. Without that, a 1-pixel data URL would be
                    // a full-width blur, which is the opposite of what a picture is for.
                    .scaledToFit()
                    .frame(
                        maxWidth: image.size.width,
                        maxHeight: Self.tallest,
                        alignment: .leading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Wei.Radius.panel, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Wei.Radius.panel, style: .continuous)
                            .strokeBorder(Wei.Palette.separator, lineWidth: 1)
                    }
                    .help(target)
                if !alt.isEmpty {
                    caption(alt)
                }
            } else if failed {
                caption(alt.isEmpty ? target : alt)
            } else {
                // Neither yet: the read is in flight. A line's worth of room rather than a box the
                // size of a picture — this is one row of a conversation, not a page of its own.
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Keyed on the target rather than on appearing: a row can be reused for another answer as the
        // transcript changes, and the read has to follow the picture rather than the position.
        .task(id: target) { await load() }
    }

    /// Small text under a picture, or in its place. A link when the target is one the platform can
    /// open, because for a picture that did not arrive, going to look at it is what a reader can do.
    private func caption(_ text: String) -> some View {
        var out = AttributedString(text)
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            out.link = url
        }
        return Text(out)
            .font(Wei.Font.caption())
            .foregroundStyle(Wei.Palette.secondary)
            .textSelection(.enabled)
            .help(target)
    }

    private func load() async {
        guard let source = PictureSource.of(target) else {
            failed = true
            return
        }
        if let kept = Pictures.shared.ready(target) {
            image = kept
            return
        }
        // `bytes(of:)` is `nonisolated`, so this is off the main thread: the read of a screenshot and
        // the fetch of a URL both happen while the window goes on drawing.
        guard let data = await Pictures.bytes(of: source), let loaded = NSImage(data: data) else {
            failed = true
            return
        }
        Pictures.shared.keep(loaded, target: target)
        image = loaded
    }
}

/// The pictures already read, by target.
///
/// A cache rather than a re-read, and the reason is scrolling: a row that leaves the window and comes
/// back is built again, and its `task` runs again with it. Without this, every pass over a
/// conversation re-reads every picture in it.
///
/// A failure is *not* kept. The file may not have been written yet when the answer arrived, and the
/// side that writes it is the shell — so the next draw asks again, and the caption turns into the
/// picture when it appears.
@MainActor
final class Pictures {
    static let shared = Pictures()

    private var images: [String: NSImage] = [:]

    /// The picture for this target, if it has already been read.
    func ready(_ target: String) -> NSImage? {
        images[target]
    }

    func keep(_ image: NSImage, target: String) {
        images[target] = image
    }

    /// The target's bytes. Off the main actor by being `nonisolated`: the caller at the view is on the
    /// main actor, and this runs on the cooperative pool instead.
    nonisolated static func bytes(of source: PictureSource) async -> Data? {
        switch source {
        case let .file(path):
            return FileManager.default.contents(atPath: path)
        case let .inline(data):
            // Nothing can fail here: the bytes came with the answer.
            return data
        case let .remote(url):
            var request = URLRequest(url: url)
            // Long enough for a picture over a slow link, short enough that a request that never
            // answers becomes a caption rather than a spinner that stays forever.
            request.timeoutInterval = 20
            return try? await URLSession.shared.data(for: request).0
        }
    }
}
