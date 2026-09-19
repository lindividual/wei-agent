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
    @State private var sketching = false
    @State private var showingUsage = false

    /// What dictation is doing, as rules (`WeiModel.Dictation`): the transitions, what each ending does
    /// to the text already in the field, and why it cannot start when it cannot. The view's part is to
    /// turn that into three glyphs and to put the text where the rules say.
    @State private var dictation = Dictation()
    /// The microphone. Held here rather than owned by a task because a sentence outlives many bodies.
    @State private var capture = VoiceCapture()
    /// The field editor's side of it: showing a sentence as a composition and settling it into the
    /// binding. A separate type because it is all facts about a text input client, none about a composer.
    @State private var field = DictationField()
    /// How far along a model download is, or `nil` when nothing is being downloaded. A number rather
    /// than a flag because a download has a length, and a control that says "working…" for two minutes
    /// is a control that looks hung.
    @State private var installing: Double?
    /// The language to dictate in, by locale identifier. Empty means "whatever the system is set to",
    /// which is the answer for everybody who never thinks about it.
    @AppStorage("voiceLanguage") private var voiceLanguage = ""
    /// Whether the send that is waiting on a settling sentence should go out when it settles.
    ///
    /// A flag rather than a pending closure: what happens afterwards is `submit()` again, and the state it
    /// reads (the draft) is only correct at that moment.
    @State private var sendWhenSettled = false
    /// Whether a drag is hovering over the card. Drawn as a highlight rather than tracked as a fact:
    /// the drop is the only thing that changes anything.
    @State private var dropping = false

    /// Whether there is a message to send.
    ///
    /// **Enabled while dictating, and that is a reversal.** The first version disabled it, on the reasoning
    /// that a send during a sentence would post the text from *before* the reader started talking. True —
    /// and it made the button a gate the reader had to understand: they finished speaking, watched the words
    /// sit in the box, and found the arrow grey with nothing saying why. What resolves it is not a rule about
    /// the button but about the click: **Send ends the dictation first**, waits for the sentence to settle,
    /// and then sends what is in the box. `draft` is still the thing being checked, so a sentence that has
    /// not settled yet leaves the arrow disabled — there is genuinely nothing to send until it does.
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
        // The sketch sheet. On the card rather than on the pencil button, because it is about *this*
        // message: the picture it produces is an attachment of the draft being written, and a sheet
        // hung on the button would be one more thing that has to be found again after a redraw.
        .sheet(isPresented: $sketching) {
            Sketchpad { png in
                // The same path the clipboard takes: a file this side made, which the shell reads,
                // sniffs and deletes. Nothing about the sketch travels except PNG bytes, so the sheet
                // and the paste cannot come to different conclusions about what an attachment is.
                if let path = TemporaryImage.write(png, named: "sketch") {
                    client.attachTemporary(path)
                }
            }
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
                // **A sentence being spoken owns Return**, because the only thing this key can mean while a
                // reader is still talking is "I am done". Handled here rather than passed on: left to the
                // platform, Return settles the composition early and the rest of the sentence then has
                // nothing left to replace.
                //
                // What "done" does next is the same thing Send does, deliberately — the key and the button are
                // one gesture, and having Return mean "finish" while the arrow meant "finish and send" would
                // be two answers to one question (see `submit`). With nothing settled yet there is nothing to
                // send, and then it only finishes: the sentence stays in the box and the next Return sends it.
                if dictation.isActive {
                    if canSend { _ = submit() } else { stopDictation() }
                    return .handled
                }
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
            // Escape takes the sentence back out. Dictation is the only thing this key can be about in
            // this field — there is no other operation in progress to cancel — and it is ignored
            // otherwise, so the platform keeps whatever else it does with Escape.
            .onKeyPress(.escape) {
                guard dictation.isActive else { return .ignored }
                cancelDictation()
                return .handled
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
        // **Dictation is finished before anything is sent, and the send is re-issued afterwards.** Pressing
        // Send while a sentence is being spoken used to do nothing at all — the draft did not have that
        // sentence in it yet — which left the reader with a text box full of words and an arrow that refused.
        // Stopping the microphone and waiting for the sentence to settle (or for the watchdog, two seconds)
        // means the box holds everything they said when the send finally happens.
        //
        // Guarded on there being something to send, so a Send pressed on an empty box does not start a
        // two-second wait for nothing.
        if dictation.isActive, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendWhenSettled = true
            finishDictationThenSend()
            return true
        }
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

            // Beside the attach button, because it is the same decision — a picture for this message —
            // taken the other way round: the reader has no file, so this is where one can be made.
            Button {
                sketching = true
            } label: {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help("Sketch an idea")

            dictate

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

    // ── dictation ─────────────────────────────────────────────────────────

    /// The microphone, as one control with one meaning per state.
    ///
    /// **One button, and its action is whatever the state needs.** The alternative — a menu, or a second
    /// button that only appears when something is wrong — was rejected because every state here has
    /// exactly one useful thing to do next, and a button that *does* it is easier to find than a menu
    /// that lists it. What the button will do is in the tooltip, in words, because a glyph cannot say
    /// "the model for Chinese is not on this Mac yet".
    ///
    /// The states and the glyphs:
    ///
    /// | state | glyph | pressing it |
    /// |---|---|---|
    /// | idle | `mic` | start listening |
    /// | listening | `mic.fill` on the highlight wash | stop, and settle the sentence |
    /// | stopping | `mic.fill` | nothing (the last result is on its way) |
    /// | downloading a model | a small progress ring | nothing |
    /// | microphone refused | `mic.slash` | open the privacy pane that can grant it |
    /// | model missing | `arrow.down.circle` | download it |
    /// | anything else | `mic.slash` | try again |
    ///
    /// The listening state is drawn on `highlightWash` rather than in a red dot: this app has one accent
    /// and one highlight, and a recording indicator is a *background*, which is the job the highlight hue
    /// was chosen for. The real feedback is the text appearing in the field, which is where the reader is
    /// looking anyway.
    private var dictate: some View {
        Button {
            dictatePressed()
        } label: {
            Group {
                if let installing {
                    ProgressView(value: installing)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: dictateGlyph)
                        .font(.system(size: 11, weight: dictation.isListening ? .bold : .semibold))
                        // **Motion, because a colour change is not a state.** The background alone was the
                        // only sign that the microphone was open, and a filled circle behind a glyph is easy
                        // to read as "this button is selected" rather than "this is happening now". The pulse
                        // is the platform's own vocabulary for exactly this and costs nothing to keep true:
                        // it runs while `isListening` and stops on its own when that stops being true.
                        .symbolEffect(.pulse, options: .repeating, isActive: dictation.isListening)
                        .frame(width: 24, height: 24)
                        .background(
                            dictation.isListening
                                ? AnyShapeStyle(Wei.Palette.highlightWash) : AnyShapeStyle(.quaternary),
                            in: Circle()
                        )
                        .overlay(
                            // A ring, only while listening: the same shape at the same size, so nothing
                            // moves — it is the outline appearing that reads as "on air".
                            Circle()
                                .strokeBorder(Wei.Palette.accent, lineWidth: dictation.isListening ? 1.5 : 0)
                                .opacity(dictation.isListening ? 1 : 0)
                        )
                        .animation(.easeInOut(duration: 0.2), value: dictation.phase)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || dictation.phase == .stopping || installing != nil)
        .help(dictateHelp)
        .accessibilityLabel(dictateHelp)
    }

    private var dictateGlyph: String {
        if dictation.isActive { return "mic.fill" }
        switch dictation.trouble {
        case .none: return "mic"
        case .microphoneNotPermitted, .languageUnsupported, .failed: return "mic.slash"
        case .modelMissing: return "arrow.down.circle"
        }
    }

    /// What the button means right now, in words — used as both the tooltip and the accessibility label,
    /// so the two cannot describe different states.
    private var dictateHelp: String {
        if installing != nil { return "Downloading the voice model…" }
        switch dictation.phase {
        case .starting: return "Starting to listen…"
        case .listening: return "Finish dictating (↩)"
        case .stopping: return "Finishing…"
        case .idle: return "Dictate (⌘D)"
        case let .unavailable(trouble):
            switch trouble {
            case .microphoneNotPermitted:
                return "Dictation needs the microphone — click to open Privacy settings"
            case let .modelMissing(locale):
                return "Download the voice model for \(languageName(locale))"
            case let .languageUnsupported(locale):
                return "\(languageName(locale)) cannot be dictated on this Mac"
            case let .failed(message):
                return "Dictation stopped: \(message). Click to try again."
            }
        }
    }

    /// A language, in the platform's own words for it.
    private func languageName(_ identifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier)
            ?? identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// What pressing the microphone means, given where dictation is.
    private func dictatePressed() {
        switch dictation.phase {
        case .starting, .listening:
            // Starting as well as listening: the model is still loading, and pressing again means "never
            // mind" — which is the same thing as stopping before anything was heard.
            stopDictation()
        case .stopping:
            break
        case .idle:
            beginDictation()
        case let .unavailable(trouble):
            mend(trouble)
        }
    }

    /// What can be done about it — which is different for each of them, and is the reason a failed state
    /// is a button rather than a message.
    private func mend(_ trouble: DictationTrouble) {
        switch trouble {
        case .microphoneNotPermitted:
            // The app cannot grant this to itself, and a dialog that only says "denied" leaves the reader
            // to find the switch. Opening the pane that has the switch is the whole of the help.
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case let .modelMissing(locale):
            installVoiceModel(locale)
        case .languageUnsupported, .failed:
            // Nothing to fetch and nothing to open: trying again is the action.
            dictation.available()
        }
    }

    private func beginDictation() {
        guard enabled else { return }
        // **An input method and dictation both write marked text, so only one of them can be writing.**
        // A composition in progress is dropped rather than committed: the keys that were typed to spell
        // it are not a word yet, and Escape — which is what this is — is the key that means exactly that
        // in every input method on this system.
        if DictationField.inputMethodIsComposing {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.inputContext?.discardMarkedText()
        }
        // The field has to have the keyboard before a sentence can go into it, and the button that was
        // just pressed may have taken it.
        editorFocused = true
        field.forget()
        // If the field editor is not there when a sentence settles — the window lost the keyboard, a
        // permission dialog took it — the sentence still lands, at the end of the draft. See `DictationField`.
        field.fallback = { text in
            draft += draft.isEmpty ? text : " " + text
        }
        capture.onEvent = { event in handle(event) }
        Task { await capture.start(wanted: voiceLanguage.isEmpty ? nil : voiceLanguage) }
    }

    /// Finish the sentence and send it, for a Send pressed while the microphone was open.
    ///
    /// The same call as `stopDictation`, with `sendWhenSettled` set: what happens when the sentence lands is
    /// the only thing that differs between "stop" and "stop and send".
    private func finishDictationThenSend() {
        stopDictation()
    }

    /// Stop listening; the sentence settles when the recogniser's last result arrives.
    ///
    /// **There is no timer here, and that is deliberate.** "A stop always ends with a settled sentence" is a
    /// guarantee of `VoiceCapture`, which owns the results stream and can see whether the final arrived; a
    /// second watchdog on this side would be a second answer to the same question, and the two would drift
    /// the moment either changed. All this does is ask and wait.
    private func stopDictation() {
        dictation.stop()
        Task { await capture.stop() }
    }

    /// Throw the sentence away.
    private func cancelDictation() {
        sendWhenSettled = false
        apply(dictation.cancel())
        field.endCue()
        Task { await capture.cancel() }
    }

    private func installVoiceModel(_ locale: String) {
        installing = 0
        Task {
            do {
                try await capture.installModel(locale: locale) { fraction in
                    installing = fraction
                }
                installing = nil
                dictation.available()
            } catch {
                installing = nil
                apply(dictation.trouble(.failed(error.localizedDescription)))
            }
        }
    }

    /// What the microphone has to say, turned into a rule and then into something the field does.
    private func handle(_ event: VoiceCapture.Event) {
        switch event {
        case .starting:
            // Deliberately no cue yet: the model is still loading and nothing is being heard, so a caret that
            // said "listening" would be saying something untrue.
            dictation.beganStarting()
        case .listening:
            dictation.beganListening()
            field.beginCue()
        case let .partial(text): apply(dictation.heard(text))
        case let .final(text):
            apply(dictation.finished(text))
            // End of the whole session, not of one sentence: only a stop does this.
            if !dictation.isActive { field.endCue() }
        case let .trouble(trouble):
            apply(dictation.trouble(trouble))
            field.endCue()
        }
    }

    private func apply(_ effect: DictationEffect) {
        switch effect {
        case .none: break
        case let .show(text):
            field.show(text)
            // The caret cue follows the text: a badge pinned to where the caret *was* is worse than no badge,
            // because it points at the wrong word.
            field.moveCue()
        case let .settle(text):
            field.settle(text)
            // A sentence settling is not the end of the session — the recogniser commits one and carries on —
            // so the cue stays and follows the caret to the next one.
            field.moveCue()
            // The reader pressed Send while they were still speaking: the sentence is now in the box, so the
            // send they asked for can happen. Deferred by a run-loop turn so SwiftUI has written the settled
            // text into the binding first — `submit()` reads `draft`, and reading it in the same turn it was
            // written is exactly the kind of "the handler saw the old value" this file has been bitten by.
            if sendWhenSettled {
                sendWhenSettled = false
                DispatchQueue.main.async { submit() }
            }
        case .discard:
            field.discard()
            field.endCue()
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
        return TemporaryImage.write(png, named: "paste")
    }

    /// Whether there is anything to attach, for the menu item's enabled state.
    static var available: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }
}

/// A picture this side made, left somewhere the shell can read it.
///
/// The one place the convention lives, because there are now two producers: the clipboard, and the
/// sketch sheet. A second copy of "write PNG bytes into a UUID-named file under the temporary
/// directory" is how the two would come to disagree about which directory gets cleaned up — and the
/// shell deletes exactly the file it was handed, so a file in the wrong place is a file that stays.
enum TemporaryImage {
    static func write(_ png: Data, named name: String) -> String? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wei-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name)-\(UUID().uuidString).png")
        do {
            try png.write(to: file)
        } catch {
            return nil
        }
        return file.path
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
                // The figures in the order they are read: how full the window is, what the cache
                // saved, and what it all cost. The web UI puts the same four on one row under its
                // composer as chips (tokens, cache, cost, context), and the reason to match it is not
                // symmetry: a reader comparing two answers — "why was that one cheaper" — is looking
                // at this line, and a figure that only exists in a popover is a figure they have to
                // already know is there.
                CacheMeter(usage: usage)
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
        // Thinking tokens, when the provider reports them. They are part of what the turn cost and
        // invisible in the answer, which is exactly the case where a reader wonders why a one-line
        // reply was expensive.
        if let thinking = last.reasoning, thinking > 0 {
            parts.append("\(TokenText.compact(thinking)) thinking")
        }
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
                // Beside the percentage, not instead of it: the share is what a reader checks at a
                // glance, and the pair is what they check when the share looks high — a number they
                // can compare against a model's published window without opening anything.
                Text("\(TokenText.compact(usage.contextFigure))/\(TokenText.compact(usage.window))")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                // The ring says how full it is; this says that being full is now a thing that will
                // *happen* rather than a thing to watch. It is the one figure on this line that
                // changes what the next turn does, so it gets a mark as well as a colour: amber
                // already means "getting close" at 70%, and "the next turn may summarize this
                // conversation" is a different fact.
                if usage.compactSoon {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .help(figure)
        }
    }

    /// What the ring is measuring, and whether that is a measurement at all.
    ///
    /// A tooltip rather than a label beside the number: this is the figure a reader checks when they
    /// wonder whether it is time to start a new conversation, which makes it worth explaining and not
    /// worth a second line of text under the composer.
    private var figure: String {
        let used = "\(TokenText.exact(usage.contextFigure)) of \(TokenText.compact(usage.window)) context tokens"
        let source = usage.contextIsMeasured
            ? "measured: the provider's prompt size for the last reply, plus what has been added since"
            : "estimated: no reply in this conversation has reported a prompt size yet"
        guard usage.overhead > 0 else { return "\(used) · \(source)" }
        let fixed = "the system prompt and tool schemas are included (~\(TokenText.compact(usage.overhead)))"
        guard usage.compactSoon else { return "\(used) · \(source) · \(fixed)" }
        return "\(used) · \(source) · \(fixed) · the next turn may summarize this conversation"
    }

    /// Amber well before full, because the interesting moment is the compaction that happens when it
    /// runs out — and by then the reader can no longer see it coming.
    private func tint(_ fill: Double) -> Color {
        if fill >= 0.9 { return .red }
        if fill >= 0.7 { return .orange }
        return .accentColor
    }
}

