import AppKit
import Foundation

import WeiModel

/// The field editor's half of dictation: putting a sentence into the box the reader is typing in.
///
/// **A dictated sentence is a composition, not an insertion.** The words go in as *marked text* — the
/// same mechanism an input method uses while it is converting pinyin — and are only written into the
/// `TextField`'s binding when the sentence settles. That is not a trick to make the text look nice; it is
/// the only way to get the behaviour a reader already knows:
///
/// - the text appears as it is spoken, and the platform draws its own underline under it, so nothing has
///   to be invented and nothing has to be redrawn;
/// - a revision replaces what it revises (the recogniser writes 「一边说一」 and then 「一边说一边」;
///   inserting those in order would type the sentence twice);
/// - the caret stays where the reader put it, so dictating into the middle of a sentence works;
/// - **one sentence is one undo**. Measured: a sentence committed this way comes back out with a single
///   ⌘Z, and so does a plain insertion — which is what "make it easy to undo" has to mean if the thing
///   being undone is a paragraph somebody spoke.
///
/// **Why this is a type rather than four lines in the composer.** Everything here is a fact about a
/// *field editor*, not about the composer: which editor is focused, whether it is holding a composition,
/// and what to do when the platform has settled one behind our back. The composer should be able to ask
/// for a sentence to appear and not know how a text input client works.
///
/// The field editor is reached through the window's first responder, which is how the composer's own
/// input-method guard already finds it (`Composer.composing`). That is the same object, found the same
/// way, for the same reason: while a reader is typing, the field editor *is* the text.
@MainActor
final class DictationField {
    /// Where a settled sentence goes when there is no field editor to put it in.
    ///
    /// The field editor is the point of this type, but it is not always there: a window that is not
    /// frontmost, a reader who clicked away, a permission dialog that took the keyboard. Without a fallback
    /// a sentence spoken in any of those states is transcribed and then dropped, which is the worst kind of
    /// bug — the reader watched the words appear and then watched them not be there. So the composer hands
    /// in the one thing that can still be done, and the honest answer is "append it to the draft".
    ///
    /// Only the *settled* sentence takes this path: without an editor there is nothing to mark, so there is
    /// nowhere for a partial to revise itself and no point showing one.
    var fallback: ((String) -> Void)?

    /// The composition this object put into the field, and the range it is at.
    ///
    /// Tracked because the platform can settle a composition without telling us — Return, a click
    /// elsewhere, or the input method — and after that there is nothing at that range to replace. What is
    /// done about it is `Dictation.pending`.
    private var marked: NSRange?
    private var shown = ""

    /// Watching the caret, so the badge follows the reader's own typing and not just ours.
    ///
    /// **Without this the badge only moves when a word arrives from the recogniser** — it was placed by
    /// `moveCue`, which only dictation called — so typing or clicking in the middle of a sentence left it
    /// pointing at where the caret used to be. Measured: the caret moved from `x=2` to `x=122.7` while the
    /// badge stayed at `(2.0, 17.0)`.
    ///
    /// The notification is the field editor's own ("the selection changed"), which fires for typing, arrow
    /// keys, a click, and for our own `setMarkedText`. Registered with `object: nil` rather than with the
    /// editor, because a `TextField` being rebuilt is a field editor being replaced, and a badge tied to the
    /// old one would stop following.
    private var caretObserver: NSObjectProtocol?

    /// The mic that rides the caret while a sentence is being spoken, and the caret colour to put back.
    ///
    /// **Because the platform's own cue is not available to us.** While the system's dictation is listening
    /// the insertion point turns blue and a small microphone sits beside it — that is
    /// `NSTextInsertionIndicator`, and it is a public view that draws *nothing* on its own: measured, it
    /// renders zero pixels in every display mode, and its `effectsViewInserter` (the documented hook for
    /// inserting the glow) is never called. The glow is put there by the text system only while a real
    /// dictation session is running, driven by input-context state that has no public setter —
    /// `_dictationDidStart:` exists and is what sets it, and calling it directly does nothing observable.
    ///
    /// So a session driven by our own engine gets no cue at the caret at all, and this is the part of that
    /// which can be said with public API: the caret takes the accent colour and a badge follows it. The
    /// badge is drawn rather than borrowed because there is nothing to borrow.
    private var badge: DictationBadge?
    private var restingCaretColor: NSColor?

