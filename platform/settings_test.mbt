///|
/// The settings file against a real filesystem.
///
/// What is worth checking here is exactly what the pure tests cannot: that a save is readable by
/// the next load, that the temporary file does not survive, and that a corrupt file degrades to
/// the empty settings instead of taking the process down. Scratch directories live under
/// `_build`, which the repository already ignores.

///|
async fn settings_scratch() -> String {
  let home = "_build/settings_test/\{@core.new_entry_id()}"
  make_dirs(home)
  home
}

///|
async test "settings round trip through a file" {
  let home = settings_scratch()
  // Nothing has been saved: a machine that never opened the panel reads as empty, not as an
  // error about a missing file.
  assert_eq(load_settings(home).saved_api_key, "")
  let settings = @core.AppSettings::new()
    .with_saved_api_key("sk-abc")
    .with_skill_enabled("alpha", false)
    .with_skill_enabled("beta", false)
    .with_limits(Some(40), Some(0.25), Some(1800))
  save_settings(home, settings)
  let loaded = load_settings(home)
  assert_eq(loaded, settings)
  // The limits survive the file as their three states, seconds included: this is the read a restart
  // does before the panel can show anything.
  assert_eq(loaded.max_rounds, Some(40))
  assert_eq(loaded.max_cost, Some(0.25))
  assert_eq(loaded.max_seconds, Some(1800))
  // The write goes through a temporary file, and it is the rename that publishes it.
  assert_true(path_exists(settings_path(home)))
  assert_false(path_exists("\{settings_path(home)}.tmp"))
  // A second save replaces the first rather than merging with it.
  save_settings(home, @core.AppSettings::new())
  let cleared = load_settings(home)
  assert_eq(cleared.saved_api_key, "")
  assert_eq(cleared.disabled_skills.length(), 0)
  assert_true(cleared.max_seconds is None)
}

///|
async test "a corrupt settings file decodes to the empty settings" {
  let home = settings_scratch()
  make_dirs("\{home}/.pi-mb")
  write_text(settings_path(home), "this is not json\n")
  let loaded = load_settings(home)
  assert_eq(loaded.saved_api_key, "")
  assert_eq(loaded.disabled_skills.length(), 0)
  // And the panel can still save over it, which is the way out for a reader who broke it by
  // hand.
  save_settings(home, @core.AppSettings::new().with_saved_api_key("sk-fresh"))
  assert_eq(load_settings(home).saved_api_key, "sk-fresh")
}

///|
test "the settings file sits beside the session store" {
  assert_eq(settings_path("/home/u"), "/home/u/.pi-mb/settings.json")
}
