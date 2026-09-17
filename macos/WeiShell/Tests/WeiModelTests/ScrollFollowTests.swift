import XCTest

@testable import WeiModel

/// When the transcript keeps up, and when it lets the reader read.
///
/// The interesting case is the third one: content arriving must never be what stops the following,
/// because content arriving is what moves the bottom away from the reader — so a rule that re-decided
/// on every measurement would stop on the first token of the first answer and never restart.
final class ScrollFollowTests: XCTestCase {
    func testItFollowsUntilTheReaderSaysOtherwise() {
        var follow = ScrollFollow()
        XCTAssertTrue(follow.following)
        // A turn's worth of growth changes nothing: only the reader moves the decision.
        follow.readerScrolled(up: false, atBottom: true)
        XCTAssertTrue(follow.following)
    }

    /// Scrolling up stops it, at the bottom or not.
    func testScrollingUpStopsFollowing() {
        var follow = ScrollFollow()
        follow.readerScrolled(up: true, atBottom: false)
        XCTAssertFalse(follow.following)
        // And from the bottom too: they are leaving it.
        var bottomed = ScrollFollow()
        bottomed.readerScrolled(up: true, atBottom: true)
        XCTAssertFalse(bottomed.following)
    }

    /// Scrolling back down restores it, but only once the end is in view.
    func testScrollingDownRestoresFollowingAtTheBottomOnly() {
        var follow = ScrollFollow(following: false)
        follow.readerScrolled(up: false, atBottom: false)
        XCTAssertFalse(follow.following, "following resumed a screen early")
        follow.readerScrolled(up: false, atBottom: true)
        XCTAssertTrue(follow.following)
    }

    /// Sending a prompt restores it, whatever the reader had been doing.
    func testSendingAPromptResumesFollowing() {
        var follow = ScrollFollow(following: false)
        follow.promptSent()
        XCTAssertTrue(follow.following)
    }
}
