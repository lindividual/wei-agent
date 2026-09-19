///|
/// Decisions that name a wrong answer
///
/// Each of these pins a rule whose comment already says what the *mistake* looks like. That is the
/// most valuable kind of test to write and the easiest to see the gap in: whoever wrote the comment
/// knew the failure mode, and had no way to get a machine to watch for it.

///|
/// A log with one model and one level recorded, or neither.
fn log_of(model : String?, level : String?) -> @core.Session {
  let entries : Array[@core.Entry] = []
  let mut parent : String? = None
  if model is Some(id) {
    entries.push(@core.Entry::{
      id: "m",
      parent_id: parent,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.ModelChange(provider="deepseek", model_id=id),
    })
    parent = Some("m")
  }
  if level is Some(name) {
    entries.push(@core.Entry::{
      id: "l",
      parent_id: parent,
      timestamp: @core.format_iso_utc(0L),
      kind: @core.ThinkingLevelChange(level=name),
    })
  }
  @core.Session::new(
    {
      id: "s",
      timestamp: @core.format_iso_utc(0L),
      cwd: "/tmp",
      parent_session: None,
      version: Some(3),
    },
    entries,
  )
}

///|
/// The model travels as the **two-part spelling**, and an id this build does not know travels as
/// itself.
///
/// The second half is the named mistake: `model_spec_for` answers with the *default's* spec for an
/// unknown id, so the old single-call version drew `DeepSeek V4 Flash` over a log that said
/// `deepseek-v9` — a window confidently naming a model the session is not running on. Which is worse
/// than showing an ugly id, because there is nothing on screen to suggest anything is wrong.
test "an unknown model id is shown as itself, not as the default's name" {
  let open = Open::new(
    "/tmp/s.jsonl",
    "/tmp",
    "deepseek-v4-pro",
    "high",
    log_of(None, None),
  )
  inspect(model_name(open), content="DeepSeek V4 Pro (deepseek-v4-pro)")
  open.model_id = "deepseek-v9"
  inspect(model_name(open), content="deepseek-v9")
}

///|
/// A resumed session runs on **what its log recorded**, not on the build's default.
///
/// The mistake is priced rather than cosmetic: a session last run on the pro model, reopened on the
/// default, silently answers its old questions at a different model's rates.
test "a resumed session's model is the one its log recorded" {
  inspect(
    session_model(log_of(Some("deepseek-v4-pro"), None)),
    content="deepseek-v4-pro",
  )
  // Nothing recorded: a session nobody has asked anything of yet is the one place the default is
  // the honest answer.
  inspect(session_model(log_of(None, None)), content=@core.default_model_id())
}

///|
/// A level the session's model does not have is settled to one it does — per model, not per
/// provider.
///
/// This is `model_catalog.mbt`'s own example, end to end: `deepseek-v4-pro` has no `low`, so a log
/// that recorded one is asking for an effort the API would reject. Answering with the level that
/// will really be used is what keeps a resumed session honest.
test "a recorded level is settled against the model that will run" {
  // `low` exists on flash and not on pro, so the same log means two different things.
  inspect(
    session_level(
      log_of(Some("deepseek-v4-flash"), Some("low")),
      "deepseek-v4-flash",
    ),
    content="low",
  )
  inspect(
    session_level(
      log_of(Some("deepseek-v4-flash"), Some("low")),
      "deepseek-v4-pro",
    ),
    content="high",
  )
  // The rule behind both literals: whatever comes out is a level this model offers, always.
  for model in ["deepseek-v4-flash", "deepseek-v4-pro"] {
    let levels = @core.model_spec_for(model).0.thinking_levels
    for wanted in ["off", "low", "high", "max", "bogus"] {
      let got = session_level(log_of(Some(model), Some(wanted)), model)
      assert_true(
        levels.offered().contains(got),
        msg="\{model} does not offer \{got}, which is what a session recording \{wanted} would run at",
      )
    }
  }
}

///|
/// Switching a session's model re-settles its level, and that is the whole reason it is a function.
///
/// The named mistake is the easy one to write: keep the level, and send `reasoning_effort: low` to a
/// model that has no `low`. Nothing writes to the log here — the driver records both at the top of
/// the next turn — so a reader who changes their mind twice leaves no trace of either decision.
test "retargeting a session clamps its level to the new model" {
  let open = Open::new(
    "/tmp/s.jsonl",
    "/tmp",
    "deepseek-v4-flash",
    "low",
    log_of(None, None),
  )
  retarget(open, "deepseek-v4-pro")
  inspect(open.model_id, content="deepseek-v4-pro")
  // Flash's `low` is not pro's, so it becomes pro's default rather than being carried over.
  inspect(open.think_level, content="high")
  // And a level the new model does have survives the move.
  retarget(open, "deepseek-v4-flash")
  inspect(open.think_level, content="high")
}

///|
/// "The reader may choose" is two facts, and the second one is the one that is easy to miss.
///
/// `turn_in_flight` alone is true for the whole time a turn *runs* — the opening entry is written
/// before any of the work happens — so a log-only answer describes a healthy turn as an interrupted
/// one, and offers to continue a conversation that is being continued, with two buttons that cannot
/// be pressed while it runs. It was found by switching away and coming back to watch the turn that
/// was left behind.
test "a turn that is running is not a turn that was interrupted" {
  inspect(interrupted_turn(open_with_turn(false)), content="true")
  inspect(interrupted_turn(open_with_turn(true)), content="false")
  // No turn open at all: nothing to offer.
  let plain = Open::new("/tmp/s.jsonl", "/tmp", "m", "high", log_of(None, None))
  inspect(interrupted_turn(plain), content="false")
}

///|
/// One open session with a turn that was started and never ended, busy or not.
fn open_with_turn(busy : Bool) -> Open {
  let session = log_of(None, None)
  let started = @core.turn_start_entry("build the thing", None, 0L)
  let open = Open::new(
    "/tmp/s.jsonl",
    "/tmp",
    "deepseek-v4-flash",
    "high",
    @core.Session::new(session.header, [started]),
  )
  open.busy = busy
  open
}

///|
/// A turn that ended in a conversation nobody is looking at is its own event.
///
/// Its own kind rather than a flag on `session`, **so that the window cannot follow it**: a turn
/// ending elsewhere used to arrive as a switch, and the window moved away from what the reader was
/// reading. The path is in the payload as well as in the routing because the host's "show me that
/// one" click hands the payload to `/open` — one is the envelope, the other is a command argument.
test "an elsewhere turn carries its path twice, on purpose" {
  inspect(
    elsewhere_event("/store/other.jsonl", "finished").stringify(),
    content="{\"kind\":\"elsewhere\",\"session\":\"/store/other.jsonl\",\"path\":\"/store/other.jsonl\",\"outcome\":\"finished\"}",
  )
}
