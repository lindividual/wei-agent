///|
/// The model catalog.
///
/// A catalog is only worth having if nothing can quietly disagree with it, so the first test below
/// is the important one: the flash entry delegates to the accessors the request builder and the
/// recorded fixtures already use, and this pins the two together. The rest are about the two
/// questions a picker and a resumed session ask — may I switch to this, and what do I show for a
/// model I do not know.

///|
/// The default is in the catalog, and its entry is the one the rest of the code already prices by.
///
/// Without this, `default_model()`'s fallback would be reachable and silent, and a reader's cost
/// figures would be computed from one set of numbers while the fixture says another.
test "the default model's entry agrees with the accessors it delegates to" {
  let spec = default_model()
  assert_eq(spec.id, default_model_id())
  assert_eq(spec.pricing, deepseek_v4_flash_pricing())
  assert_eq(spec.context_window, deepseek_v4_flash_context_window())
  assert_eq(spec.max_tokens, deepseek_v4_flash_max_tokens())
  assert_eq(spec.thinking_levels, deepseek_v4_thinking_levels())
  // And a resume of an old session finds it by the id its log recorded.
  assert_eq(
    find_model("deepseek-v4-flash").unwrap().pricing,
    deepseek_v4_flash_pricing(),
  )
}

///|
test "the catalog is searchable by the id a log records" {
  assert_true(model_spec_for("deepseek-v4-flash").1)
  assert_true(model_spec_for("deepseek-flash").1)
  assert_true(model_spec_for("deepseek-v4-pro").1)
  // Case and whitespace are not normalized: an id is an identifier, and guessing at near-misses
  // would turn a typo into a call to the wrong model.
  assert_false(model_spec_for("DeepSeek-V4-Pro").1)
  assert_false(model_spec_for(" deepseek-v4-pro").1)
  assert_false(model_spec_for("").1)
  assert_true(find_model("nope") is None)
}

///|
/// Every entry is complete enough to switch a session to it: a model with no pricing would bill
/// every turn at zero, and one with no window would make the context chip a division by zero.
test "every model in the catalog is complete" {
  let catalog = model_catalog()
  assert_true(catalog.length() >= 3, msg="\{catalog.length()} models")
  let ids : Array[String] = []
  for spec in catalog {
    assert_true(spec.id != "", msg=spec.id)
    assert_true(spec.provider != "", msg=spec.id)
    assert_true(spec.context_window > 0, msg=spec.id)
    assert_true(spec.pricing.input > 0.0, msg=spec.id)
    assert_true(spec.pricing.output > 0.0, msg=spec.id)
    // A cache read costs less than fresh input, in every model's table. A ratio the wrong way
    // round would make caching look like a loss.
    assert_true(spec.pricing.cache_read < spec.pricing.input, msg=spec.id)
    // No duplicate ids, or `find_model` would be order-dependent.
    assert_false(ids.contains(spec.id), msg="duplicate id \{spec.id}")
    ids.push(spec.id)
  }
}

///|
/// The pro model is dearer than the default, which is the whole reason a reader would switch to it
/// deliberately — and a table where that was not true would be a typo nobody noticed.
test "the pro model costs more than the default and has fewer thinking levels" {
  let pro = find_model("deepseek-v4-pro").unwrap()
  let flash = default_model()
  assert_true(
    pro.pricing.input > flash.pricing.input,
    msg="\{pro.pricing.input} vs \{flash.pricing.input}",
  )
  assert_true(pro.pricing.cache_read > flash.pricing.cache_read)
  // `low` is not one of its levels. Present-and-null rather than absent, so that `offered` has one
  // thing to read: a name the map does not know and a name it holds as null are the same answer to
  // "may this model run at that level" (no), and the second is also a record that the level was
  // considered rather than forgotten.
  assert_eq(pro.thinking_levels.map.get("low"), Some(None))
  assert_eq(pro.thinking_levels.map.get("high"), Some(Some("high")))
  assert_eq(flash.thinking_levels.map.get("low"), Some(Some("low")))
}

