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
  assert_true(is_known_model("deepseek-v4-flash"))
  assert_true(is_known_model("deepseek-flash"))
  assert_true(is_known_model("deepseek-v4-pro"))
  // Case and whitespace are not normalized: an id is an identifier, and guessing at near-misses
  // would turn a typo into a call to the wrong model.
  assert_false(is_known_model("DeepSeek-V4-Pro"))
  assert_false(is_known_model(" deepseek-v4-pro"))
  assert_false(is_known_model(""))
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
  // `low` is not one of its levels. Present-and-null rather than absent, so the request builder's
  // fallback for an unavailable level applies instead of the level being sent as-is.
  assert_eq(pro.thinking_levels.map.get("low"), Some(None))
  assert_eq(pro.thinking_levels.map.get("high"), Some(Some("high")))
  assert_eq(flash.thinking_levels.map.get("low"), Some(Some("low")))
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
test "a model's label shows the id when the name is not the id" {
  assert_eq(default_model().label(), "DeepSeek V4 Flash (deepseek-v4-flash)")
  // A hypothetical model whose name is its id does not repeat itself.
  let same : ModelSpec = {
    ..default_model(),
    name: "same-as-id",
    id: "same-as-id",
  }
  assert_eq(same.label(), "same-as-id")
}
