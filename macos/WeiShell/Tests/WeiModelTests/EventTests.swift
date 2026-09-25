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
        guard case let .error(text, endsTurn) = envelope.event else {
            return XCTFail("expected error, got \(envelope.event)")
        }
        XCTAssertEqual(text, "no session at /nope.jsonl")
        // And a line with no `endsTurn` — which is every error a shell older than the field sent — is read
        // as "the turn is still running" rather than as the end of one. That is what keeps an old shell's
        // error from putting Stop away: see `ShellEvent.error`.
        XCTAssertFalse(endsTurn)
    }

    /// The one error that *is* the end of a turn, and the flag the host draws Stop from.
    ///
    /// The bug this pins: the host cleared `running` on **every** error, so a jobs file that could not be
    /// recorded — written on a two-second timer — took the Stop button away from a reader whose turn was
    /// still going, and the only way out was to wait. The shell knows which errors end a turn and the host
    /// cannot, so the flag travels.
    func testOnlyTheErrorsThatEndATurnSaySo() throws {
        let ends = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"error","session":"/store/b.jsonl","text":"the turn failed: boom","endsTurn":true}"#
            )
        )
        guard case let .error(_, endsTurn) = ends.event else {
            return XCTFail("expected error, got \(ends.event)")
        }
        XCTAssertTrue(endsTurn)

        let beside = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"error","session":"/store/b.jsonl","text":"could not record background jobs","endsTurn":false}"#
            )
        )
        guard case let .error(_, besideTurn) = beside.event else {
            return XCTFail("expected error, got \(beside.event)")
        }
        XCTAssertFalse(besideTurn)
    }

    /// A turn that ended in **another** conversation, as a kind of its own.
    ///
    /// The distinction this pins is the fix for a window that used to jump: `session` means "this one is
    /// now on screen" and the host answers it by swapping transcripts, so a turn finishing in a session
    /// nobody had open moved the reader. This event carries the same routing — which session it is about —
    /// and none of the meaning "show it": the path is there to be opened *on request*, and the outcome is
    /// a token this side turns into words.
    func testATurnEndingElsewhereNamesTheSessionWithoutSwitchingToIt() throws {
        let envelope = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"elsewhere","session":"/store/b.jsonl","path":"/store/b.jsonl","outcome":"finished"}"#
            )
        )
        XCTAssertEqual(envelope.session, "/store/b.jsonl")
        guard case let .elsewhere(path, outcome) = envelope.event else {
            return XCTFail("expected elsewhere, got \(envelope.event)")
        }
        XCTAssertEqual(path, "/store/b.jsonl")
        XCTAssertEqual(outcome, "finished")

        // A shell of the same generation always sends both fields; a missing outcome is read as an
        // unknown one rather than as an undecodable line, because the fact that a turn ended somewhere
        // is worth saying even when the word for how is missing.
        let bare = try XCTUnwrap(
            Envelope.decode(
                line: #"{"kind":"elsewhere","session":"/store/b.jsonl","path":"/store/b.jsonl"}"#
            )
        )
        guard case let .elsewhere(_, noOutcome) = bare.event else {
            return XCTFail("expected elsewhere, got \(bare.event)")
        }
        XCTAssertEqual(noOutcome, "")
        XCTAssertEqual(SessionNotice.Outcome(wire: noOutcome).word, "ended")
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
                #"{"kind":"models","unit":"US dollars per million tokens — in · out · cached","items":[{"id":"deepseek-v4-flash","label":"DeepSeek V4 Flash","vision":true,"prices":{"input":"0.14","output":"0.28","cached":"0.0028"}},{"id":"deepseek-v3","label":"deepseek-v3","vision":false}],"current":"deepseek-v3"}"#
            )
        )
        guard case let .models(catalog) = event else {
            return XCTFail("expected models, got \(event)")
        }
        XCTAssertEqual(catalog.items.count, 2)
        XCTAssertEqual(catalog.current, "deepseek-v3")
        XCTAssertEqual(catalog.currentLabel, "deepseek-v3")
        XCTAssertFalse(try XCTUnwrap(catalog.currentChoice).vision)
        // The unit is one line for the whole menu, which is what makes the rows three bare numbers
        // instead of three numbers each carrying a symbol.
        XCTAssertEqual(catalog.unit, "US dollars per million tokens — in · out · cached")
        // And a model's prices arrive cut to their column, which is what lines the menu up.
        XCTAssertEqual(try XCTUnwrap(catalog.items.first).prices, ModelPrices(input: "0.14", output: "0.28", cached: "0.0028"))
        // **A model the shell sent no prices for is dashes, not zeroes.** An older shell, or a row
        // whose numbers were left out: either way the menu must not price a model at nothing.
        XCTAssertEqual(try XCTUnwrap(catalog.items.last).prices, .unknown)
        XCTAssertEqual(ModelPrices.unknown.input, "—")
    }

    /// The exact literal `macos/appffi/app_wbtest.mbt` produces, field for field.
    ///
    /// The same event as above with the real catalog in it: three rows whose price columns are the
    /// same width, which is the invariant the menu is built on and the one thing a JSON reader cannot
    /// check for itself. `0.14` / `0.30` / `1.32` are all four characters, and the cached column is six
    /// on every row.
    func testTheModelMenuCarriesPricesCutToTheirColumn() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"models","session":"/tmp/s.jsonl","items":[{"id":"deepseek-v4-flash","label":"DeepSeek V4 Flash","vision":true,"prices":{"input":"0.14","output":"0.28","cached":"0.0028"}},{"id":"deepseek-flash","label":"DeepSeek V4.1 Flash","vision":true,"prices":{"input":"0.30","output":"1.20","cached":"0.0060"}},{"id":"deepseek-v4-pro","label":"DeepSeek V4 Pro","vision":false,"prices":{"input":"1.32","output":"3.96","cached":"0.0440"}}],"current":"deepseek-v4-flash","unit":"US dollars per million tokens — in · out · cached"}"#
            )
        )
        guard case let .models(catalog) = event else {
            return XCTFail("expected models, got \(event)")
        }
        let columns = catalog.items.map { ($0.prices.input, $0.prices.output, $0.prices.cached) }
        XCTAssertEqual(columns.map(\.0).map(\.count), [4, 4, 4])
        XCTAssertEqual(columns.map(\.1).map(\.count), [4, 4, 4])
        XCTAssertEqual(columns.map(\.2).map(\.count), [6, 6, 6])
        // The label is the name: no id, which is what keeps the row narrow enough for the prices.
        XCTAssertEqual(catalog.items.map(\.label), ["DeepSeek V4 Flash", "DeepSeek V4.1 Flash", "DeepSeek V4 Pro"])
        XCTAssertEqual(catalog.items.map(\.id), ["deepseek-v4-flash", "deepseek-flash", "deepseek-v4-pro"])
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

    /// The thinking menu's wire, decoded from the same literal `app_wbtest.mbt` produces.
    ///
    /// The levels are the *model's*: `low` is here because flash has it, and the pro model's menu —
    /// the same event with a shorter list — does not offer it, which is the fact that makes this a
    /// separate event rather than a list on this side.
    func testTheThinkingMenuOffersThisModelsLevels() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"think","session":"/tmp/s.jsonl","items":[{"id":"off","label":"Off","detail":"fastest and cheapest; answers may be shallower","default":false},{"id":"low","label":"Low","detail":"thinks briefly; a sooner first word","default":false},{"id":"high","label":"High","detail":"thinks before answering","default":true},{"id":"max","label":"Max","detail":"thinks longest; slowest and dearest","default":false}],"current":"high"}"#
            )
        )
        guard case let .think(levels) = event else {
            return XCTFail("expected think, got \(event)")
        }
        XCTAssertEqual(levels.items.map(\.id), ["off", "low", "high", "max"])
        XCTAssertEqual(levels.current, "high")
        XCTAssertEqual(levels.currentLabel, "High")
        XCTAssertEqual(levels.currentLevel?.isDefault, true)
        XCTAssertTrue(levels.isOffered)
        // The sentence is the shell's, and it arrives whole: a host that wrote its own would be a
        // second opinion about what a level means.
        XCTAssertEqual(levels.items[1].detail, "thinks briefly; a sooner first word")
    }

    /// A level this build has never heard of is still shown, by the name the shell sent.
    ///
    /// This is not a hypothetical: a session's level is recorded in its log, so a build that quietly
    /// stops recognising one would otherwise draw an unticked menu over a session that is really
    /// running at it.
    func testALevelThisBuildDoesNotKnowStillHasAName() throws {
        let event = try XCTUnwrap(
            decode(
                #"{"kind":"think","items":[],"current":"paranoid"}"#
            )
        )
        guard case let .think(levels) = event else {
            return XCTFail("expected think, got \(event)")
        }
        XCTAssertEqual(levels.currentLabel, "paranoid")
        XCTAssertNil(levels.currentLevel)
        // And before the shell has said anything the menu is not offered at all, rather than offered
        // empty: a control with nothing to pick is a control that looks broken.
        XCTAssertFalse(levels.isOffered)
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