///|
/// What a picker may offer, per model, and in the order it should draw them.
///
/// The two lists differ, and that is the point: `low` and `medium` are flash's, `low` is not pro's,
/// and every model has `off` because "do not think" is not an effort the provider has to support.
/// A single shared list would put a level on screen that the API rejects.
test "each model offers only the levels it has, off first" {
  let flash = default_model()
  assert_eq(flash.thinking_levels.offered(), ["off", "low", "high", "max"])
  assert_eq(find_model("deepseek-v4-pro").unwrap().thinking_levels.offered(), [
    "off", "high", "max",
  ])
  // The three ids that name flash share its list, because they share its table.
  assert_eq(
    find_model("deepseek-flash").unwrap().thinking_levels.offered(),
    flash.thinking_levels.offered(),
  )
}

///|
/// The default is what every front end in this repository already asked for, so adding a choice does
/// not change what happens when nobody makes one.
test "a model's default level is high" {
  for spec in model_catalog() {
    assert_eq(spec.thinking_levels.default_level(), "high", msg=spec.id)
  }
}

///|
/// What will actually be sent, given what was asked for and the model that will run it.
///
/// The case worth pinning is the third one: a session carries its level in its log, and the levels
/// are per model, so switching from flash to pro leaves a session asking for a level pro does not
/// have. The answer is the level that will really be used — not the request, and not a refusal.
test "a level this model does not have falls back to its default" {
  let flash = default_model().thinking_levels
  let pro = find_model("deepseek-v4-pro").unwrap().thinking_levels
  assert_eq(flash.in_force(Some("low")), "low")
  assert_eq(flash.in_force(Some("off")), "off")
  assert_eq(pro.in_force(Some("low")), "high")
  assert_eq(pro.in_force(Some("high")), "high")
  // Nobody has said, and a name nobody recognises, are answered the same way: neither is a level
  // this model can run at.
  assert_eq(pro.in_force(None), "high")
  assert_eq(pro.in_force(Some("paranoid")), "high")
}

///|
/// The fallbacks themselves, on tables no model in the catalog has yet.
///
/// Written as real answers rather than as a panic, so they are worth a test: a model with no `high`
/// gets the most thinking it has, and a model with no levels at all gets `off` rather than the name
/// of a level it cannot run at.
test "a table without high falls back to the most it has" {
  let legacy : ThinkingLevels = {
    map: Map([("off", None), ("low", Some("low")), ("medium", Some("medium"))]),
  }
  assert_eq(legacy.offered(), ["off", "low", "medium"])
  assert_eq(legacy.default_level(), "medium")
  assert_eq(legacy.in_force(Some("high")), "medium")
  // A model with nothing but an off switch is one that does not think, and saying so is the honest
  // answer: the alternative is an effort string no provider accepts.
  let silent : ThinkingLevels = { map: Map([("off", None)]), }
  assert_eq(silent.offered(), ["off"])
  assert_eq(silent.default_level(), "off")
  assert_eq(silent.in_force(Some("max")), "off")
}

///|
/// A resumed session naming a model this build does not have stays openable, and the fallback is
/// reported rather than hidden — the flag is what the model chip uses to say so.
test "an unknown model falls back to the default and says that it did" {
  let (known_spec, known) = model_spec_for("deepseek-v4-pro")
  assert_eq(known_spec.id, "deepseek-v4-pro")
  assert_true(known)
  let (fallback, was_known) = model_spec_for("deepseek-v9-someday")
  assert_false(was_known)
  assert_eq(fallback.id, default_model_id())
  // It still prices and measures, because the alternative is a session that cannot be opened.
  assert_true(fallback.context_window > 0)
  assert_true(fallback.pricing.input > 0.0)
}

