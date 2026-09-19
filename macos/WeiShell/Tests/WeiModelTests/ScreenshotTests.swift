import XCTest

@testable import WeiModel

/// What a screenshot came back as.
///
/// The capture is another process, so its answer is *bytes, whatever it said, and how it exited* — and
/// the whole of this rule is which of the three endings that triple means. Four cases were measured on
/// this machine (a throwaway app bundle with its own identifier, so a process *without* the screen
/// recording grant could be run against the same command), and they are the four tests below:
///
/// | case | exit | said | file |
/// |---|---|---|---|
/// | region drawn, permission granted | `0` | — | written |
/// | region drawn, no permission | `1` | `could not create image from rect` | none |
/// | Escape, permission granted | `0` | — | none |
/// | Escape, no permission | `0` | — | none |
///
/// The one that matters most is the last pair: **a cancel is not a failure.** Escape is the reader
/// changing their mind about a gesture whose whole point is that it can be abandoned, and a dialog in
/// front of that is how a screenshot feature becomes irritating.
///
/// What is deliberately not tested here: whether the picture is one the shell will attach, and whether
/// the model can be shown it. Both are the shell's answers on the bytes, and both are already pinned
/// where they live (`macos/appffi/app_wbtest.mbt`, `core/image_wire_test.mbt`) — a second opinion here
/// would be a second policy.
final class ScreenshotTests: XCTestCase {

    /// The tool succeeded and wrote a picture.
    private func taken(_ bytes: Data = Data([0x89, 0x50, 0x4E, 0x47])) -> ScreenshotOutcome {
        .taken(bytes)
    }

    // ── a picture ─────────────────────────────────────────────────────────

    func testBytesAreTheWholeOfASuccess() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(
            ScreenshotOutcome.of(bytes: png, said: "", status: 0, screenAccess: true),
            taken(png)
        )
    }

    /// The tool's own chatter cannot turn a capture into a failure.
    ///
    /// This is the reason the bytes are the arbiter: `screencapture` writes sentences to standard error
    /// for things it recovers from, and an implementation that read the text first would refuse a picture
    /// it had in its hand.
    func testASentenceAlongsideAPictureIsNotAFailure() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(
            ScreenshotOutcome.of(
                bytes: png,
                said: "could not create image from display\n",
                status: 1,
                screenAccess: false
            ),
            taken(png)
        )
    }

    /// No bytes at all is not a picture, whatever else is true.
    func testAnEmptyFileIsNotAPicture() {
        for bytes: Data? in [Data(), nil] {
            XCTAssertEqual(
                ScreenshotOutcome.of(bytes: bytes, said: "", status: 1, screenAccess: true),
                .refused(.other(""))
            )
        }
    }

    // ── the reader changed their mind ─────────────────────────────────────

    /// **The measured cancel: silence and exit 0.** Neither half is enough alone — the status by itself
    /// also describes a success (there is simply no file), and the silence by itself also describes a
    /// failure to start — so the pair is what says "the tool did nothing, and nothing went wrong".
    func testASilentSuccessWithNoPictureIsACancel() {
        XCTAssertEqual(
            ScreenshotOutcome.of(bytes: nil, said: "", status: 0, screenAccess: true),
            .cancelled
        )
        // Whitespace is not words: a stray newline on an otherwise silent run is still a cancel.
        XCTAssertEqual(
            ScreenshotOutcome.of(bytes: nil, said: "\n", status: 0, screenAccess: true),
            .cancelled
        )
    }

    /// The words the tool has for it, if a build ever prints them again.
    func testACancelIsRecognisedFromTheToolsOwnWords() {
        for said in [
            "No selection to capture. Cancelling\n",
            "screencapture: user canceled\n",
            "CANCELLED",
        ] {
            XCTAssertEqual(
                ScreenshotOutcome.of(bytes: nil, said: said, status: 1, screenAccess: true),
                .cancelled,
                "expected \(said.debugDescription) to read as a cancel"
            )
        }
    }

    /// **A cancel is a cancel even when the permission is missing**, and this is the one ordering this
    /// rule has. Measured: a process without the grant that is cancelled produces exactly the same
    /// answer as one that has it — silence and `0` — so a rule that consulted the permission first would
    /// tell that reader their Escape was a permission problem: the wrong sentence, about the wrong thing,
    /// at the moment they decided not to take a picture.
    func testACancelIsNotTurnedIntoAPermissionProblem() {
        XCTAssertEqual(
            ScreenshotOutcome.of(bytes: nil, said: "", status: 0, screenAccess: false),
            .cancelled
        )
        XCTAssertEqual(
            ScreenshotOutcome.of(
                bytes: nil,
                said: "No selection to capture. Cancelling\n",
                status: 0,
                screenAccess: false
            ),
            .cancelled
        )
    }

    // ── a failure ─────────────────────────────────────────────────────────

    /// The measured refusal: the tool speaks, exits non-zero, and there is no picture.
    ///
    /// Reported as a permission problem when we do not have the permission, because the sentence is a
    /// symptom and the permission is both the cause and the thing the reader can do something about.
    func testARefusalWithoutThePermissionIsThePermission() {
        XCTAssertEqual(
            ScreenshotOutcome.of(
                bytes: nil,
                said: "could not create image from rect\n",
                status: 1,
                screenAccess: false
            ),
            .refused(.permission)
        )
    }

    /// With the permission in hand, the tool's own sentence is the only thing there is to say — trimmed,
    /// because it is going into a dialog and not into a log.
    func testTheToolsSentenceIsTheDiagnosticWhenThereIsNoBetterOne() {
        XCTAssertEqual(
            ScreenshotOutcome.of(
                bytes: nil,
                said: "could not create image from rect\n",
                status: 1,
                screenAccess: true
            ),
            .refused(.other("could not create image from rect"))
        )
    }

    /// A tool that could not even be started is not a cancel: the failure to *run* comes back as a status
    /// that is neither `0` nor the tool's own, so it keeps its shape as an unexplained refusal.
    func testAToolThatCouldNotStartIsNotACancel() {
        XCTAssertEqual(
            ScreenshotOutcome.of(bytes: nil, said: "", status: -1, screenAccess: true),
            .refused(.other(""))
        )
    }
}
