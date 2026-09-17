import Foundation

/// Whether the transcript keeps up with what is arriving.
///
/// The rule exists because following unconditionally is wrong in the one situation a long turn
/// creates: a reader who has scrolled up to read something — usually the thing the model is
/// referring to — is dragged back to the bottom by every frame of the answer.
///
/// The subtlety, and the reason this is a named rule rather than a boolean somewhere in a view, is
/// *what is allowed to change it*. Content growing pushes the bottom away from the reader by
/// definition, so "am I at the bottom" answered on every layout pass says "no" the instant anything
/// streams in — and following then stops forever on the first token of the first turn. Measured, not
/// imagined: that is the failure mode of the naive version.
///
/// So only the reader's own scrolling is allowed to stop it, and the geometry is consulted only for
/// the direction that needs it:
///
/// - scrolling **up** stops following, immediately and unconditionally. Nothing else could mean
///   anything: they are going to read something above.
/// - scrolling **down** restores following, but only once the bottom is back in view. A reader
///   mid-flick should not have the stream start yanking at them a screen early.
/// - sending a prompt restores it too. They asked a question; the answer has to be visible.
///
/// Everything else — deltas arriving, a tool finishing, the window being resized — leaves the
/// decision alone.
public struct ScrollFollow: Equatable {
    public private(set) var following: Bool

    public init(following: Bool = true) {
        self.following = following
    }

    /// The reader moved the transcript themselves.
    ///
    /// `up` is the direction of the content: scrolling up means the reader is looking at something
    /// above where they were. `atBottom` is the latest measurement of whether the end of the
    /// transcript is in view, and is only consulted on the way down.
    public mutating func readerScrolled(up: Bool, atBottom: Bool) {
        if up {
            following = false
        } else if atBottom {
            following = true
        }
    }

    /// Another session is now on screen.
    ///
    /// A conversation is read from its end, so opening one lands there — and unlike `readerScrolled` this does
    /// not consult a measurement, because the rows have not been laid out yet and any measurement taken now
    /// belongs to the transcript that is being replaced.
    public mutating func opened() {
        following = true
    }

    /// A prompt went out: the answer to it is the thing to look at.
    ///
    /// Forced rather than measured, because the message has not been drawn yet — the row appears in
    /// the same pass that raises this, so any measurement taken now is of a transcript that does not
    /// have the question in it yet.
    public mutating func promptSent() {
        following = true
    }
}
