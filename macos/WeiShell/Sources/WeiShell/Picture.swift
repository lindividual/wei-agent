import AppKit
import SwiftUI

import WeiModel

/// A picture in a message: one in an answer, or one the reader sent.
///
/// **Two ways in, and the difference is where the bytes come from.** A picture in an answer is named
/// by a target the model wrote — a path on this machine, the answer itself, or the network — and what
/// the reader gets when that cannot be read is **the alt text**, on its own line, in the place the
/// picture would have been. That is what every picture got before this file existed (see the note that
/// used to be in `md/walk.mbt`), and it is still the right answer, because a broken-image box is a
/// thing to look at rather than a thing to act on.
///
/// A picture the reader sent (`SentPicture` below) has nowhere to fail: the bytes arrived with the
/// message, in the base64 the log holds. So it has no caption and no spinner — and, unlike the other
/// direction, it is **right-aligned**, because it is part of the question.
///
/// Both are kept in `Pictures` by key, because the transcript rebuilds rows as they scroll: a picture
/// re-read on every pass would be a read per pass over the conversation.
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

/// The pictures the reader sent with a message: a row of thumbnails, and the one they opened.
///
/// **Thumbnails, because a message is not a gallery.** The first version drew every picture at its full
/// size in a column, which is right for one screenshot and wrong for four: three screenshots of a
/// window are taller than the whole transcript column, so the conversation the reader is having is
/// pushed off the screen by the pictures they already know the contents of. A row of thumbnails is
/// **one line of the conversation whatever the count**, and it is the same 44-point chip the composer
/// showed before the message was sent (see `AttachmentChip`), so the two ends of the same act look like
/// the same thing.
///
/// **And one of them can be opened, in place.** A thumbnail says *which* picture this is; it cannot say
/// what is in it, and a reader looking back at a message — or checking a screenshot they are about to
/// ask about again — needs to read it. Opening is the pattern this transcript already uses for a tool's
/// output (`ToolRow`'s "Show all"): the row grows where it stands, clicking again puts it back, so the
/// space is the reader's decision at the moment they want it rather than a cost paid on every message
/// for the rest of the conversation. A separate window or a full-screen viewer was the alternative, and
/// it is worse here for the reason the app has one window: the picture belongs to the message, and the
/// message is on screen.
///
/// What it deliberately does not have: no count, no caption, no file name. The reader attached these a
/// minute ago; the row is confirmation, and every word next to a picture that already says what it is
/// is one more thing between the reader and their own message.
struct SentPictures: View {
    let images: [RowImage]

    /// Which one is open, by position. One at a time: opening a second is the reader moving their
    /// attention, not asking for two pages of pictures.
    @State private var opened: Int?