///|
/// A model's label is its name, and the id is a separate answer for a separate question.
///
/// **This is a reversal, and the reason is measured.** The label used to be `Name (id)`, and the id
/// came along to help the reader who later has to type it — in a `curl`, in a log. In the composer's
/// menu, that reader is not present: measured on this build's own menu (`docs/macos-pitfalls.md` §六),
/// the id made every row ~110 points wider while adding nothing a reader of *that* menu acts on, and
/// the menu's width is its longest row. Two questions, two answers: the picker draws `label`, and the
/// one place a reader is told what to type (`model_report`) draws `label_with_id`.
test "a label is the name, and the id is asked for separately" {
  assert_eq(default_model().label(), "DeepSeek V4 Flash")
  assert_eq(
    default_model().label_with_id(),
    "DeepSeek V4 Flash (deepseek-v4-flash)",
  )
  // A hypothetical model whose name is its id does not repeat itself.
  let same : ModelSpec = {
    ..default_model(),
    name: "same-as-id",
    id: "same-as-id",
  }
  assert_eq(same.label(), "same-as-id")
  assert_eq(same.label_with_id(), "same-as-id")
}

///|
/// **The invariant the price columns exist for: every row's column is the same width.**
///
/// A menu of three prices is read *down* the list — is this one dearer than that one — and a column
/// that moves cannot be read that way. The widths come from the whole catalog rather than from each
/// model, so this is true for any pair of rows, and it is asserted that way rather than by pinning a
/// width: a fourth model with a longer name or a different rate must not be able to break the column
/// without failing a test.
test "price columns are the same width on every row" {
  let rows = model_catalog().map(spec => spec.pricing.columns())
  let first = rows[0]
  for row in rows {
    assert_eq(row.0.length(), first.0.length(), msg="input column")
    assert_eq(row.1.length(), first.1.length(), msg="output column")
    assert_eq(row.2.length(), first.2.length(), msg="cached column")
  }
  // Two decimals as the floor, because these are dollars and a cent is the smallest unit a reader
  // thinks in; the cache column needs four, because a fiftieth of a cent is not zero.
  assert_eq(first.0.length(), 4, msg="0.14")
  assert_eq(first.2.length(), 6, msg="0.0028")
}

///|
/// The exact three columns a picker draws, which is the shape the host's menu rows are cut from.
///
/// Pinned rather than described, because the alignment is a fact about *characters* and this is where
/// the character counts are decided. The same three rows were measured in the running app's menu
/// (`docs/macos-pitfalls.md` §六): `0.14  0.28  0.0028   DeepSeek V4 Flash` at 335 points wide.
test "prices are formatted to the width their column needs" {
  assert_eq(default_model().pricing.columns(), ("0.14", "0.28", "0.0028"))
  assert_eq(
    find_model("deepseek-flash").unwrap().pricing.columns(),
    ("0.30", "1.20", "0.0060"),
  )
  assert_eq(
    find_model("deepseek-v4-pro").unwrap().pricing.columns(),
    ("1.32", "3.96", "0.0440"),
  )
}

///|
/// A price wider than its column is printed in full rather than cut, and one narrower is rounded.
///
/// Two edges of the same function, and both matter for what they refuse to do. Cutting a number to fit
/// a column would print a price the model does not have — a wrong number is worse than a row that is
/// one character wider — and rounding is what a price finer than the column gets, which in practice is
/// only reachable for a model this build does not have in its catalog (the widths are derived from it,
/// so a catalog with such a price would have widened the column instead).
test "a price outside its column is not silently changed" {
  let dear : Pricing = {
    input: 20.0,
    output: 30.0,
    cache_read: 0.5,
    cache_write: 0.0,
  }
  // Wider than the four-character column, and printed whole: `20.00`, not `0.00` or `2.00`.
  assert_eq(dear.columns(), ("20.00", "30.00", "0.5000"))
  let tiny : Pricing = {
    input: 0.004,
    output: 0.0,
    cache_read: 0.0,
    cache_write: 0.0,
  }
  // `0.00` at this width, and it is the *column* that is wrong rather than the number: what this pins
  // is that the formatter rounds rather than truncates (truncation would print the same here, which is
  // why the value is chosen just under a cent rather than just over one).
  assert_eq(tiny.columns().0, "0.00")
  let halfway : Pricing = {
    input: 0.005,
    output: 0.0,
    cache_read: 0.0,
    cache_write: 0.0,
  }
  assert_eq(halfway.columns().0, "0.01", msg="rounds, not truncates")
}
