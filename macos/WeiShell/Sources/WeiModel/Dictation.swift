import Foundation

/// Whether the microphone is listening, and what has to happen to the text it hears.
///
/// A named rule rather than a `Bool` in a view, for the same reason `ScrollFollow` is one: the parts that
/// are easy to get wrong are not "is it on" but *what is allowed to change it* and *what happens to the
/// text already in the field*. Those are decisions, they are checkable, and they live here where a test
/// can run them a hundred times without a microphone or a permission prompt.
///
/// **The shape of a sentence.** Speech arrives as a stream of *partial* results — each one the whole
/// sentence so far, revised as the recogniser changes its mind — and ends with one final result. The
/// field shows the partial as a *composition* (marked text, the same mechanism an input method uses: see
/// `DictationField`), so the reader sees words arriving with the platform's own underline, and the
/// binding is only written when the sentence is settled. Partial → settled is therefore the only
/// transition that touches the reader's text, and it is the one this type is really about.
///
/// **Three ways a sentence ends, and they differ on purpose:**
///
/// - `stop` — the reader asked for it to end. The text stays; they are going to send it.
/// - `cancel` — Escape. What was heard is taken back out. They asked for it to not have happened.
/// - `trouble` — the microphone died, the model went missing, a permission was refused. **What was
///   already heard is kept**: the reader did not ask to lose it, and "it stopped working" is not a
///   reason to discard a sentence they just spoke.
///
/// Nothing here sends. Dictation fills the field; sending is a separate act by the reader, and it stays
/// that way deliberately — a misheard word is cheap to fix and expensive to have already sent.
public struct Dictation: Equatable {
    public private(set) var phase: DictationPhase

    /// What this sentence has put into the field, still waiting to be settled.
    ///
    /// Kept because it is what "cancel" has to take back out and what "trouble" has to keep, and because
    /// it is the only way to tell a partial that *extends* what is shown from one that revises it.
    public private(set) var heard: String

    /// Everything this session has already written into the field as ordinary text.
    ///
    /// Needed because **a sentence can settle while the reader is still speaking**: the recogniser is asked
    /// to commit early and often, and when it does, the text stops being a composition and becomes real.
    /// Its next results then have to be read against what is already there — see `fresh` — or a hypothesis
    /// that restarts from the beginning of the utterance would type the beginning twice.
    public private(set) var settled: String

    public init() {
        phase = .idle
        heard = ""
        settled = ""
    }

    /// Whether a sentence is being heard right now.
    public var isListening: Bool { phase == .listening }

    /// Whether dictation is doing anything at all — including the moment between "stop" and the last
    /// result arriving, when the microphone is already closed and the field is not yet settled, and the
    /// moment at the start when the model is being loaded.
    public var isActive: Bool { phase == .starting || phase == .listening || phase == .stopping }

    /// Why it cannot start, when it cannot. `nil` means it can.
    public var trouble: DictationTrouble? {
        if case let .unavailable(trouble) = phase { return trouble }
        return nil
    }

    /// The model is being prepared: the button has been pressed and nothing is being heard yet.
    public mutating func beganStarting() {
        phase = .starting
        heard = ""
        settled = ""
    }

    /// The microphone opened: everything after this until the sentence ends is part of one utterance.
    public mutating func beganListening() {
        phase = .listening
        heard = ""
        settled = ""
    }

    /// Drop what a hypothesis has already repeated.
    ///
    /// A result is the recogniser's best reading of the utterance so far, and "so far" may reach back past
    /// the sentences already settled — an utterance does not start again just because a sentence in the
    /// middle of it was committed. What has been written down is therefore removed from the front rather
    /// than written a second time.
    private func fresh(_ text: String) -> String {
        guard !settled.isEmpty, text.hasPrefix(settled) else { return text }
        return String(text.dropFirst(settled.count))
    }

    /// A partial result: the whole sentence so far, which may revise what was shown before.
    ///
    /// Revisions are the normal case, not an error — the recogniser writes "一边说一" and then decides it
    /// was "一边说一边" — so the effect is always "make the field say this", never "append this".
    public mutating func heard(_ text: String) -> DictationEffect {
        guard isActive, !text.isEmpty else { return .none }
        let text = fresh(text)
        guard !text.isEmpty, text != heard else { return .none }
        heard = text
        return .show(text)
    }

    /// The reader asked for the sentence to end. The recogniser still owes us its final result.
    public mutating func stop() {
        guard phase == .listening || phase == .starting else { return }
        phase = .stopping
    }

