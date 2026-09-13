///|
/// The settings model and its file format.
///
/// Pure, so these run without a filesystem: the questions worth pinning are which key wins,
/// whether disabling a name silences every skill of that name, and what a corrupt file means.
/// The file itself is written by `platform/settings.mbt`, which the panel test covers end to end.

///|
fn skill(name : String, path : String) -> Skill {
  { name, description: "does \{name}", path, }
}

///|
test "a round trip preserves the key, the names and the limits" {
  let settings : AppSettings = {
    saved_api_key: "sk-from-the-panel",
    disabled_skills: ["alpha", "beta"],
    agents_md: "Prefer small diffs.",
    max_rounds: Some(40),
    max_cost: Some(0.25),
  }
  let decoded = decode_app_settings(encode_app_settings(settings))
  assert_eq(decoded, settings)
  // The three states of a limit survive as three states: a number, explicitly off, and never set.
  let off = decode_app_settings(
    encode_app_settings({
      ..settings,
      max_rounds: Some(0),
      max_cost: Some(0.0),
    }),
  )
  assert_eq(off.max_rounds, Some(0))
  assert_eq(off.max_cost, Some(0.0))
  let unset = decode_app_settings(
    encode_app_settings({ ..settings, max_rounds: None, max_cost: None, }),
  )
  assert_true(unset.max_rounds is None)
  assert_true(unset.max_cost is None)
}

///|
/// An empty settings file is written as an object, not as nothing, so decoding it back is the
/// empty settings rather than a special case.
test "the empty settings survive a round trip" {
  let decoded = decode_app_settings(encode_app_settings(AppSettings::new()))
  assert_eq(decoded.saved_api_key, "")
  assert_eq(decoded.disabled_skills.length(), 0)
  assert_true(decoded.max_rounds is None)
  assert_true(decoded.max_cost is None)
}

///|
test "anything unreadable is the empty settings, not a failure" {
  assert_eq(decode_app_settings("").saved_api_key, "")
  assert_eq(decode_app_settings("not json at all").disabled_skills.length(), 0)
  assert_eq(decode_app_settings("[1, 2, 3]").saved_api_key, "")
  // A field of the wrong type is dropped rather than allowed to poison the rest.
  let mixed = decode_app_settings(
    "{\"saved_api_key\": 42, \"disabled_skills\": \"alpha\"}",
  )
  assert_eq(mixed.saved_api_key, "")
  assert_eq(mixed.disabled_skills.length(), 0)
  // A missing field is a default, which is what lets a hand-written file hold only a key.
  let partial = decode_app_settings("{\"saved_api_key\": \"sk\"}")
  assert_eq(partial.saved_api_key, "sk")
  assert_eq(partial.disabled_skills.length(), 0)
}

///|
test "disabled names are deduplicated and sorted" {
  let decoded = decode_app_settings(
    "{\"saved_api_key\": \"\", \"disabled_skills\": [\"b\", \"a\", \"b\", 7]}",
  )
  assert_eq(decoded.disabled_skills.length(), 2)
  assert_eq(decoded.disabled_skills[0], "a")
  assert_eq(decoded.disabled_skills[1], "b")
}

///|
test "a key is stored trimmed" {
  let settings = AppSettings::new().with_saved_api_key("  sk-abc\n")
  assert_eq(settings.saved_api_key, "sk-abc")
  // Clearing it is how the panel falls back to the environment, and it stays clear.
  assert_eq(AppSettings::new().with_saved_api_key("").saved_api_key, "")
}

///|
test "toggling a skill off and on again returns to enabled" {
  let base = AppSettings::new()
  assert_true(base.skill_enabled("alpha"))
  let off = base.with_skill_enabled("alpha", false)
  assert_false(off.skill_enabled("alpha"))
  assert_true(off.skill_enabled("beta"), msg="only the named skill is affected")
  let on = off.with_skill_enabled("alpha", true)
  assert_true(on.skill_enabled("alpha"))
  assert_eq(on.disabled_skills.length(), 0)
  // Toggling twice is not two entries.
  let twice = base
    .with_skill_enabled("alpha", false)
    .with_skill_enabled("alpha", false)
  assert_eq(twice.disabled_skills.length(), 1)
}

