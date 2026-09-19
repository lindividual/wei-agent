import XCTest

@testable import WeiModel

/// The wire, from the side that reads it.
///
/// The JSON literals here are the same ones `macos/appffi/app_wbtest.mbt` asserts from the side
/// that writes them. Between the two, a field name has no unwatched edge: renaming one without the
/// other stops a build rather than producing a host that quietly ignores an event.
final class EventTests: XCTestCase {
    private func decode(_ line: String) -> ShellEvent? {
        ShellEvent.decode(line: line)
    }

    /// The shell is up, which session it is about, and where its key came from.
    ///
    /// The path is the *routing* field now rather than a payload field, so this also pins the one thing
    /// that changed shape: the session is read from the envelope, and the payload is the three facts
    /// about it.
    func testReadyNamesTheModelDirectoryAndKeySource() throws {
        let envelope = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"ready","session":"/tmp/s.jsonl","model":"DeepSeek V4 Flash (deepseek-v4-flash)","cwd":"/tmp","key":"missing"}"#
            )
        )
        XCTAssertEqual(envelope.session, "/tmp/s.jsonl")
        guard case let .ready(model, cwd, key) = envelope.event else {
            return XCTFail("expected ready, got \(envelope.event)")
        }
        XCTAssertEqual(model, "DeepSeek V4 Flash (deepseek-v4-flash)")
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(key, "missing")
    }

    /// The field that makes two conversations at once possible: which session an event belongs to.
    ///
    /// Pinned from the reading side, against the literals `macos/appffi/app_wbtest.mbt` asserts from the
    /// writing side. A host that dropped this on the floor would write one conversation's answer into
    /// another's transcript — which is invisible until two turns are running.
    func testEveryTurnEventSaysWhichSessionItIsAbout() throws {
        let lines = [
            #"{"kind":"reply","session":"/store/a.jsonl","id":"reply-1-1","delta":"hi"}"#,
            #"{"kind":"thinking","session":"/store/a.jsonl","id":"thinking-1-1","delta":"hm"}"#,
            #"{"kind":"user","session":"/store/a.jsonl","text":"go","continued":false}"#,
            #"{"kind":"status","session":"/store/a.jsonl","text":"thinking…"}"#,
            #"{"kind":"end","session":"/store/a.jsonl","text":"","calls":1,"tools":0,"cost":"0.01"}"#,
            #"{"kind":"error","session":"/store/a.jsonl","text":"no"}"#,
            #"{"kind":"blocks","session":"/store/a.jsonl","id":"reply-1-1","blocks":[]}"#,
            #"{"kind":"tool","session":"/store/a.jsonl","id":"tool-1-1","name":"bash","detail":"ls","done":false,"output":"","error":false}"#,
            #"{"kind":"note","session":"/store/a.jsonl","text":"summary","name":"context compacted"}"#,
            #"{"kind":"usage","session":"/store/a.jsonl","turns":1,"total":10,"input":10,"output":0,"cache_read":0,"cache_write":0,"prompt":10,"window":1000,"cost":"0.000000","cost_input":"0.000000","cost_output":"0.000000","cost_cache_read":"0.000000","cost_cache_write":"0.000000"}"#,
            #"{"kind":"images","session":"/store/a.jsonl","items":[],"can_send":true}"#,
            #"{"kind":"models","session":"/store/a.jsonl","items":[],"current":"deepseek-v4-flash"}"#,
        ]
        for line in lines {
            let envelope = try XCTUnwrap(Envelope.decode(line: line), "did not decode: \(line)")
            XCTAssertEqual(envelope.session, "/store/a.jsonl", "no session on: \(line)")
        }
    }

    /// No session means the one on screen. That is the rule for the answers to something the reader just
    /// did to the session they are looking at, and it is what keeps those events from having to name a
    /// path they would only repeat.
    func testAnEventWithNoSessionIsAboutTheOneOnScreen() throws {
        let envelope = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"error","text":"no session at /nope.jsonl"}"#
            )
        )
        XCTAssertEqual(envelope.session, "")
        guard case let .error(text) = envelope.event else {
            return XCTFail("expected error, got \(envelope.event)")
        }
        XCTAssertEqual(text, "no session at /nope.jsonl")
    }

    /// The conversation that was deleted: the path that puts it back, and whether there is one.
    ///
    /// This event is the one place a *click's outcome* travels: the shell refuses a delete with work
    /// going on in the session, and it replaces the session on screen rather than refusing that — so the
    /// host cannot know from the click alone whether a file moved, or which one. The offer to undo is
    /// drawn from here, and its Undo button sends this path back.
    ///
    /// `restorable` is the checkbox: the same event carries a delete that renamed the file aside and one
    /// that removed it, and only this field tells them apart. The literals are the ones
    /// `macos/appffi/app_wbtest.mbt` asserts from the writing side.
    func testADeletedSessionCarriesThePathToRestoreIt() throws {
        let kept = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"deleted","session":"/store/a.jsonl","path":"/store/a.jsonl","label":"set up the project","restorable":true}"#
            )
        )
        // Routed by the session that went, which is no longer in the list — the offer has to be told
        // apart from an event about the conversation the window has already moved to.
        XCTAssertEqual(kept.session, "/store/a.jsonl")
        guard case let .deleted(path, label, restorable) = kept.event else {
            return XCTFail("expected deleted, got \(kept.event)")
        }
        XCTAssertEqual(path, "/store/a.jsonl")
        XCTAssertEqual(label, "set up the project")
        XCTAssertTrue(restorable)

        // The purge: the same event with the one field that says there is nothing to put back.
        let gone = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"deleted","session":"/store/a.jsonl","path":"/store/a.jsonl","label":"set up the project","restorable":false}"#
            )
        )
        guard case let .deleted(_, _, goneRestorable) = gone.event else {
            return XCTFail("expected deleted, got \(gone.event)")
        }
        XCTAssertFalse(goneRestorable)
    }

    /// A shell that predates the checkbox only ever renamed the file aside, so an event without the
    /// field still means "there is a way back". A missing field that decoded as `false` would silently
    /// remove the Undo button against an older shell, which is the kind of disagreement this whole
    /// read-the-names-by-hand arrangement exists to catch.
    func testADeletedSessionFromAnOlderShellIsStillRestorable() throws {
        let envelope = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"deleted","session":"/store/a.jsonl","path":"/store/a.jsonl","label":"set up the project"}"#
            )
        )
        guard case let .deleted(_, _, restorable) = envelope.event else {
            return XCTFail("expected deleted, got \(envelope.event)")
        }
        XCTAssertTrue(restorable)
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

    // MARK: - the composer's own wire

    /// The two lines under the composer, against the same literals MoonBit asserts.
    ///
    /// The names here are the contract: `macos/appffi/app_wbtest.mbt` pins them from the side that
    /// writes them, and a rename only one side noticed would be a composer that draws nothing under
    /// itself, or a model picker with no entries.
    func testImagesCarryTheirPathsMimeTypesAndBytes() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"images","items":[{"path":"/tmp/shot.png","mime":"image/png","data":"aGk="}],"can_send":false}"#
            )
        )
        guard case let .images(items, canSend) = event else {
            return XCTFail("expected images, got \(event)")
        }
        XCTAssertFalse(canSend)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].path, "/tmp/shot.png")
        XCTAssertEqual(items[0].mime, "image/png")
        XCTAssertEqual(items[0].data, "aGk=")
        // The row's identity is the path, because that is what a remove names.
        XCTAssertEqual(items[0].id, "/tmp/shot.png")
        // And what to draw: the file name, which is what the reader picked.
        XCTAssertEqual(items[0].name, "shot.png")
    }

    func testTheUsageEventCarriesTheTotalsTheContextAndTheLastTurn() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"usage","turns":3,"total":2340,"input":1200,"output":340,"cache_read":800,"cache_write":0,"reasoning":60,"prompt":2000,"context":2400,"context_source":"provider","overhead":1300,"window":128000,"compact_soon":false,"cost":"0.000928","cost_input":"0.000240","cost_output":"0.000680","cost_cache_read":"0.000008","cost_cache_write":"0.000000","cache_hit":"40","last_model_calls":2,"last_tool_calls":1,"last_total":1200,"last_input":900,"last_output":300,"last_cache_read":800,"last_reasoning":45,"last_cost":"0.000500"}"#
            )
        )
        guard case let .usage(usage) = event else {
            return XCTFail("expected usage, got \(event)")
        }
        XCTAssertEqual(usage.turns, 3)
        XCTAssertEqual(usage.total, 2340)
        XCTAssertEqual(usage.reasoning, 60)
        XCTAssertEqual(usage.prompt, 2000)
        XCTAssertEqual(usage.context, 2400)
        XCTAssertEqual(usage.overhead, 1300)
        XCTAssertEqual(usage.window, 128_000)
        XCTAssertFalse(usage.compactSoon)
        XCTAssertEqual(usage.cost, "0.000928")
        XCTAssertEqual(usage.cacheHit, "40")
        XCTAssertTrue(usage.contextIsMeasured)
        let last = try XCTUnwrap(usage.last)
        XCTAssertEqual(last.modelCalls, 2)
        XCTAssertEqual(last.toolCalls, 1)
        XCTAssertEqual(last.cacheRead, 800)
        XCTAssertEqual(last.reasoning, 45)
        XCTAssertEqual(last.cost, "0.000500")
        // The **next** request against the window, not the last one: 2400 of 128000, when the
        // measurement behind it was 2000. The ring answers "how close is this conversation to being
        // summarized", so it has to move with what has been appended since the last reply.
        XCTAssertEqual(try XCTUnwrap(usage.contextFill), 2400.0 / 128_000.0, accuracy: 1e-9)
    }

    /// A payload from before the context fields existed still decodes, and says it is a guess.
    ///
    /// The version skew this file exists to catch: the shell and the window are built separately, and
    /// a window that refused a usage event for a missing field would show no figures at all rather
    /// than slightly old ones. The figure falls back to the measured prompt, which is the honest
    /// answer available when the shell does not send a better one.
    func testAnOlderUsagePayloadStillDecodes() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"usage","turns":1,"total":10,"input":10,"output":0,"cache_read":0,"cache_write":0,"prompt":10,"window":1000,"cost":"0.000000","cost_input":"0.000000","cost_output":"0.000000","cost_cache_read":"0.000000","cost_cache_write":"0.000000"}"#
            )
        )
        guard case let .usage(usage) = event else {
            return XCTFail("expected usage, got \(event)")
        }
        XCTAssertEqual(usage.context, 0)
        XCTAssertEqual(usage.overhead, 0)
        XCTAssertEqual(usage.reasoning, 0)
        XCTAssertFalse(usage.compactSoon)
        // The last request's own measured size rather than zero, and still a measurement: `prompt` is
        // what the provider reported, which is why the fallback is worth having.
        XCTAssertEqual(usage.contextFigure, 10)
        XCTAssertTrue(usage.contextIsMeasured)
        XCTAssertEqual(try XCTUnwrap(usage.contextFill), 10.0 / 1000.0, accuracy: 1e-9)
    }

    /// A window that is nearly full says so.
    func testANearlyFullContextIsMarkedForCompaction() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"usage","turns":1,"total":0,"input":0,"output":0,"cache_read":0,"cache_write":0,"prompt":0,"context":120000,"context_source":"estimated","overhead":1300,"window":128000,"compact_soon":true,"cost":"0.000000","cost_input":"0.000000","cost_output":"0.000000","cost_cache_read":"0.000000","cost_cache_write":"0.000000"}"#
            )
        )
        guard case let .usage(usage) = event else {
            return XCTFail("expected usage, got \(event)")
        }
        XCTAssertTrue(usage.compactSoon)
        XCTAssertFalse(usage.contextIsMeasured, "an estimate is not a measurement")
        XCTAssertEqual(try XCTUnwrap(usage.contextFill), 120_000.0 / 128_000.0, accuracy: 1e-9)
    }

    /// A session with nothing in it says so by leaving fields out.
    ///
    /// `cache_hit` is absent rather than `"0"` because a share of no prompt is not a figure, and the
    /// last turn's fields are absent rather than zeroes because a turn that has not happened has no
    /// cost. Both are drawn as nothing at all.
    func testTheUsageEventOmitsWhatHasNotHappened() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"usage","turns":0,"total":0,"input":0,"output":0,"cache_read":0,"cache_write":0,"prompt":0,"window":128000,"cost":"0.000000","cost_input":"0.000000","cost_output":"0.000000","cost_cache_read":"0.000000","cost_cache_write":"0.000000"}"#
            )
        )
        guard case let .usage(usage) = event else {
            return XCTFail("expected usage, got \(event)")
        }
        XCTAssertNil(usage.cacheHit)
        XCTAssertNil(usage.last)
        XCTAssertNil(usage.contextFill, "an empty context is not a ring at zero")
    }

    func testTheModelCatalogSaysWhatCanBeCalledAndWhatIsInForce() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"models","items":[{"id":"deepseek-v4-flash","label":"DeepSeek V4 Flash (deepseek-v4-flash)","vision":true},{"id":"deepseek-v3","label":"deepseek-v3","vision":false}],"current":"deepseek-v3"}"#
            )
        )
        guard case let .models(catalog) = event else {
            return XCTFail("expected models, got \(event)")
        }
        XCTAssertEqual(catalog.items.count, 2)
        XCTAssertEqual(catalog.current, "deepseek-v3")
        XCTAssertEqual(catalog.currentLabel, "deepseek-v3")
        XCTAssertFalse(try XCTUnwrap(catalog.currentChoice).vision)
    }

    /// A session whose log names a model this build does not have is shown by its id rather than as
    /// a blank.
    func testAModelThisBuildDoesNotHaveStillHasAName() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"models","items":[],"current":"some-future-model"}"#
            )
        )
        guard case let .models(catalog) = event else {
            return XCTFail("expected models, got \(event)")
        }
        XCTAssertEqual(catalog.currentLabel, "some-future-model")
        XCTAssertNil(catalog.currentChoice)
    }
    // MARK: - background jobs

    /// The jobs panel's wire: only live work, and only the processes still behind it.
    ///
    /// Pinned against the same literal `macos/appffi/app_wbtest.mbt` asserts from the producing side.
    /// The pids matter as much as the job: the shell filters them to the ones the process table still
    /// knows, so a reader looking in `ps` is given something they can find.
    func testJobsCarryTheirLabelStatusAgeAndPids() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"jobs","items":[{"id":"bash-1","kind":"bash","label":"sleep 300","status":"running","age_ms":5000,"pids":[101],"session":"/store/s.jsonl"}]}"#
            )
        )
        guard case let .jobs(items) = event else {
            return XCTFail("expected jobs, got \(event)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "bash-1")
        XCTAssertEqual(items[0].label, "sleep 300")
        XCTAssertFalse(items[0].isStopping)
        XCTAssertEqual(items[0].pids, [101])
        XCTAssertEqual(items[0].ageMS, 5000)
        // The age as a reader reads it: the two units that matter, not milliseconds.
        XCTAssertEqual(items[0].age(), "5s")
    }

    func testAnEmptyJobsEventIsStillAnEvent() throws {
        let event = try XCTUnwrap(decode(#"{"kind":"jobs","items":[]}"#))
        guard case let .jobs(items) = event else {
            return XCTFail("expected jobs, got \(event)")
        }
        XCTAssertTrue(items.isEmpty)
    }

    /// A stop that has been sent but has not landed says so, because that is the state a reader is
    /// waiting on.
    func testAStoppingJobSaysSo() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"jobs","items":[{"id":"bash-1","kind":"bash","label":"python -m http.server","status":"stopping","age_ms":65000,"pids":[],"session":"/s.jsonl"}]}"#
            )
        )
        guard case let .jobs(items) = event else {
            return XCTFail("expected jobs, got \(event)")
        }
        XCTAssertTrue(items[0].isStopping)
        XCTAssertTrue(items[0].pids.isEmpty)
        // A minute and five seconds, said the way the panel says it.
        XCTAssertEqual(items[0].age(), "1m 5s")
    }

    /// A compaction arrives as a labelled row, and the label is what keeps it from reading as prose.
    ///
    /// The same literal `macos/appffi/app_wbtest.mbt` asserts from the producing side. The label is
    /// optional on the wire so an older shell's unlabelled note still decodes — and draws as the
    /// paragraph it always was.
    func testANoteCarriesItsLabelAndStillDecodesWithoutOne() throws {
        let labelled = try XCTUnwrap(
            decode(#"{"kind":"note","text":"they asked for a parser","name":"context compacted"}"#)
        )
        guard case let .note(text, label) = labelled else {
            return XCTFail("expected note, got \(labelled)")
        }
        XCTAssertEqual(text, "they asked for a parser")
        XCTAssertEqual(label, "context compacted")

        let bare = try XCTUnwrap(decode(#"{"kind":"note","text":"1 model call · $0.001"}"#))
        guard case let .note(text, label) = bare else {
            return XCTFail("expected note, got \(bare)")
        }
        XCTAssertEqual(label, "")
    }

    /// A compacted note lands where the compacting happened, and settles what is above it.
    func testACompactionBecomesARowAndEndsTheBlockBeforeIt() {
        var conversation = Conversation()
        for line in [
            #"{"kind":"reply","id":"reply-1-1","delta":"working on it"}"#,
            #"{"kind":"note","text":"earlier work summarized","name":"context compacted"}"#,
            #"{"kind":"reply","id":"reply-1-2","delta":"done"}"#,
        ] {
            guard let event = ShellEvent.decode(line: line) else {
                return XCTFail("undecodable: \(line)")
            }
            conversation.apply(event)
        }
        XCTAssertEqual(conversation.rows.map(\.kind), [.reply, .note, .reply])
        // The row above is finished: the summary is a different thing from the answer around it.
        XCTAssertTrue(conversation.rows[0].complete)
        XCTAssertEqual(conversation.rows[1].name, "context compacted")
        XCTAssertTrue(conversation.rows[1].complete)
    }
}
