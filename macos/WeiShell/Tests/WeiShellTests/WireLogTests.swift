import XCTest

@testable import WeiKit

/// The wire log's one job under load: stay readable when a picture goes past.
///
/// The attachment bytes are megabytes of base64 in a single JSON line, and the log is opt-in — which
/// means the person reading it is debugging something and got the one screenshot that makes the file
/// unopenable. These assert the two halves of the rule: a payload is replaced by its length, and
/// everything else on the line survives, because the field names around it are what is being read.
final class WireLogTests: XCTestCase {
    func testAnAttachmentPayloadIsReplacedByItsLength() {
        let payload = String(repeating: "A", count: 4096)
        let line =
            #"{"kind":"images","items":[{"path":"/tmp/shot.png","mime":"image/png","data":"\#(payload)"}],"can_send":true}"#
        let elided = WireLog.elided(line)
        XCTAssertFalse(elided.contains(payload), "the bytes are still in the log")
        XCTAssertTrue(elided.contains("<4096 bytes of base64>"), elided)
        // The facts around it are what a wire log is read for, and they are untouched.
        XCTAssertTrue(elided.contains(#""path":"/tmp/shot.png""#), elided)
        XCTAssertTrue(elided.contains(#""can_send":true"#), elided)
    }

    func testAShortValueIsLeftAlone() {
        // A fixture, or a thumbnail: rewriting it would hide exactly what a test would look at.
        let line = #"{"kind":"images","items":[{"path":"a","mime":"image/png","data":"aGk="}]}"#
        XCTAssertEqual(WireLog.elided(line), line)
    }

    func testEveryOtherEventIsUntouched() {
        let line = #"{"kind":"usage","turns":3,"total":2340,"cost":"0.000928"}"#
        XCTAssertEqual(WireLog.elided(line), line)
        // A prompt with the word data in it is not a payload.
        let prompt = #"{"kind":"user","text":"what does data mean here"}"#
        XCTAssertEqual(WireLog.elided(prompt), prompt)
        // And a `data` field with no closing quote is left as it is rather than mangled, because a
        // half-written line is a thing a wire log exists to show.
        let truncated = #"{"kind":"images","items":[{"data":"AAAA"#
        XCTAssertEqual(WireLog.elided(truncated), truncated)
    }
}