///|
/// A disabled name silences *every* skill of that name, which is what makes a project skill
/// able to shadow a global one with a single switch.
test "the disabled names filter the catalog, one name for all paths" {
  let discovered = [
    skill("alpha", "/home/u/.pi/agent/skills/alpha/SKILL.md"),
    skill("alpha", "/work/proj/.pi/skills/alpha/SKILL.md"),
    skill("beta", "/home/u/.agents/skills/beta.md"),
  ]
  assert_eq(enabled_skills(discovered, []).length(), 2)
  let kept = enabled_skills(discovered, ["alpha"])
  assert_eq(kept.length(), 1)
  assert_eq(kept[0].name, "beta")
  // A name nobody has is harmless.
  assert_eq(enabled_skills(discovered, ["gone"]).length(), 2)
}

///|
/// The panel's list: everything discovered, in catalog order, plus the names that are switched
/// off and no longer exist anywhere.
test "the panel lists enabled and disabled skills alike" {
  let discovered = [skill("alpha", "/a/SKILL.md"), skill("beta", "/b/SKILL.md")]
  let rows = skill_entries(discovered, ["beta"])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].name, "alpha")
  assert_true(rows[0].enabled)
  assert_eq(rows[0].path, "/a/SKILL.md")
  assert_eq(rows[1].name, "beta")
  assert_false(rows[1].enabled)
  // A name with no file behind it is still listed and still off, so the switch back on exists.
  let stale = skill_entries(discovered, ["beta", "gone"])
  assert_eq(stale.length(), 3)
  assert_eq(stale[2].name, "gone")
  assert_false(stale[2].enabled)
  assert_eq(stale[2].path, "")
  // And a name that is merely unavailable, not switched off, is not invented.
  assert_eq(skill_entries(discovered, []).length(), 2)
}

///|
/// The instructions setting: a round trip keeps the prose, and the three sources are three
/// distinct answers rather than one string that happens to be empty sometimes.
test "the fallback instructions survive a round trip and lose only their margins" {
  let settings = AppSettings::new().with_agents_md(
    "\n  Always run moon test.\n",
  )
  assert_eq(settings.agents_md, "Always run moon test.")
  assert_eq(decode_app_settings(encode_app_settings(settings)), settings)
  // Newlines inside are prose, not margins, and surviving them is the whole point of storing this
  // as a string rather than as one line.
  let two_lines = AppSettings::new().with_agents_md("one\n\ntwo")
  assert_eq(
    decode_app_settings(encode_app_settings(two_lines)).agents_md,
    "one\n\ntwo",
  )
  // The empty settings, and a setting emptied by the reader, are the same state.
  assert_eq(AppSettings::new().agents_md, "")
  assert_eq(
    AppSettings::new().with_agents_md("x").with_agents_md("").agents_md,
    "",
  )
}

///|
test "a hand-written file without the instructions field still decodes" {
  let partial = decode_app_settings("{\"saved_api_key\": \"sk\"}")
  assert_eq(partial.agents_md, "")
  // And a field of the wrong type is dropped rather than poisoning the rest.
  assert_eq(decode_app_settings("{\"agents_md\": 42}").agents_md, "")
}

///|
/// Which of the two instruction sources wins, and that "neither" is not spelled as an empty file.
test "a workspace file beats the saved instructions, and the saved ones fill in elsewhere" {
  let saved = AppSettings::new().with_agents_md("from the panel")
  let file = choose_instructions(saved, "# From the repository\n")
  assert_eq(file.text, "# From the repository\n")
  assert_true(file.source is File)
  // A workspace with no file of its own gets the saved text, which is the whole reason the
  // fallback exists.
  let fallback = choose_instructions(saved, "")
  assert_eq(fallback.text, "from the panel")
  assert_true(fallback.source is Saved)
  // Whitespace is not instructions: a file of blank lines is a workspace that has none.
  let blank = choose_instructions(saved, "   \n\t\n")
  assert_true(blank.source is Saved)
}

