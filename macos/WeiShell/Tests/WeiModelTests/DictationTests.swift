import XCTest

@testable import WeiModel

/// How a dictated sentence gets into the field, and what each way of ending it does to the text already
/// there.
///
/// The three endings are the whole point of the type, and they are checked here rather than in a window
/// because a window cannot say what a *cancel* should do — only a rule can, and then a test can hold it
/// to it. Audio, permissions and the field editor are all absent by construction.
final class DictationTests: XCTestCase {

    // ── the happy path ────────────────────────────────────────────────────

    /// A sentence is shown as it arrives, and settled when it ends.
    func testAPartialIsShownAndTheFinalSettlesIt() {
        var dictation = Dictation()
        dictation.beganListening()
        XCTAssertEqual(dictation.phase, .listening)

        XCTAssertEqual(dictation.heard("你"), .show("你"))
        XCTAssertEqual(dictation.heard("你好"), .show("你好"))
        XCTAssertEqual(dictation.heard("你好，帮我"), .show("你好，帮我"))

        dictation.stop()
        XCTAssertEqual(dictation.phase, .stopping)
        XCTAssertEqual(dictation.finished("你好，帮我改一下"), .settle("你好，帮我改一下"))
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(dictation.heard, "")
    }

    /// Every partial is the sentence *so far*, so showing one replaces the last — it never appends.
    func testAPartialThatRevisesReplacesWhatWasShown() {
        var dictation = Dictation()
        dictation.beganListening()
        XCTAssertEqual(dictation.heard("然后让他一边说"), .show("然后让他一边说"))
        // The recogniser changed its mind about a word it had already emitted. Measured, not invented:
        // this exact pair came out of a real recording.
        XCTAssertEqual(dictation.heard("然后让它一边说"), .show("然后让它一边说"))
    }

    /// The framework repeats a partial while it waits for more audio, and a repeat must not make the
    /// field redraw itself.
    func testARepeatedPartialIsNotASecondEffect() {
        var dictation = Dictation()
        dictation.beganListening()
        XCTAssertEqual(dictation.heard("你好"), .show("你好"))
        XCTAssertEqual(dictation.heard("你好"), .none)
        XCTAssertEqual(dictation.heard(""), .none)
    }

    /// The final result wins over the last partial, because it is the one the recogniser stands behind.
    func testTheFinalResultIsWhatIsSettled() {
        var dictation = Dictation()
        dictation.beganListening()
        _ = dictation.heard("然后让他一边说")
        XCTAssertEqual(dictation.finished("然后让它一边说"), .settle("然后让它一边说"))
    }

    /// A result that arrives with nothing in it settles the sentence as it stands rather than throwing
    /// away what the reader already watched arrive.
    func testAnEmptyFinalKeepsWhatWasHeard() {
        var dictation = Dictation()
        dictation.beganListening()
        _ = dictation.heard("你好")
        XCTAssertEqual(dictation.finished(""), .settle("你好"))
        XCTAssertEqual(dictation.phase, .listening, "a settled sentence ended the session")
    }

    /// An empty final *while still listening* is a no-op: the recogniser is still working and there is
    /// nothing to write. (After the reader stops, the same empty result is the end of the session — see
    /// `testStoppingWhileStartingEndsCleanly`.)
    func testAnEmptyFinalWithNothingHeardDoesNothing() {
        var dictation = Dictation()
        dictation.beganListening()
        XCTAssertEqual(dictation.finished(""), .none)
        XCTAssertEqual(dictation.phase, .listening)
    }

    // ── the three endings ─────────────────────────────────────────────────

    /// Cancelling takes the sentence back out, because that is what cancelling means.
    func testCancelDiscardsWhatWasHeard() {
        var dictation = Dictation()
        dictation.beganListening()
        _ = dictation.heard("你好，帮我删掉这个文件")
        XCTAssertEqual(dictation.cancel(), .discard)
        XCTAssertEqual(dictation.phase, .idle)
    }

    /// **A sentence that already settled is not taken back**, even by a cancel. By then it is ordinary
    /// text — the reader watched it finish — and removing it would be a surprise rather than an undo. A
    /// cancel mid-sentence is not tested that way above because there is nothing settled yet; this is the
    /// case where there is.
    func testCancelKeepsSentencesThatAlreadySettled() {
        var dictation = Dictation()
        dictation.beganListening()
        _ = dictation.finished("帮我加一个按钮")
        XCTAssertEqual(dictation.cancel(), .none, "a settled sentence was taken back out")
        XCTAssertEqual(dictation.phase, .idle)
    }

    /// **Trouble keeps the sentence.** The reader did not ask to lose it, and the microphone dying is
    /// not a reason to throw away words they just spoke.
    func testTroubleKeepsWhatWasHeard() {
        var dictation = Dictation()
        dictation.beganListening()
        _ = dictation.heard("你好，帮我改一下设")
        XCTAssertEqual(
            dictation.trouble(.microphoneNotPermitted),
            .settle("你好，帮我改一下设")
        )
        XCTAssertEqual(dictation.phase, .unavailable(.microphoneNotPermitted))
        XCTAssertEqual(dictation.trouble, .microphoneNotPermitted)
    }

