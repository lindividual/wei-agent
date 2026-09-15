import XCTest

@testable import PiModel

/// The wire, from the side that reads it.
///
/// The JSON literals here are the same ones `macos/appffi/app_wbtest.mbt` asserts from the side
/// that writes them. Between the two, a field name has no unwatched edge: renaming one without the
/// other stops a build rather than producing a host that quietly ignores an event.
final class EventTests: XCTestCase {
    private func decode(_ line: String) -> PiEvent? {
        PiEvent.decode(line: line)
    }

    func testReadyCarriesTheSessionModelDirectoryAndKeySource() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"ready","session":"/tmp/s.jsonl","model":"DeepSeek V4 Flash (deepseek-v4-flash)","cwd":"/tmp","key":"missing"}"#
            )
        )
        guard case let .ready(session, model, cwd, key) = event else {
            return XCTFail("expected ready, got \(event)")
        }
        XCTAssertEqual(session, "/tmp/s.jsonl")
        XCTAssertEqual(model, "DeepSeek V4 Flash (deepseek-v4-flash)")
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(key, "missing")
    }

    func testAPieceNamesItsBlock() throws {
        let event = try XCTUnwrap(decode(#"{"kind":"reply","id":"reply-1","delta":"hi"}"#))
        guard case let .reply(id, delta) = event else {
            return XCTFail("expected reply, got \(event)")
        }
        XCTAssertEqual(id, "reply-1")
        XCTAssertEqual(delta, "hi")
    }

    func testAToolRowCarriesItsWholeState() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"tool","id":"tool-1","name":"bash","detail":"ls","done":false,"output":"","error":false}"#
            )
        )
        guard case let .tool(id, name, detail, done, output, isError) = event else {
            return XCTFail("expected tool, got \(event)")
        }
        XCTAssertEqual(id, "tool-1")
        XCTAssertEqual(name, "bash")
        XCTAssertEqual(detail, "ls")
        XCTAssertFalse(done)
        XCTAssertEqual(output, "")
        XCTAssertFalse(isError)
    }

    func testCountsDecodeAsIntegers() throws {
        let event = try XCTUnwrap(
            decode(#"{"kind":"end","text":"","calls":19,"tools":0,"cost":"0.0042"}"#)
        )
        guard case let .end(text, calls, tools, cost) = event else {
            return XCTFail("expected end, got \(event)")
        }
        XCTAssertEqual(text, "")
        XCTAssertEqual(calls, 19)
        XCTAssertEqual(tools, 0)
        XCTAssertEqual(cost, "0.0042")
    }

    /// An event the host cannot name is refused rather than half-read.
    ///
    /// A newer MoonBit side against an older app is the case: the alternative is a transcript that
    /// silently drops the events it does not understand, which reads as a turn that stalled.
    func testAnUnknownKindIsRefused() {
        XCTAssertNil(decode(#"{"kind":"something-new","text":"hi"}"#))
    }

    func testGarbageIsNotAnEvent() {
        XCTAssertNil(decode("not json at all"))
        XCTAssertNil(decode(""))
    }
}