///|
/// Nothing anywhere is its own state, so the panel can say "none" rather than showing an empty
/// box and letting the reader guess whether that means empty or broken.
test "no file and no saved text is neither source" {
  let nothing = choose_instructions(AppSettings::new(), "")
  assert_eq(nothing.text, "")
  assert_true(nothing.source is Absent)
  // And it is not the same answer as a saved setting that was cleared, in the only sense that
  // matters: both send nothing, and the panel distinguishes them by what was in the box.
  let cleared = choose_instructions(
    AppSettings::new().with_agents_md("  "),
    "  ",
  )
  assert_eq(cleared.text, "")
  assert_true(cleared.source is Absent)
}

///|
test "the instructions form decodes to the whole text, including an emptied one" {
  match parse_settings_post("agents=1&agents_md=Prefer+small+diffs.%0A") {
    Some(ApplyAgentsMd(text~)) =>
      // Percent-decoded like every other field, and the newline is part of what was typed.
      assert_eq(text, "Prefer small diffs.\n")
    _ => fail("an agents field is an apply")
  }
  // The case the marker exists for: an empty textarea posts nothing but the marker, and that has
  // to mean "no fallback" rather than "not a settings form".
  match parse_settings_post("agents=1") {
    Some(ApplyAgentsMd(text~)) => assert_eq(text, "")
    _ => fail("the marker alone is an empty text")
  }
  match parse_settings_post("agents=1&agents_md=") {
    Some(ApplyAgentsMd(text~)) => assert_eq(text, "")
    _ => fail("an empty field is an empty text")
  }
  // A body with no marker is still not a settings post, marker or no marker.
  assert_true(parse_settings_post("agents_md=hello") is None)
}

///|
test "a form body decodes to the save, clear or apply it names" {
  match parse_settings_post("key=sk-a%2Bb%2Fc") {
    Some(SaveKey(key~, clear~)) => {
      // `%2B` is a plus, and it is not turned into a space — which is the one thing a form
      // decoder has to get right that a URI decoder would get wrong.
      assert_eq(key, "sk-a+b/c")
      assert_false(clear)
    }
    _ => fail("a key field is a save")
  }
  // The clearing form carries an empty key field, and clear wins over it.
  match parse_settings_post("key=&clear=1") {
    Some(SaveKey(key~, clear~)) => {
      assert_eq(key, "")
      assert_true(clear)
    }
    _ => fail("a clear field is a clear")
  }
  match parse_settings_post("skills=1&skill=alpha&skill=beta&skill=alpha") {
    Some(ApplySkills(enabled~)) => {
      // The set, exactly as posted: duplicates collapsed, order kept.
      assert_eq(enabled.length(), 2)
      assert_eq(enabled[0], "alpha")
      assert_eq(enabled[1], "beta")
    }
    _ => fail("skill fields are an apply")
  }
  // Every box unchecked posts nothing but the marker, and that is an empty set rather than a form
  // the panel did not write — switching off the last skill is the case this protects.
  match parse_settings_post("skills=1") {
    Some(ApplySkills(enabled~)) => assert_eq(enabled.length(), 0)
    _ => fail("the marker alone is an empty set")
  }
  // A form with nothing in it, or one this panel did not write, is not a settings post.
  assert_true(parse_settings_post("") is None)
  assert_true(parse_settings_post("prompt=hello") is None)
  assert_true(parse_settings_post("skill=") is None)
  assert_true(parse_settings_post("skill=alpha") is None)
}