    /// The focused field editor, if a text box has the keyboard.
    ///
    /// Only a field editor that is actually in the key window counts: dictation that typed into a window
    /// nobody is looking at would be worse than dictation that did nothing.
    private var editor: NSTextView? {
        guard let responder = NSApp.keyWindow?.firstResponder else { return nil }
        return responder as? NSTextView
    }

    /// Whether an input method is partway through a word in the focused field.
    ///
    /// Dictation and an input method both write marked text, and two writers of one composition would
    /// fight: the input method would replace the sentence, or the sentence would swallow the candidate.
    /// So dictation refuses to start while this is true, rather than trying to share.
    static var inputMethodIsComposing: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return (responder as? NSTextView)?.hasMarkedText() ?? false
    }

    /// Show `text` as the composition in progress.
    func show(_ text: String) {
        guard let editor else {
            // No editor: nothing to mark and nothing to revise, so the sentence is held and written once.
            shown = text
            return
        }
        // The normal case: replace the composition we are holding.
        if let marked, marked.location != NSNotFound, NSMaxRange(marked) <= (editor.string as NSString).length,
            editor.markedRange() == marked
        {
            let range = marked
            let selection = NSRange(location: range.location + (text as NSString).length, length: 0)
            self.marked = NSRange(location: range.location, length: (text as NSString).length)
            shown = text
            editor.setMarkedText(text, selectedRange: selection, replacementRange: range)
            return
        }
        // The composition was settled behind our back. There is no range to replace any more, so what can
        // still be done is to add whatever the sentence has gained since.
        let fresh = Dictation.pending(text, after: shown)
        // Nothing to add: the sentence has not grown, or it was revised. Either way the text that is
        // already in the field stands, and `shown` is left alone so the next partial is judged against
        // what is really there.
        guard let fresh else { return }
        let start = editor.selectedRange().location
        self.marked = NSRange(location: start, length: (fresh as NSString).length)
        shown = text
        editor.setMarkedText(
            fresh,
            selectedRange: NSRange(location: start + (fresh as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    /// The sentence is over: make it ordinary text.
    ///
    /// The final result is written before it is settled when it differs from what is shown, because the
    /// recogniser's last word on a sentence is often not its last guess — 「然后让他一边说」 settles as
    /// 「然后让它一边说」 — and the reader is about to send this text.
    func settle(_ text: String) {
        guard let editor else {
            fallback?(text)
            return forget()
        }
        if let marked, editor.markedRange() == marked, text != shown {
            let range = NSRange(location: marked.location, length: (text as NSString).length)
            editor.setMarkedText(
                text,
                selectedRange: NSRange(location: NSMaxRange(range), length: 0),
                replacementRange: marked
            )
        }
        // `unmarkText` rather than an insertion: this is the call that writes the composition into the
        // binding, and it is the same one an input method's commit goes through.
        editor.unmarkText()
        forget()
    }

    /// Take the sentence back out.
    func discard() {
        guard let editor, let marked, editor.markedRange() == marked else { return forget() }
        // Replacing the composition with nothing, then settling it: what the reader had before the
        // sentence started is what is left.
        editor.setMarkedText(
            "",
            selectedRange: NSRange(location: marked.location, length: 0),
            replacementRange: marked
        )
        editor.unmarkText()
        forget()
    }

    /// Forget the composition without touching the field.
    func forget() {
        marked = nil
        shown = ""
    }

    // ── the cue at the caret ──────────────────────────────────────────────

    /// A sentence is starting: the caret takes the accent colour and grows a microphone.
    func beginCue() {
        guard let editor else { return }
        if restingCaretColor == nil { restingCaretColor = editor.insertionPointColor }
        editor.insertionPointColor = cueColor
        if badge == nil {
            let badge = DictationBadge(color: cueColor)
            editor.addSubview(badge, positioned: .above, relativeTo: nil)
            self.badge = badge
        }
        if caretObserver == nil {
            caretObserver =
                NotificationCenter.default.addObserver(
                    forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.moveCue() }
                }
        }
        moveCue()
    }

    /// The caret has moved — because a word arrived, or the reader typed. Follow it.
    ///
    /// The colour is re-asserted here rather than only in `beginCue`, because a `TextField` being rebuilt is
    /// a field editor being configured, and the configuration wins over what was set on it a moment ago.
    func moveCue() {
        guard let editor, let badge else { return }
        editor.insertionPointColor = cueColor
        let caret = caretRect(in: editor)
        // Above the line, and below it when there is no room above — a caret on the first visible line has
        // nothing over it, and a badge that gets clipped away is a cue that is not there.
        let size = DictationBadge.size
        var origin = CGPoint(x: caret.minX, y: caret.maxY + 1)
        if origin.y + size.height > editor.bounds.maxY {
            origin.y = caret.minY - size.height - 1
        }
        origin.x = min(max(0, origin.x), max(0, editor.bounds.width - size.width))
        origin.y = min(max(0, origin.y), max(0, editor.bounds.height - size.height))
        badge.frame = NSRect(origin: origin, size: size)
    }

    /// The sentence is over: the caret goes back to how it was and the microphone goes away.
    func endCue() {
        if let caretObserver {
            NotificationCenter.default.removeObserver(caretObserver)
            self.caretObserver = nil
        }
        if let editor, let restingCaretColor { editor.insertionPointColor = restingCaretColor }
        badge?.removeFromSuperview()
        badge = nil
        restingCaretColor = nil
    }

    /// Where the caret is, in the field editor's own coordinates.
    ///
    /// `firstRect` answers in *screen* coordinates — it is the API a spell checker uses to put a panel near
    /// the word — so it is converted through the window and back. The height is the line's, which is what the
    /// badge is positioned against.
    private func caretRect(in editor: NSTextView) -> NSRect {
        var rect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        guard let window = editor.window else { return .zero }
        rect = window.convertFromScreen(rect)
        return editor.convert(rect, from: nil)
    }

    /// The colour the caret and the badge are drawn in.
    private var cueColor: NSColor { NSColor(Wei.Palette.accent) }
}

/// The microphone that rides the caret while a sentence is being spoken.
///
/// Small, round, and in the accent colour — the same colour the caret turns and the same colour as the ring
/// around the microphone in the composer, so the two are visibly one state rather than two decorations.
/// Click-through, because it sits over the text the reader may be about to type into.
@MainActor
final class DictationBadge: NSView {
    static let size = NSSize(width: 14, height: 14)

    private let icon = NSImageView()

    init(color: NSColor) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 4
        icon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictating")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        // **The frame is set here, once, and not in `layout()`.** `layout()` runs when a view needs layout,
        // and this badge is placed by assigning its frame — so nothing ever asked for one, the icon stayed
        // `0×0`, and a `0×0` image view with proportional scaling draws the glyph at its natural size from the
        // bottom-left corner: the microphone sat in the corner of its own circle. The badge is a fixed size,
        // so laying it out once is not an optimisation, it is the whole of the correctness.
        //
        // `insetBy` with one margin on both axes is what makes it centred by construction: 14 - 3 - 3 = 8,
        // and `scaleProportionallyDown` centres the scaled glyph inside that box. Rounding any of these
        // numbers to whole points is what breaks it — a 7.2-point box rounded to 7 leaves 3 points on one
        // side and 4 on the other.
        icon.frame = bounds.insetBy(dx: 3, dy: 3)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The badge is a cue, not a control: a click on it belongs to the text underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