    /// Trouble before anything was heard is not a failed sentence, it is a failure to start: nothing is
    /// written into the field and nothing is taken out of it.
    func testTroubleBeforeAnySpeechLeavesTheFieldAlone() {
        var dictation = Dictation()
        XCTAssertEqual(dictation.trouble(.modelMissing(locale: "zh_CN")), .none)
        XCTAssertEqual(dictation.phase, .unavailable(.modelMissing(locale: "zh_CN")))
        XCTAssertEqual(dictation.trouble, .modelMissing(locale: "zh_CN"))
    }

    /// Fixing the trouble (a granted permission, a downloaded model) makes it possible again.
    func testFixingTheTroubleClearsIt() {
        var dictation = Dictation()
        _ = dictation.trouble(.microphoneNotPermitted)
        XCTAssertTrue(dictation.trouble != nil)
        dictation.available()
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertNil(dictation.trouble)
    }

    // ── starting, and stopping before it finishes ─────────────────────────

    /// The model is loaded before the microphone opens, and that moment is a state.
    func testItIsStartingBeforeItIsListening() {
        var dictation = Dictation()
        dictation.beganStarting()
        XCTAssertEqual(dictation.phase, .starting)
        // Active, so a sentence spoken now is not thrown away and a send cannot race it...
        XCTAssertTrue(dictation.isActive)
        XCTAssertFalse(dictation.isListening)
        // ...but nothing is heard yet, so nothing is shown.
        XCTAssertEqual(dictation.heard("你好"), .show("你好"))
        dictation.beganListening()
        XCTAssertEqual(dictation.phase, .listening)
        XCTAssertTrue(dictation.isListening)
    }

    /// Stopping while the model is still loading is not a sentence: there is nothing to settle, and the
    /// session ends cleanly rather than sitting in `stopping` forever.
    func testStoppingWhileStartingEndsCleanly() {
        var dictation = Dictation()
        dictation.beganStarting()
        dictation.stop()
        XCTAssertEqual(dictation.phase, .stopping)
        // Nothing was heard, so there is nothing to write and nothing to take back.
        XCTAssertEqual(dictation.finished(""), .none)
        XCTAssertEqual(dictation.phase, .idle)
    }

    // ── late and out-of-order results ─────────────────────────────────────

    /// A result that arrives after the sentence ended describes a sentence that is over. Settling it
    /// again would type the same words twice.
    func testALateResultAfterTheEndIsIgnored() {
        var dictation = Dictation()
        dictation.beganListening()
        _ = dictation.heard("你好")
        dictation.stop()
        _ = dictation.finished("你好")
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(dictation.finished("你好，还有这个"), .none)
        XCTAssertEqual(dictation.heard("你好，还有这个"), .none)
    }

    /// …and the same after a cancel, which is the case that matters: the reader said no, and a partial
    /// still in flight from before must not put the sentence back.
    func testALatePartialAfterACancelIsIgnored() {
        var dictation = Dictation()
        dictation.beganListening()
        _ = dictation.heard("你好")
        XCTAssertEqual(dictation.cancel(), .discard)
        XCTAssertEqual(dictation.heard("你好，帮我改一下"), .none)
        XCTAssertEqual(dictation.phase, .idle)
    }

    /// Cancelling before anything arrived is not an error, and takes nothing out of the field.
    func testCancelWithNothingHeardTouchesNothing() {
        var dictation = Dictation()
        XCTAssertEqual(dictation.cancel(), .none)
    }

    /// `stop` only means something while listening: a second one, or one after the end, is not a state.
    func testStopOnlyAppliesWhileListening() {
        var dictation = Dictation()
        dictation.stop()
        XCTAssertEqual(dictation.phase, .idle)
        dictation.beganListening()
        dictation.stop()
        dictation.stop()
        XCTAssertEqual(dictation.phase, .stopping)
    }

    // ── recovering text the platform settled behind our back ──────────────

    /// The ordinary recovery: the sentence grew, so the growth is what still has to be typed.
    func testPendingAddsWhatTheSentenceGained() {
        XCTAssertEqual(Dictation.pending("你好，帮我", after: "你好"), "，帮我")
        XCTAssertEqual(Dictation.pending("你好", after: ""), "你好")
    }

    /// Nothing gained, nothing to add.
    func testPendingAddsNothingWhenThereIsNothingNew() {
        XCTAssertNil(Dictation.pending("你好", after: "你好"))
        XCTAssertNil(Dictation.pending("", after: ""))
    }

    /// A revision of text that has already been committed adds nothing, rather than typing the shared
    /// beginning a second time. One stale word reads better than a stutter.
    func testPendingAddsNothingForARevision() {
        XCTAssertNil(Dictation.pending("然后让它一边说", after: "然后让他一边说"))
    }
}
