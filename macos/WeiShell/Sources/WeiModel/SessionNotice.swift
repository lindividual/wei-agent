import Foundation

/// A turn that ended in a conversation the reader is **not** looking at.
///
/// A fact about the window rather than about a transcript: it is news from somewhere else, so the only
/// place it can live is the side that decides which conversation is on screen.
///
/// **It exists because the alternative was a window that jumped.** A turn ending in a background session
/// used to be announced with a `session` event — the event that means "this session is now on screen" —
/// and this side answered it by switching. So an answer finishing in session 2 while the reader was in
/// session 1 moved them to session 2, mid-sentence, with nothing they had done to ask for it. The fix
/// is on both sides of the wire: the shell sends `elsewhere` instead, and this side is free to say so
/// without moving anything.
///
/// What it is *for* is the gap the sidebar cannot cover. While a turn runs, the row carries a spinner;
/// when it ends, the spinner goes away — and a reader who has switched conversations, collapsed the
/// list, or scrolled past that row has no way to learn that the moment they were waiting for arrived.
/// A line above the conversation they *are* reading closes that gap without taking the screen.
public struct SessionNotice: Equatable, Identifiable, Sendable {
    /// How the turn ended, as the shell names it.
    ///
    /// A token off the wire rather than a sentence: the shell has no business writing this app's English,
    /// and a word chosen here is a word a test can check. `outcome` and `title` are the two halves of that
    /// split — the wire says what happened, this type says how to say it.
    public enum Outcome: Equatable, Sendable {
        case finished
        /// The turn raised. It is still a turn the reader can carry on — the log keeps it open — and the
        /// session's own transcript is where the notice offering that is drawn.
        case failed
        /// The reader asked for this one, so it is the least surprising of the three; it is said anyway
        /// because a stopped turn is still a row that has stopped moving.
        case stopped
        /// An outcome from a newer shell. Kept rather than refused — it is still true that the turn ended
        /// somewhere else, which is the whole of what this notice is for — and the raw token is shown,
        /// because a token is more use than a line that says nothing happened.
        case other(String)

        public init(wire: String) {
            switch wire {
            case "finished": self = .finished
            case "failed": self = .failed
            case "stopped": self = .stopped
            default: self = .other(wire)
            }
        }

        /// The verb the line uses. Past tense, because the turn is over by the time this is drawn — a
        /// notice that said "finishing" would be a notice about something still moving.
        public var word: String {
            switch self {
            case .finished: return "finished"
            case .failed: return "failed"
            case .stopped: return "stopped"
            case let .other(raw): return raw.isEmpty ? "ended" : raw
            }
        }
    }

    /// The session the turn was in. The identity, and the argument `/open` takes: what "Open" means is
    /// "put that session on screen", and a session is its file.
    public let path: String
    public let outcome: Outcome
    /// What the sidebar calls that session, resolved when the notice is made. Empty when the store has
    /// not listed it — see `sessionName(of:in:)`.
    public let label: String

    /// The session, and not the outcome, is the identity: a second turn ending in the same conversation
    /// is this one line saying something newer, not a second line stacked under it. A stack of banners is
    /// a second inbox, and the transcript of the session that ended already keeps the record of what it
    /// did.
    public var id: String { path }

    public init(path: String, outcome: Outcome, label: String) {
        self.path = path
        self.outcome = outcome
        self.label = label
    }

    /// The line, as the reader reads it.
    ///
    /// **It names the kind of thing before the name**, because the name is not a name: a label is the
    /// reader's own words or the session's first question, and either can be a whole sentence — “fix the
    /// flaky test on CI” finished would read as a remark about CI rather than about a conversation. One
    /// word in front of the quotes is what keeps the line a sentence about a session.
    ///
    /// Without a name the line falls back to describing rather than dropping the subject: a notice with
    /// no subject — “finished” — is a notice about nothing, and the reader cannot tell whether it meant
    /// them.
    public var title: String {
        label.isEmpty ? "Another session \(outcome.word)" : "Session “\(label)” \(outcome.word)"
    }
}