///|
test "a form field is percent-decoded, including names that are not ascii" {
  // Every catalog form carries the marker, so the fixture does too.
  match parse_settings_post("skills=1&skill=%E4%B8%AD%E6%96%87") {
    Some(ApplySkills(enabled~)) => assert_eq(enabled[0], "中文")
    _ => fail("a percent-encoded name is still a name")
  }
  // A space is what a form says a plus is, and a literal name keeps it.
  match parse_settings_post("skills=1&skill=name+with+spaces") {
    Some(ApplySkills(enabled~)) => assert_eq(enabled[0], "name with spaces")
    _ => fail("a plus is a space in a form body")
  }
  // A stray percent is left as itself rather than eating the characters after it.
  match parse_settings_post("skills=1&skill=100%25") {
    Some(ApplySkills(enabled~)) => assert_eq(enabled[0], "100%")
    _ => fail("an escape is decoded")
  }
  match parse_settings_post("skills=1&skill=50%zz") {
    Some(ApplySkills(enabled~)) => assert_eq(enabled[0], "50%zz")
    _ => fail("a percent that starts no escape stays put")
  }
}

///|
/// The flag wins over the saved setting, which wins over the default — the opposite order from the
/// key's, because a flag here is a hard cap someone typed for this run and a saved value must not
/// be able to turn it into a suggestion.
test "a limit comes from the flag, then the setting, then the default" {
  let unset = AppSettings::new()
  let from_default = choose_limits(None, None, unset)
  assert_eq(from_default.max_rounds.value, default_max_rounds().to_double())
  assert_eq(from_default.max_rounds.source, Default)
  assert_eq(from_default.max_cost.value, default_max_cost())
  assert_eq(from_default.max_cost.source, Default)
  let saved = unset.with_limits(Some(5), Some(0.02))
  let from_saved = choose_limits(None, None, saved)
  assert_eq(from_saved.max_rounds.value, 5.0)
  assert_eq(from_saved.max_rounds.source, Saved)
  assert_eq(from_saved.max_cost.value, 0.02)
  assert_eq(from_saved.max_cost.source, Saved)
  // A flag wins for its own limit and leaves the other one where it was: setting a cost cap on the
  // command line should not also throw away a saved call limit.
  let mixed = choose_limits(Some(9), None, saved)
  assert_eq(mixed.max_rounds.value, 9.0)
  assert_eq(mixed.max_rounds.source, Flag)
  assert_eq(mixed.max_cost.source, Saved)
  // Zero is a value, not an absence: it disables the bound rather than falling back.
  let off = choose_limits(Some(0), Some(0.0), saved)
  assert_eq(off.max_rounds.value, 0.0)
  assert_eq(off.max_rounds.source, Flag)
  assert_eq(off.max_cost.source, Flag)
}

///|
/// The limits form is told apart by its own marker, and each field reads the way a reader would
/// expect: empty means no opinion, `0` means no bound, and something that is not a number means no
/// opinion rather than a bound of zero.
test "the limits form decodes to the two values or to none" {
  match parse_settings_post("limits=1&max_rounds=40&max_cost=0.25") {
    Some(ApplyLimits(max_rounds~, max_cost~)) => {
      assert_eq(max_rounds, Some(40))
      assert_eq(max_cost, Some(0.25))
    }
    _ => fail("a limits form is a limits post")
  }
  // Both boxes cleared posts only the marker, and that is "clear both" rather than "nothing to
  // do" — which is what a reader does after raising them once.
  match parse_settings_post("limits=1") {
    Some(ApplyLimits(max_rounds~, max_cost~)) => {
      assert_true(max_rounds is None)
      assert_true(max_cost is None)
    }
    _ => fail("the marker alone clears both")
  }
  // One of the two left as it is never happens through the form — it submits both — but a hand-typed
  // body can, and the missing field is "no opinion" rather than a bound of zero.
  match parse_settings_post("limits=1&max_cost=2") {
    Some(ApplyLimits(max_rounds~, max_cost~)) => {
      assert_true(max_rounds is None)
      assert_eq(max_cost, Some(2.0))
    }
    _ => fail("half a form is still a limits post")
  }
  // No marker at all, but a limit field: still a limits post, because that is what someone typing
  // at `curl` means by it.
  match parse_settings_post("max_cost=0.5") {
    Some(ApplyLimits(max_rounds~, max_cost~)) => {
      assert_true(max_rounds is None)
      assert_eq(max_cost, Some(0.5))
    }
    _ => fail("a bare limit field is a limits post")
  }
  assert_true(parse_settings_post("prompt=hello") is None)
  // The marker with an empty value is still the marker — an unchecked box would have been dropped
  // by `FormData`, but this field is hidden and always sent, so `limits=` can only mean the form.
  match parse_settings_post("limits=") {
    Some(ApplyLimits(max_rounds~, max_cost~)) => {
      assert_true(max_rounds is None)
      assert_true(max_cost is None)
    }
    _ => fail("the bare marker is still a limits post")
  }
}

