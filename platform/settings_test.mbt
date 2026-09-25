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
  // The write goes through a temporary file, and it is the rename that publishes it — so what is worth
  // asserting is that *nothing temporary is left behind*, not that one particular name is gone: the temp
  // name carries four random bytes (`temp_beside`), so a test that looked for `settings.json.tmp` would
  // pass whether the rename happened or not.
  assert_true(path_exists(settings_path(home)))
  assert_eq(
    list_entries(home).filter(name => name.has_suffix(".tmp")).length(),
    0,
    msg="a temp file survived the save: \{list_entries(home).join(", ")}",
  )
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
  make_dirs("\{home}/.wei")
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
  assert_eq(settings_path("/home/u"), "/home/u/.wei/settings.json")
}

///|
/// The key a front end actually sends, read the way the front ends read it.
///
/// The precedence itself is `@core.choose_api_key`'s and is tested there; what this adds is the
/// wiring — that the two sources are read from the places they are really kept, and that an empty
/// variable is not a key. Two front ends used to hold a copy of this, so it is worth a test that
/// pins the one copy down.
async test "the key to send is the environment's, else the saved one" {
  let home = settings_scratch()
  @env.unset_env_var("DEEPSEEK_API_KEY")
  // No variable and nothing saved: there is no key, and that is not the empty string.
  assert_eq(api_key(home), None)

  save_settings(home, @core.AppSettings::new().with_saved_api_key("sk-saved"))
  assert_eq(api_key(home), Some("sk-saved"))

  // The variable wins over the file, and it says so by value rather than by source: the source is
  // what `@core.choose_api_key` reports to the panel.
  @env.set_env_var("DEEPSEEK_API_KEY", "sk-env")
  assert_eq(api_key(home), Some("sk-env"))

  // Set to nothing is not set: an exported-but-empty variable is a machine that meant to have no
  // key, and falling back to the file is what makes the panel's own key usable.
  @env.set_env_var("DEEPSEEK_API_KEY", "")
  assert_eq(api_key(home), Some("sk-saved"))
  @env.unset_env_var("DEEPSEEK_API_KEY")
}
