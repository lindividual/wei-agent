import AppKit
import SwiftUI
import UniformTypeIdentifiers

import WeiKit
import WeiModel

/// The card's outline, in one place.
///
/// The fill under the glass, the glass itself and the ring drawn while a file is dragged over it all
/// describe the same rectangle, and they were three separate `RoundedRectangle(cornerRadius: 24)` literals
/// — which is how a card ends up with a fill that does not quite meet its ring. `Wei.Radius.surface` is the
/// token, documented as "the floating composer, the biggest thing in the window": the literal said 24 and
/// the token says 28, and the token is the one that was written down as the decision.
struct CardShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: Wei.Radius.surface - inset,
            style: .continuous
        ).path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> CardShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// The surface the composer floats on.
///
/// A name for `Wei.surface` rather than an implementation, because the search field needs the same surface
/// in a capsule and two implementations of "the material this app floats on" is exactly the drift a design
/// system exists to prevent.
extension View {
    func composerSurface(cornerRadius: CGFloat) -> some View {
        weiSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// What the reader types in: a card that floats over the transcript, and a line of figures beneath it.
///
/// The card holds everything that belongs to the message being written — the pictures attached to it,
/// the text, and the three controls a reader reaches for while writing one: attach a file, choose the
/// model that will answer, and send. They are inside the card rather than around it because they are
/// all about *this* message, and a control that changes what will be sent belongs next to the thing
/// that will be sent.
///
/// The line beneath is the whole of the accounting. It is outside the card because it is about the
/// session rather than about the draft: what the last question cost, how full the context is, and what
/// the conversation has spent altogether. A reader deciding whether to ask another question is the one
/// who reads it, and they are looking at the answer, not at the box.
struct Composer: View {
    @ObservedObject var client: ShellClient
    /// The draft lives **here**, not in the window above.
    ///
    /// A `@Binding` handed down from `RootView` was the shape of a message that never left the app: the
    /// `onKeyPress` handler is installed by an earlier `body`, so a closure handed down captures the
    /// `draft` of *that* body — it read an empty string, cleared a binding that was no longer on the
    /// chain, and the field kept its text. Owning the state is what makes the send path correct by
    /// construction, and it is why nothing above this view needs to see the draft at all (ADR-0007).
    @State private var draft = ""
    let enabled: Bool
    /// Called after a message has gone out. It is a closure because the caller owns the scroll
    /// behaviour, and it is safe to be a closure because it carries no state: what it does is tell a
    /// reference type that the reader asked something.
    let onSent: () -> Void
    let onStop: () -> Void

    @FocusState private var editorFocused: Bool
    @State private var pickingFiles = false
    @State private var showingUsage = false
    /// Whether a drag is hovering over the card. Drawn as a highlight rather than tracked as a fact:
    /// the drop is the only thing that changes anything.
    @State private var dropping = false

    private var canSend: Bool {
        enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Above the card rather than below it: the list grows upward out of the field, and it
            // never covers the text being written or the send button.
            if !skillSuggestions.isEmpty {
                SkillSuggestions(skills: skillSuggestions) { name in
                    draft = "/skill:\(name) "
                    editorFocused = true
                }
            }
            card
            StatusLine(
                client: client,
                showingUsage: $showingUsage
            )
        }
        // One column for the card and the line under it, capped and centred. The cap is what makes
        // this read as a card floating over the conversation rather than a bar across the bottom of
        // the window: the same arrangement the web UI uses (its composer is `clamp(680, 64%, 920)`
        // wide, centred), and the reading width it produces is the reason for the number.
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        // Room above for the fade below to work in, and a smaller gap under it so the card sits
        // close to the window's edge — the elevation, not the spacing, is what separates it.
        .padding(.top, Wei.Space.loose)
        .padding(.bottom, Wei.Space.cozy)
        // The transcript fades out as it goes under the card instead of being cut off by it. The web UI
        // puts the same gradient on its chat scroller, for the same reason: a hard edge under a floating
        // card reads as the end of the conversation.
        //
        // **One gradient over the whole frame, and it is doing two jobs.** At the top it is nearly clear,
        // so the conversation is visible right up to the card's edge and *through* its upper part — blurred
        // by the glass, which is what a floating card is supposed to look like. By the bottom it is opaque,
        // which is what keeps the composer's own figures (the context ring, the cost) off the transcript
        // text behind them.
        //
        // This was briefly replaced by an opaque fill plus a short top ramp, on the reading that a line of
        // the transcript was legible inside the card. It was not: the thing measured at mid-grey through the
        // card was a *table border* (its own tone is ~150 against a glyph's ~40), and the card had been
        // masking text correctly all along. The opaque fill then hid everything the reader liked about this
        // rectangle — "文字滚动的时候，在 composer 底下也会透出来" — and had to come out again.
        .background(
            LinearGradient(
                colors: [.clear, Wei.Palette.window],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // The composer owns the keyboard: a window whose only text field is not focused is a window
        // where the first thing a reader does is click. Focus follows the editor being usable, so a
        // turn that ends hands the keyboard straight back.
        .onAppear { editorFocused = enabled }
        .onChange(of: enabled) { _, usable in editorFocused = usable }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Attachments(attachments: client.conversation.attachments) { path in
                client.detach(path)
            }
            editor
            toolbar
        }
        .padding(.horizontal, Wei.Space.regular)
        .padding(.vertical, Wei.Space.regular)
        .composerSurface(cornerRadius: Wei.Radius.surface)
        // Dropping a file on the card attaches it. The card is the thing on screen that is about the
        // message being written, so it is the thing that should accept something for it.
        //
        // Only the shape of the gesture is decided here; whether a file is an image at all is the
        // shell's answer, because the shell is the side that can read the bytes. Filtering by file
        // extension here would refuse a screenshot saved without one — the case that motivates
        // sniffing in the first place.
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { client.attach(url.path) }
            return !urls.isEmpty
        } isTargeted: { targeted in
            dropping = targeted
        }
        .overlay(
            CardShape()
                .strokeBorder(Wei.Palette.accent, lineWidth: dropping ? 2 : 0)
                .opacity(dropping ? 1 : 0)
        )
        // Pasting an image attaches it; pasting anything else goes where it would have gone.
        //
        // `onPasteCommand(of:)` is only offered when the pasteboard can supply the named types, which
        // is what keeps this from swallowing a ⌘V of text into the field. What arrives is bytes, so
        // they are written to a file first: an attachment travels as a path, and the shell is the side
        // that reads it — see `attachTemporary`.
        .onPasteCommand(of: [.image]) { _ in
            if let path = PastedImage.write() { client.attachTemporary(path) }
        }
        .fileImporter(
            isPresented: $pickingFiles,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            // A cancelled picker is not a failure, and an unreadable file is the shell's to explain:
            // it is the side that sniffs the bytes. Both are therefore dropped rather than reported
            // here, where all that is known is that a panel closed.
            guard case let .success(urls) = result else { return }
            for url in urls { client.attach(url.path) }
        }
    }

    private var editor: some View {
        TextField("Ask something…", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .lineLimit(2...14)
            // A floor rather than a fixed height: the field is two lines tall when it is empty, which
            // is what gives the card the air a floating surface needs, and it grows from there.
            .frame(minHeight: 34, alignment: .topLeading)
            .focused($editorFocused)
            .disabled(!enabled)
            // Return sends; ⇧Return starts a line. Both are decided here rather than inherited,
            // because neither of the platform's own answers is the one this box wants — measured:
            // Return in a field that can grow is a newline, and ⇧Return is a *submit*.
            //
            // Taking Return is only safe because an input method gets it back. While one is
            // composing, Return is the keystroke that commits the candidates, and a handler that eats
            // it discards what the reader typed and sends nothing at all — the field empties, the
            // button goes grey, and the message never leaves. That is `submit()`'s first guard, and it
            // is the whole of the reported bug.
            .onKeyPress(.return, phases: .down) { press in
                // The event's own modifiers, not `NSEvent.modifierFlags`: that reads the *current*
                // hardware state rather than the keystroke being handled, so a synthetic or replayed
                // event — and a real one under a stuck modifier — would be judged by something other
                // than itself.
                if press.modifiers.contains(.shift) {
                    // A newline, inserted rather than passed on: the platform reads ⇧Return as a
                    // submit for this field, so handing it over sends the message instead of adding a
                    // line to it. The caret is not consulted — the newline lands at the end — which
                    // is where it goes for a message being written in order.
                    draft += "\n"
                    return .handled
                }
                return submit() ? .handled : .ignored
            }
            // The window's own submit gesture as well, because it is the one the menu bar and every
            // other command in this app use — and it goes through the same guard, since the platform
            // can read a keystroke as a submit that this handler deliberately did not take.
            .onSubmit { submit() }
            .padding(.horizontal, 2)
            .padding(.top, 2)
    }

    /// The skills a `/skill:` at the start of the draft is offering, filtered by what has been typed.
    ///
    /// Read from the settings snapshot rather than asked for: the shell already sends every skill it
    /// can see, with whether each one is switched on, so the composer needs no new wire and cannot
    /// disagree with the panel about what exists.
    ///
    /// Only the enabled ones. A switched-off skill is not something the reader can invoke — the
    /// expansion refuses it and the model is never told about it — so offering it would be offering a
    /// command that does nothing.
    private var skillSuggestions: [SkillEntry] {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/skill:") else { return [] }
        let typed = String(trimmed.dropFirst("/skill:".count))
        // A space ends the name: `/skill:moonbit do X` is a finished command with an argument, not a
        // prefix still being typed.
        guard !typed.contains(" ") else { return [] }
        let skills = (client.settings?.skills ?? []).filter(\.enabled)
        let matches = typed.isEmpty
            ? skills
            : skills.filter { $0.name.lowercased().hasPrefix(typed.lowercased()) }
        // A single exact match is not a suggestion, it is what has already been typed.
        if matches.count == 1, matches[0].name.lowercased() == typed.lowercased() { return [] }
        return matches
    }

    /// Send what has been typed, if there is anything and no input method is partway through a word.
    ///
    /// `false` means the keystroke was not a send and belongs to somebody else — the platform, or the
    /// input method — which is what the caller turns into `.ignored`.
    ///
    /// The composing check is the one that is easy to leave out and impossible to notice in English:
    /// while an input method is composing, its text is in the field editor and *not* in the binding,
    /// so `draft` is empty and the reader's typing is invisible from here. A Return taken at that
    /// moment is a Return the IME never sees, and the composition is thrown away.
    @discardableResult
    private func submit() -> Bool {
        // An input method gets Return back, always. See the handler's note.
        if composing { return false }
        // Nothing typed is not a message. It is also the state a composition leaves behind when its
        // text has not reached this binding yet, which is the second reason this guard is not merely
        // politeness.
        // Read once, clear, then send: the order matters, because sending can re-enter this view
        // (the shell answers, the transcript grows, the body is rebuilt) and a draft cleared after
        // that would clear text the reader had started typing in the meantime.
        let text = draft
        draft = ""
        // Sent from here rather than by a closure passed in from above, and that is the whole of the
        // fix for a message that never left the app. A closure is a captured value: the one that
        // arrived here was built by an earlier body — when the draft was still empty — so it read an
        // empty string and wrote the clear to a binding that had gone nowhere. Measured: the handler
        // fired, `ShellClient.send` was called, and it was handed `""`. This view's own binding is live
        // by construction, which is what makes the difference.
        client.send(text)
        onSent()
        return true
    }

    /// Whether an input method is partway through a word in this field.
    ///
    /// Asked of the field editor rather than of anything this view holds, because the composing text
    /// lives there: `hasMarkedText` is the text-input system's own answer to "is a composition in
    /// progress", the same answer for every input method and every script.
    ///
    /// One test, and deliberately not a second guess of the same thing. Comparing the editor's string
    /// against `draft` looks like a stronger signal and is a wrong one: the binding catches up a
    /// keystroke behind the field, so the first character typed is exactly the state "the editor has
    /// text and the binding does not" — and a Return ignored there is a message that goes nowhere,
    /// which is the bug this guard exists to prevent, in a new place.
    private var composing: Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                pickingFiles = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help("Attach an image")

            ModelPicker(client: client, enabled: enabled)

            Spacer(minLength: 8)

            if client.conversation.running {
                Button("Stop", action: onStop)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // The button goes through the same submit as the key, so the two cannot come to different
            // conclusions about whether this is a send.
            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(canSend ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                    .foregroundStyle(canSend ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
    }
}

/// The image on the clipboard, written somewhere the shell can read it.
///
/// A file because that is how an attachment travels: the shell reads paths, sniffs the bytes and
/// decides whether it is an image at all. Written as PNG whatever the clipboard held — a screenshot
/// arrives as TIFF, and a TIFF the model cannot be shown is not an improvement on a re-encode that
/// costs nothing visible.
///
/// The name carries a UUID, so two pastes of the same screenshot are two files rather than one
/// attachment the reader did not ask to merge. The shell deletes it once it has the bytes.
///
/// A type rather than a function because two paths use it: the ⌘V gesture on the card, and the menu
/// item — which exists because the gesture is the one part of this that cannot be relied on to be
/// reachable: a text field claims ⌘V for itself, so the reader is given a way that does not depend on
/// who wins that argument.
enum PastedImage {
    static func write() -> String? {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let image = NSImage(data: data),
              let png = image.pngData else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wei-pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("paste-\(UUID().uuidString).png")
        do {
            try png.write(to: file)
        } catch {
            return nil
        }
        return file.path
    }

    /// Whether there is anything to attach, for the menu item's enabled state.
    static var available: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }
}

/// `NSImage` has no `pngData`, so the re-encode goes through a bitmap representation — which is also
/// where the scale is settled: a TIFF clipboard item carries the screen's scale, and a PNG written
/// from a representation that keeps it is twice the pixels for no more information.
extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// The skills a `/skill:` prefix can name, as a short menu above the composer.
///
/// A list rather than a popover with a selection model: the reader is mid-sentence, so the cheapest
/// thing that works is a row per name they can click, and typing the name themselves is still there
/// for anyone who knows it. Capped, because a machine with thirty skills would otherwise push the
/// conversation off the screen while somebody types a slash.
private struct SkillSuggestions: View {
    let skills: [SkillEntry]
    let choose: (String) -> Void

    private static let limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(skills.prefix(Self.limit)) { skill in
                Button {
                    choose(skill.name)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("/skill:\(skill.name)")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        Text(skill.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if skills.count > Self.limit {
                Text("\(skills.count - Self.limit) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// The pictures attached to the message being written, as thumbnails.
///
/// A row that is absent when there is nothing attached rather than an empty state: a reader who has
/// not attached anything does not need to be told about the feature, and the space it would take is
/// the space the text field wants.
private struct Attachments: View {
    let attachments: [Attachment]
    let onRemove: (String) -> Void

    var body: some View {
        if !attachments.isEmpty {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) { onRemove(attachment.path) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
        }
    }
}

/// One thumbnail, with the way to take it back off.
private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        preview
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                // Drawn only under the pointer: the common case is a reader who attached the right
                // thing, and a row of permanent close buttons is a row of things to avoid clicking.
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }
            .onHover { hovering = $0 }
            .help(attachment.path)
    }

    /// The picture, if the bytes still decode. Decoding from the attachment's own bytes rather than
    /// from the file means the thumbnail is what will be sent, and a file deleted since it was picked
    /// still shows what it was.
    @ViewBuilder private var preview: some View {
        if let data = Data(base64Encoded: attachment.data), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

/// The model that will answer the next question.
///
/// A menu rather than a picker, and inside the composer rather than in a settings panel. The model is
/// not a preference: it decides what the answer costs and whether the picture just attached can be
/// seen at all, and both of those are decisions about the message being written. A reader who picked
/// a screenshot and then has to leave the window to ask whether the model can see it would attach it,
/// switch, and come back to find the reason it was needed.
private struct ModelPicker: View {
    @ObservedObject var client: ShellClient
    let enabled: Bool

    var body: some View {
        Menu {
            ForEach(client.catalog.items) { model in
                Button {
                    client.setModel(model.id)
                } label: {
                    // The vision note is in the entry that would be wrong to pick, which is where it
                    // is read: "cannot be shown images" next to one model is a sentence a reader acts
                    // on, and a tooltip they have to go looking for is not.
                    Text(model.vision ? model.label : "\(model.label) — no images")
                }
                .disabled(!enabled || model.id == client.catalog.current)
            }
            if !client.conversation.attachments.isEmpty {
                Divider()
                // Said in the menu rather than only at attach time: this is where a reader goes to
                // fix it, so this is where the reason belongs.
                Text(
                    client.conversation.canSendImages
                        ? "This model can be shown images"
                        : "Attached images will be replaced by a note"
                )
            }
        } label: {
            HStack(spacing: 3) {
                Text(client.catalog.currentLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled || client.catalog.items.isEmpty)
        .help("Model for the next turn")
    }
}

/// What a turn costs and how full the context is, under the composer.
///
/// Two figures and two shapes, because they answer different questions. The left is a sentence: what
/// the last question cost, or what the agent is doing right now. The right is a control: the context
/// meter, which opens the whole breakdown — the session's token totals, its cost split by category,
/// and the cache hit share, which is the figure that explains why one turn was cheap and the next was
/// not.
private struct StatusLine: View {
    @ObservedObject var client: ShellClient
    @Binding var showingUsage: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let usage = client.conversation.usage {
                ContextMeter(usage: usage)
                Button {
                    client.refreshUsage()
                    showingUsage = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "dollarsign.circle").font(.system(size: 10))
                        Text(usage.cost)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingUsage, arrowEdge: .bottom) {
                    UsagePanel(usage: usage)
                }
                .help("Token usage and cost")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        // The figures are the thing that changes most often while a turn runs, so this line is what
        // makes the window feel alive. Animating the width rather than replacing the text keeps the
        // reader's eye on the answer instead of on the numbers moving.
        .animation(.default, value: client.conversation.usage)
    }

    /// The left half: what is happening, or what just happened.
    ///
    /// The status first, because while a turn runs it is the only thing that changes and a reader
    /// watching a long turn is watching it — and because every other thing the status carries (which
    /// model, which tools, stopping, failed) is something the shell just said and is the most recent
    /// fact there is. The shell clears it when a turn ends, and that is what makes room for the
    /// figures underneath.
    ///
    /// The last turn's own numbers rather than the session totals: the line under a composer is read
    /// by someone deciding whether to ask another question, and what the last one cost is the number
    /// that answers that.
    private var summary: String {
        let status = client.conversation.status
        if !status.isEmpty { return status }
        // Why nothing can be sent, if that is the case, and before the figures: a turn's cost is
        // interesting and a missing key is a wall, and this is where a reader looks on their way to
        // typing. It used to live in the window's subtitle, which is now the project and its count —
        // and a machine with no key must not be a machine that says nothing about it.
        if let blocked = client.blocked { return blocked }
        guard let last = client.conversation.usage?.last else { return "" }
        var parts: [String] = []
        parts.append("\(last.modelCalls) model call\(last.modelCalls == 1 ? "" : "s")")
        if last.toolCalls > 0 {
            parts.append("\(last.toolCalls) tool call\(last.toolCalls == 1 ? "" : "s")")
        }
        parts.append("\(TokenText.compact(last.input)) in / \(TokenText.compact(last.output)) out")
        return parts.joined(separator: " · ")
    }
}

/// How full the context is, as a ring.
///
/// A ring rather than a bar because it has to live in the same row as the cost and the ring's
/// reading — "how close to full" — is one a circle answers at a glance. Absent before anything has
/// been sent: an empty ring is a claim that the context is empty, and a session that has asked
/// nothing has no context to report.
private struct ContextMeter: View {
    let usage: Usage

    var body: some View {
        if let fill = usage.contextFill {
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fill)
                        .stroke(tint(fill), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                Text("\(Int((fill * 100).rounded()))%")
                    .monospacedDigit()
            }
            .help(
                "\(TokenText.exact(usage.prompt)) of \(TokenText.compact(usage.window)) context tokens"
            )
        }
    }

    /// Amber well before full, because the interesting moment is the compaction that happens when it
    /// runs out — and by then the reader can no longer see it coming.
    private func tint(_ fill: Double) -> Color {
        if fill >= 0.9 { return .red }
        if fill >= 0.7 { return .orange }
        return .accentColor
    }
}

/// The whole of the accounting, for a reader who opened the line under the composer.
private struct UsagePanel: View {
    let usage: Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This session")
                .font(.system(size: 11, weight: .semibold))
            rows
            Divider()
            HStack {
                Text("Total").fontWeight(.semibold)
                Spacer()
                Text(usage.cost).fontWeight(.semibold).monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(minWidth: 230)
    }

    @ViewBuilder private var rows: some View {
        if let last = usage.last {
            section("Last turn")
            row("model calls", "\(last.modelCalls)")
            if last.toolCalls > 0 { row("tool calls", "\(last.toolCalls)") }
            row("tokens", TokenText.exact(last.total))
            row("cost", last.cost)
            section("Session")
        }
        row("replies", "\(usage.turns)")
        row("input", TokenText.exact(usage.input))
        if usage.cacheRead > 0 {
            let share = usage.cacheHit.map { " (\($0)% cached)" } ?? ""
            row("cached input", TokenText.exact(usage.cacheRead) + share)
        }
        if usage.cacheWrite > 0 {
            row("cache writes", TokenText.exact(usage.cacheWrite))
        }
        row("output", TokenText.exact(usage.output))
        row("total tokens", TokenText.exact(usage.total))
        row("context", "\(TokenText.compact(usage.prompt)) / \(TokenText.compact(usage.window))")
        Divider()
        row("input cost", usage.costInput)
        row("output cost", usage.costOutput)
        if usage.cacheRead > 0 || usage.cacheWrite > 0 {
            row("cache cost", sum(usage.costCacheRead, usage.costCacheWrite))
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
        }
    }

    /// Two cost strings added. The shell formats each part on its own — that is where the decimal
    /// rule lives — so a sum here has to parse them back, and a part that does not parse is dropped
    /// rather than printed as `0`.
    private func sum(_ a: String, _ b: String) -> String {
        let total = (Double(a) ?? 0) + (Double(b) ?? 0)
        return String(format: total < 0.1 ? "%.6f" : "%.4f", total)
    }
}