///|
test "a limit field reads empty, zero and nonsense distinctly" {
  assert_true(parse_limit_int("") is None)
  assert_true(parse_limit_int("  ") is None)
  assert_eq(parse_limit_int("0"), Some(0))
  assert_eq(parse_limit_int("40"), Some(40))
  assert_eq(parse_limit_int(" 40 "), Some(40))
  // Not a number, and negative, are both "no opinion": the guard treats `> 0` as on, so a negative
  // value passed through would silently disable the bound the reader thought they were setting.
  assert_true(parse_limit_int("forty") is None)
  assert_true(parse_limit_int("-1") is None)
  assert_true(parse_limit_cost("") is None)
  assert_eq(parse_limit_cost("0"), Some(0.0))
  assert_eq(parse_limit_cost("0.25"), Some(0.25))
  // A `$` is what the status line writes, so a value copied from it pastes clean.
  assert_eq(parse_limit_cost("$0.25"), Some(0.25))
  assert_eq(parse_limit_cost(" $1.50 "), Some(1.5))
  assert_true(parse_limit_cost("cheap") is None)
  assert_true(parse_limit_cost("-0.5") is None)
  // The forms the parser refuses to turn into a bound rather than into infinity.
  assert_true(parse_limit_cost("nan") is None)
  assert_true(parse_limit_cost("inf") is None)
}

///|
/// A hand-edited file is not allowed to smuggle in a bound the guard would ignore.
test "a nonsense limit in the file is no opinion, not a disabled bound" {
  let negative = decode_app_settings("{\"max_rounds\": -5, \"max_cost\": -1}")
  assert_true(negative.max_rounds is None)
  assert_true(negative.max_cost is None)
  let wrong_type = decode_app_settings(
    "{\"max_rounds\": \"40\", \"max_cost\": \"0.5\"}",
  )
  assert_true(wrong_type.max_rounds is None)
  assert_true(wrong_type.max_cost is None)
  // Zero is a legitimate value from a hand-edited file too: it is how a reader who knows what they
  // are doing turns the bound off for good.
  let off = decode_app_settings("{\"max_rounds\": 0, \"max_cost\": 0}")
  assert_eq(off.max_rounds, Some(0))
  assert_eq(off.max_cost, Some(0.0))
}

///|
test "the environment key wins over everything" {
  let choice = choose_api_key("sk-env", "sk-saved", Some("sk-pi"))
  match choice {
    Some(chosen) => {
      assert_eq(chosen.key, "sk-env")
      assert_eq(chosen.source, Environment)
    }
    None => fail("an environment key is a choice")
  }
}

///|
test "a saved key is used when the environment has none" {
  match choose_api_key("", "sk-saved", Some("sk-pi")) {
    Some(chosen) => {
      assert_eq(chosen.key, "sk-saved")
      assert_eq(chosen.source, Saved)
    }
    None => fail("a saved key is a choice")
  }
}

///|
test "pi's store is the last resort, and nothing set is not a choice" {
  match choose_api_key("", "", Some("sk-pi")) {
    Some(chosen) => {
      assert_eq(chosen.key, "sk-pi")
      assert_eq(chosen.source, Pi)
    }
    None => fail("a stored key is a choice")
  }
  // An empty string is absence, not a key: all three providers can hand one over when they
  // have nothing, and treating it as a value would send `Bearer ` to the model.
  assert_true(choose_api_key("", "", None) is None)
  assert_true(choose_api_key("", "", Some("")) is None)
}
