import XCTest

@testable import WeiModel

/// What the line under the composer says about the session.
///
/// A sentence rather than a number, so the parts that can be wrong are the ones a test can hold: which
/// figures appear, in what order, and — the case worth the file — which of them are left out. A line
/// that printed `0 thinking` for a provider that does not report thinking bytes would be a claim about
/// the conversation drawn from a fact about the provider.
final class UsageSummaryTests: XCTestCase {
    /// A session's figures, taken through the wire rather than built by hand.
    ///
    /// The literal is assembled from the four numbers that vary so that each test states only what it is
    /// about — and it goes through the same decoding the window uses, so a sentence this asserts is a
    /// sentence the reader can actually get.
    private func usage(
        turns: Int,
        input: Int,
        output: Int,
        reasoning: Int = 0
    ) throws -> Usage {
        let line = #"""
        {"kind":"usage","turns":\#(turns),"total":\#(input + output),"input":\#(input),"output":\#(output),"cache_read":0,"cache_write":0,"reasoning":\#(reasoning),"prompt":0,"context":0,"context_source":"estimated","overhead":1300,"window":128000,"compact_soon":false,"cost":"0.000000","cost_input":"0.000000","cost_output":"0.000000","cost_cache_read":"0.000000","cost_cache_write":"0.000000"}
        """#
        guard case let .usage(usage)? = ShellEvent.decode(line: line) else {
            throw XCTSkip("the usage literal did not decode")
        }
        return usage
    }

    /// The whole sentence, in the order a reader reads it: how many calls, then the tokens they
    /// bought, then the part of them that is invisible in the answers.
    func testTheSessionSentenceCountsTheCallsTheTokensAndTheThinking() throws {
        let summary = try usage(turns: 728, input: 2_480_985, output: 530_457, reasoning: 290_847).sessionSummary
        XCTAssertEqual(summary, "728 model calls · 2.5M in / 530.5k out · 290.8k thinking")
    }

    /// One call is one call.
    ///
    /// The plural is the whole of this test and it is not cosmetic: `1 model calls` is the kind of line
    /// that makes a reader stop trusting every number on it.
    func testOneCallIsSingular() throws {
        let summary = try usage(turns: 1, input: 900, output: 300).sessionSummary
        XCTAssertEqual(summary, "1 model call · 900 in / 300 out")
    }

    /// A provider that does not report thinking does not get a zero for it.
    ///
    /// Unlike a cache read — where nothing means nothing — this one is a fact about the provider, and
    /// `0 thinking` would claim the model did none.
    func testThinkingIsLeftOutWhenThereIsNone() throws {
        let summary = try usage(turns: 3, input: 1200, output: 340).sessionSummary
        XCTAssertEqual(summary, "3 model calls · 1.2k in / 340 out")
        XCTAssertFalse(summary.contains("thinking"))
    }

    /// A session that has asked nothing says nothing.
    ///
    /// The same rule the ring follows, and for the same reason: `0 model calls · 0 in / 0 out` is a
    /// line of zeroes that reads as a statement about a turn rather than as the absence of one.
    func testASessionWithNoRepliesSaysNothingAtAll() throws {
        let summary = try usage(turns: 0, input: 0, output: 0).sessionSummary
        XCTAssertEqual(summary, "")
    }
}