    /// The recogniser's last word on a sentence.
    ///
    /// **A sentence can end while the reader is still speaking**, which is why this does not simply stop:
    /// the recogniser is asked to commit early, so a pause in the middle of a long answer produces a final
    /// result and then carries on. That sentence is written into the field as ordinary text and listening
    /// continues; only `stop` — the reader's own — ends the session.
    ///
    /// `text` is used rather than what was last shown, because the final result is the one the recogniser
    /// stands behind: measured, the last partial of a sentence and its final result differ often enough to
    /// matter (「然后让他一边说」 settles as 「然后让它一边说」), and the settled text is the one the reader
    /// is going to send.
    public mutating func finished(_ text: String) -> DictationEffect {
        guard isActive else { return .none }
        let sentence = text.isEmpty ? heard : fresh(text)
        heard = ""
        guard !sentence.isEmpty else {
            // Nothing was said — nothing heard, and nothing settled either, since `sentence` falls back to
            // what was heard. Mid-sentence that is a no-op: the recogniser is still working. After the
            // reader stopped, it is the end of the session, and the end of it with no text to write.
            guard phase == .stopping else { return .none }
            phase = .idle
            return .none
        }
        settled += sentence
        if phase == .listening { return .settle(sentence) }
        phase = .idle
        return .settle(sentence)
    }

    /// The reader cancelled: what was heard but not settled is taken back out of the field.
    ///
    /// Sentences that were already settled stay: they are ordinary text by then, and taking back a sentence
    /// the reader watched finish would be a surprise rather than an undo.
    public mutating func cancel() -> DictationEffect {
        guard isActive || !heard.isEmpty else { return .none }
        phase = .idle
        let had = !heard.isEmpty
        heard = ""
        return had ? .discard : .none
    }

    /// It cannot go on — and what was heard is kept.
    public mutating func trouble(_ trouble: DictationTrouble) -> DictationEffect {
        phase = .unavailable(trouble)
        let kept = heard
        heard = ""
        return kept.isEmpty ? .none : .settle(kept)
    }

    /// The trouble is over (a permission granted, a model installed): dictation is possible again.
    public mutating func available() {
        guard trouble != nil else { return }
        phase = .idle
    }

    /// What still has to be typed when the composition we marked is no longer marked.
    ///
    /// The field editor is not ours alone: Return, a click somewhere else, or the input method can settle
    /// our composition behind our back, and then the next partial cannot replace it any more — there is
    /// nothing left to replace. What can still be done is to add what the sentence has gained since.
    ///
    /// `nil` means "nothing to add": either the sentence has not grown, or it was *revised* rather than
    /// extended and there is no honest way to patch text that has already been committed. Appending the
    /// whole sentence in that case would type the shared beginning twice, which reads worse than a
    /// sentence that keeps one stale word — and the next partial almost always extends again.
    public static func pending(_ text: String, after heard: String) -> String? {
        if heard.isEmpty { return text.isEmpty ? nil : text }
        guard text.hasPrefix(heard) else { return nil }
        let rest = String(text.dropFirst(heard.count))
        return rest.isEmpty ? nil : rest
    }
}

/// What dictation is doing.
public enum DictationPhase: Equatable, Sendable {
    /// Not listening, and able to.
    case idle
    /// **Before `listening`: the model is being got ready.**
    ///
    /// This phase exists because of a measurement rather than a feeling. Opening the microphone and asking
    /// the model to start at the same moment loses the first seconds of speech — measured twice, on two
    /// runs, once losing 「请帮我」 from the front of a sentence and once losing a whole sentence — because
    /// the audio is already flowing while the model is still being loaded. So the model is prepared *first*
    /// and the microphone is opened after, and this is the state the reader is in while that happens. It is
    /// short, and it is visible: the button shows it, so the reader waits instead of talking to nothing.
    case starting
    /// The microphone is open and the reader is speaking.
    case listening
    /// The reader asked for the end; the recogniser's final result is still on its way.
    case stopping
    /// Not listening, and not able to. See `DictationTrouble`.
    case unavailable(DictationTrouble)
}

/// Why dictation cannot start, or why it stopped.
///
/// Cases rather than sentences: this is the model's answer, and the words a reader sees are the view's
/// business (`Composer`), for the same reason every other fact on the wire is a tag rather than a
/// sentence — the two sides can be changed, and checked, separately.
public enum DictationTrouble: Equatable, Sendable {
    /// The system has not been asked yet, or the reader said no.
    case microphoneNotPermitted
    /// The voice model for this language is not on the machine and has to be downloaded first.
    case modelMissing(locale: String)
    /// This language cannot be dictated on this Mac at all.
    case languageUnsupported(locale: String)
    /// Anything else, in the framework's own words.
    case failed(String)
}

/// What the field has to do, in the order the caller must do it.
public enum DictationEffect: Equatable, Sendable {
    /// Nothing.
    case none
    /// Show this as the composition in progress, replacing whatever composition is shown now.
    case show(String)
    /// The composition is over and this is what it says: make it ordinary text.
    case settle(String)
    /// Take the composition back out.
    case discard
}