/// What the provider's cache bought, on the line rather than in the panel.
///
/// It earns its place there because it is the one figure that explains a bill a reader would
/// otherwise find surprising: the same conversation, sent twice, costs very different amounts
/// depending on how much of it the provider recognized. Absent when nothing has been read from a
/// cache, which is the normal state on a first turn and on a provider that does not cache at all —
/// a chip reading `0 · 0%` would be a chip every reader learns to skip.
private struct CacheMeter: View {
    let usage: Usage

    var body: some View {
        if usage.cacheRead > 0 {
            HStack(spacing: 3) {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 9))
                // The share first, because that is the number that answers "is caching working here",
                // and the volume second, compacted: `186M · 99%` reads as "nearly everything".
                Text(share)
                    .monospacedDigit()
                Text(TokenText.compact(usage.cacheRead))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .help(figure)
        }
    }

    private var share: String {
        usage.cacheHit.map { "\($0)%" } ?? "—"
    }

    private var figure: String {
        let read = "\(TokenText.exact(usage.cacheRead)) prompt tokens came from the provider's cache"
        guard let hit = usage.cacheHit else { return read }
        return "\(read) — \(hit)% of all billed input this session"
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
            // Only when it happened: a turn that read nothing from the cache is the normal case, and
            // a row of zeroes for it would be a row every reader learns to skip.
            if last.cacheRead > 0 { row("cached input", TokenText.exact(last.cacheRead)) }
            if let thinking = last.reasoning, thinking > 0 {
                row("thinking", TokenText.exact(thinking))
            }
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
        // Absent rather than zero when the provider does not report it: unlike a cache read, where
        // nothing means nothing, this one is a fact about the *provider*, and a `0` would claim the
        // model did no thinking.
        if usage.reasoning > 0 {
            row("thinking", TokenText.exact(usage.reasoning))
        }
        row("total tokens", TokenText.exact(usage.total))
        context
        Divider()
        row("input cost", usage.costInput)
        row("output cost", usage.costOutput)
        if usage.cacheRead > 0 || usage.cacheWrite > 0 {
            row("cache cost", sum(usage.costCacheRead, usage.costCacheWrite))
        }
    }

    /// How close the conversation is to the model's window, and how much of that it can do nothing
    /// about.
    ///
    /// A section of its own rather than three more rows under the totals: this is the block a reader
    /// opens the panel for, and the rest of the panel is the bill.
    @ViewBuilder private var context: some View {
        section("Context")
        // The figure for the **next** request against the window it has to fit in, which is the
        // question the panel is opened to answer. Not the size of the last request: see
        // `Usage::contextFill` for why those are two numbers and why this is the one that matters.
        row("next request", "\(TokenText.compact(usage.contextFigure)) / \(TokenText.compact(usage.window))")
        if let fill = usage.contextFill {
            row("used", "\(Int((fill * 100).rounded()))%")
        }
        row("source", usage.contextIsMeasured ? "measured" : "estimated")
        // What every request carries before the conversation starts. Named, because it is the part of
        // that figure which no amount of tidying the conversation will move. Left out when the shell
        // did not say, rather than drawn as `~0`.
        if usage.overhead > 0 {
            row("system + tools", "~\(TokenText.compact(usage.overhead))")
        }
        if usage.compactSoon {
            Text("This conversation is close to the window: the next turn may summarize it.")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
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