    /// The thumbnail's size, and it is bigger than the composer's chip on purpose: 44 points is enough
    /// to recognise a picture you attached five seconds ago, and this row can be read months later
    /// when "which screenshot was that" is the actual question. 64 still puts ten of them on one line
    /// of the widest column.
    static let thumb: CGFloat = 64
    static let gap: CGFloat = 6

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.gap) {
            if let opened, opened < images.count {
                SentPicture(image: images[opened], opened: true)
            }
            ThumbnailRow(item: Self.thumb, spacing: Self.gap) {
                ForEach(images.indices, id: \.self) { index in
                    Button {
                        // Toggling rather than setting: the same thumbnail is both the way to open it
                        // and — since this is what the reader will click again — the way to put it
                        // back. A separate close button on a 64-point picture would be a second thing
                        // to find for the one action that has an obvious inverse.
                        opened = opened == index ? nil : index
                    } label: {
                        SentPicture(image: images[index], opened: false)
                            .overlay {
                                // The open one is marked, or a reader who has scrolled would be
                                // looking at a picture with no way to tell which thumbnail put it
                                // there.
                                RoundedRectangle(cornerRadius: Wei.Radius.chip, style: .continuous)
                                    .strokeBorder(
                                        Wei.Palette.accent,
                                        lineWidth: opened == index ? 2 : 0
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(opened == index ? "Close this picture" : "Open this picture")
                    .accessibilityLabel(
                        opened == index ? "Close this picture" : "Open this picture"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One of them: a thumbnail, or the same picture opened.
///
/// **The bytes come with the message.** A question's pictures are in the log as base64 — deliberately,
/// rather than as paths: one came from the screen a second before it was sent, another from the
/// clipboard, and the file behind either may be temp, may be gone, may never have existed here. So
/// there is nothing to read, nothing to fetch, and **nowhere to fail** — which is why this has no
/// caption and no spinner, and why it is not `Picture` with a different source.
struct SentPicture: View {
    let image: RowImage
    /// Whether this is the opened one rather than a thumbnail. The only difference is the size.
    let opened: Bool

    @State private var loaded: NSImage?

    /// The opened size, and it is the *thumbnail* that is the interesting number — see `SentPictures`
    /// for why the row is a row. These two are the cap the old full-size version had, kept because it
    /// was chosen against something real: an answer's picture may be a page tall, and a picture inside a
    /// message the reader already sent is being re-read rather than read for the first time.
    private static let tallest: CGFloat = 300
    private static let widest: CGFloat = 420

    var body: some View {
        Group {
            if let loaded {
                if opened {
                    Image(nsImage: loaded)
                        .resizable()
                        // Proportions kept and never enlarged, the same rule as an answer's picture: a
                        // small capture drawn at its own size rather than blown up into a blur.
                        .scaledToFit()
                        .frame(
                            maxWidth: min(loaded.size.width, Self.widest),
                            maxHeight: Self.tallest,
                            alignment: .trailing
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: Wei.Radius.panel, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Wei.Radius.panel, style: .continuous)
                                .strokeBorder(Wei.Palette.separator, lineWidth: 1)
                        }
                } else {
                    // A thumbnail: square, and **filled rather than fitted**. `scaledToFill` crops a
                    // screenshot's edges, which is the right trade at this size — what the reader is
                    // recognising is the middle of the picture (a window, a dialog, a face), and the
                    // alternative is a 64-point box with a 40-point picture floating in it.
                    Image(nsImage: loaded)
                        .resizable()
                        .scaledToFill()
                        .frame(width: SentPictures.thumb, height: SentPictures.thumb)
                        .clipShape(RoundedRectangle(cornerRadius: Wei.Radius.chip, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Wei.Radius.chip, style: .continuous)
                                .strokeBorder(Wei.Palette.separator, lineWidth: 1)
                        }
                }
            } else {
                // **Something has to be here, or nothing below it ever runs.** This was `Group {
                // if let loaded { … } }` with the `task` attached, and it drew nothing at all: SwiftUI
                // attaches `.task` to the view the modifier is on, and a branch that produces *no*
                // view has nothing to attach to — so `load()` was never called, `loaded` stayed nil,
                // and the picture never appeared. An empty `Color` with no size costs no layout and is
                // a view, which is the whole of the difference. (An answer's picture never hit this:
                // `Picture` draws a spinner while its read is in flight, so its branch is never empty.)
                Color.clear
                    .frame(
                        width: opened ? 0 : SentPictures.thumb,
                        height: opened ? 0 : SentPictures.thumb
                    )
            }
        }
        // Keyed on the *bytes* rather than on appearing, for the same reason `Picture` is keyed on its
        // target: a row can be reused for another message as the transcript changes, and the key is
        // what keeps the previous message's screenshot from being drawn in this one.
        .task(id: image.key) { await load() }
    }

    private func load() async {
        let key = image.key
        if let kept = Pictures.shared.ready(key) {
            loaded = kept
            return
        }
        guard let data = image.bytes, let decoded = NSImage(data: data) else { return }
        Pictures.shared.keep(decoded, target: key)
        loaded = decoded
    }
}

/// The pictures already read, by key.
///
/// A cache rather than a re-read, and the reason is scrolling: a row that leaves the window and comes
/// back is built again, and its `task` runs again with it. Without this, every pass over a
/// conversation re-reads every picture in it.
///
/// "Read" is doing some work in that name: an answer's picture is read from a path or fetched over the
/// network, and a *sent* picture is only decoded — from bytes that are already in memory, because the
/// row holds them. One cache rather than two because the reason is the same (a redraw must not repeat
/// the work) and because the decode of base64 is the expensive half of that work anyway. What keeps
/// the two from colliding is the key: a target is a path or a URL, and a sent picture's key is
/// `row-image:…`.
///
/// A failure is *not* kept. The file may not have been written yet when the answer arrived, and the
/// side that writes it is the shell — so the next draw asks again, and the caption turns into the
/// picture when it appears.
@MainActor
final class Pictures {
    static let shared = Pictures()

    private var images: [String: NSImage] = [:]

    /// The picture for this key, if it has already been read.
    func ready(_ key: String) -> NSImage? {
        images[key]
    }

    func keep(_ image: NSImage, target key: String) {
        images[key] = image
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

/// A row of thumbnails that wraps, aligned to the trailing edge.
///
/// A `Layout` rather than an `HStack`, because an `HStack` does not wrap: past the width it squeezes
/// its children instead, and a thumbnail squeezed to nothing is a picture that **disappears** — the
/// reader's own screenshot, gone, with no error and nothing to click. Wrapping is the failure that has
/// to be impossible here, which is why the rule that decides the lines is out of this file and tested
/// (`WeiModel.PictureFlow`).
///
/// Trailing-aligned because a question is: these sit above the reader's own words, at the right edge of
/// the column, and a block of thumbnails hugging the left edge would read as part of the answer below
/// them.
private struct ThumbnailRow: Layout {
    let item: CGFloat
    let spacing: CGFloat

    private func lines(_ count: Int, _ width: CGFloat) -> [Range<Int>] {
        PictureFlow.rows(count: count, available: width, item: item, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews.count, width(proposal, subviews))
        return CGSize(
            width: proposal.width ?? 0,
            height: PictureFlow.height(lines: lines.count, item: item, spacing: spacing)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let lines = lines(subviews.count, width(proposal, subviews))
        for (row, range) in lines.enumerated() {
            let y = bounds.minY + CGFloat(row) * (item + spacing)
            // From the trailing edge backwards, so the last thumbnail of every line is flush with the
            // bubble below it.
            var x = bounds.maxX - CGFloat(range.count) * item - CGFloat(range.count - 1) * spacing
            for index in range {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item, height: item)
                )
                x += item + spacing
            }
        }
    }

    /// The width there is to lay out in.
    ///
    /// The proposal's own width, with the children's sizes as the fallback: a `Layout` is also asked to
    /// size itself when the parent has no opinion (a proposal of `nil`), and "everything on one line" is
    /// the honest answer there — the parent will constrain it afterwards.
    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        if let width = proposal.width { return width }
        let count = CGFloat(subviews.count)
        return count * item + max(0, count - 1) * spacing
    }
}
