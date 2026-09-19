import Foundation

/// What a screenshot came back as: the three things that can have happened.
///
/// The capture itself is the system's own tool (`/usr/sbin/screencapture`), which means it is a
/// **separate process with the reader in the loop**, and its answer arrives as *bytes and a sentence*
/// rather than as a status: a file with a picture in it, nothing at all because the reader pressed
/// Escape, or nothing at all because something refused. Telling those three apart is the part of this
/// feature that can be wrong, and the way it is wrong is the way a screenshot feature is annoying for
/// a reader — a cancel reported as a failure is a dialog in front of a gesture whose whole point is
/// that it can be abandoned.
///
/// So the rule lives here, where a test can hand it every combination without a screen. What the
/// picture then *is* — whether it is a kind the shell will attach, and whether the model on screen can
/// be shown it — is the shell's answer, on the bytes, exactly as it is for a dropped file.
public enum ScreenshotOutcome: Equatable, Sendable {
    /// A picture, as the bytes the tool wrote.
    case taken(Data)
    /// The reader changed their mind: Escape, or a click that selected nothing.
    case cancelled
    /// No picture, and something to say about it.
    case refused(ScreenshotTrouble)

    /// The three answers from the tool, read together. There are four cases and they were **measured**,
    /// not guessed — a throwaway app bundle with its own identifier, so a process *without* the screen
    /// recording grant could be run against the same command:
    ///
    /// | case | exit | what it said | file |
    /// |---|---|---|---|
    /// | reader drew a region, permission granted | `0` | — | written |
    /// | reader drew a region, **no permission** | `1` | `could not create image from rect` | none |
    /// | reader pressed Escape, permission granted | `0` | — | none |
    /// | reader pressed Escape, **no permission** | `0` | — | none |
    ///
    /// Three things fall out of that table, and all three are rules here:
    ///
    /// - **The bytes are the arbiter.** A capture that wrote a picture succeeded, whatever else the tool
    ///   printed along the way — the file is the whole of the answer, and the text is not a second opinion
    ///   about it. `said` is therefore only read to explain a *failure*.
    /// - **A cancel is silent and exits 0; a refusal speaks and exits non-zero.** So neither the exit
    ///   status nor the absence of a picture is enough on its own: judging by status calls a cancel a
    ///   success, and judging by the file calls both a cancel and a refusal a failure. The pair
    ///   (*nothing said*, `0`) is the one thing only a cancel produces, and it is the reason a reader
    ///   who changes their mind gets no dialog — which is what makes a screenshot feature usable.
    /// - **The cancel is checked before the permission**, and that ordering is visible in the table: a
    ///   reader *without* the grant who presses Escape also gets silence and `0`, and telling them their
    ///   Escape was a permission problem is the wrong sentence about the wrong thing at the moment they
    ///   decided not to take a picture. The permission explains a failure that already happened; it is
    ///   never part of a picture that did not happen for the reader's own reasons.
    ///
    /// `screenAccess` is the app's own permission, asked of the system before the capture, and it is only
    /// consulted once there is a failure to explain. (An app without it still gets the selection
    /// crosshair — measured: the tool ran and waited for input — and then fails to produce the picture,
    /// which is why the permission is asked for *after* the fact and not before the gesture.)
    public static func of(
        bytes: Data?,
        said: String,
        status: Int32,
        screenAccess: Bool,
    ) -> ScreenshotOutcome {
        if let bytes, !bytes.isEmpty { return .taken(bytes) }
        if isCancellation(said) { return .cancelled }
        if said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, status == 0 {
            return .cancelled
        }
        if !screenAccess { return .refused(.permission) }
        return .refused(.other(said.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Whether the tool is saying that the reader asked for nothing.
    ///
    /// The tool's own messages for an interrupted selection are "No selection to capture. Cancelling" and
    /// the word itself; both are matched on the two phrases that carry the meaning, so the untranslated
    /// parts of a sentence (a path, a locale's punctuation) do not decide it. Measured on macOS 26.5, an
    /// Escape prints *nothing at all* — see the table above for why the silence is the real signal and
    /// this is the belt to that pair of braces (a build that starts saying "cancelling" again is still a
    /// cancel).
    private static func isCancellation(_ said: String) -> Bool {
        let words = said.lowercased()
        return words.contains("cancel") || words.contains("no selection")
    }
}

/// What to say about a screenshot that did not happen.
///
/// Two cases rather than a message, because they are two different *actions*: one has a switch the
/// reader can turn on, and the other has nothing but its own sentence. Which of them it is cannot be
/// worked out at the point of failure by anything that only knows the capture failed — which is what
/// makes this a value rather than a string.
public enum ScreenshotTrouble: Equatable, Identifiable, Sendable {
    /// The app is not allowed to read the screen.
    case permission
    /// The tool said something, and the sentence is the only thing that can be said about it.
    case other(String)

    public var id: String {
        switch self {
        case .permission: return "permission"
        case let .other(said): return said
        }
    }
}
