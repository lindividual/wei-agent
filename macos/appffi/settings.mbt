///|
/// What a reader can change from the native settings panel: the API key, and which tools a turn
/// gets.
///
/// The same question the web panel asks decides what is here — **can a running process honour it?**
/// The store, the endpoint and the session are decided at launch, so a control for them would be
/// lying about what it can do; they are shown as facts instead, or not at all. A key and a tool mode
/// are read at the top of every turn (`Shell::api_key`, `Shell::run_turn`), so saving either one
/// means the next turn uses it rather than the next process.
///
/// Deliberately not the whole of `AppSettings`: skills, the fallback instructions and the turn
/// limits are all in the file and all changeable from the web UI, and each needs its own control to
/// be worth a place here. The panel grows one honest control at a time.

///|
/// What this process calls each place a key can come from.
///
/// The same four words the web panel uses, because they name the same fact; a third vocabulary for
/// "where is the key coming from" would be a third thing to keep in step.
fn key_source_name(choice : @core.KeyChoice?) -> String {
  match choice {
    Some(chosen) =>
      match chosen.source {
        @core.Environment => "environment"
        @core.Saved => "saved"
        @core.Pi => "pi"
      }
    None => "none"
  }
}

///|
/// `DEEPSEEK_API_KEY` as this process sees it, or the empty string.
///
/// One reader, because two things compare it: `resolve_key` decides against it, and the settings
/// event reports whether it is set. Two reads would be two answers the day one of them changes.
///
/// A GUI app launched from Finder does not inherit a login shell's environment, so on the machine
/// this app is *installed* on this is empty and the saved key is the one that matters — which is the
/// whole reason the panel exists.
fn env_key() -> String {
  match @env.get_env_var("DEEPSEEK_API_KEY") {
    Some(value) => value
    None => ""
  }
}

///|
/// The settings as they stand, for the panel to draw.
///
/// The key itself never crosses: the panel is told where the key in use comes from and whether one
/// has been saved, which is everything it needs to say what the next turn will do. Sending the value
/// would put a secret in a place that only ever draws it dimmed — and the host has no use for it.
fn Shell::say_settings(self : Shell) -> Unit {
  emit(
    event("settings", [
      ("key", Json::string(key_source_name(resolve_key(self.settings)))),
      // Both flags, because with both set the panel has something to explain: a key the reader
      // saved is being overruled by the environment, and "I saved it and it still uses the old one"
      // reads as a bug otherwise.
      ("env", Json::boolean(env_key() != "")),
      ("saved", Json::boolean(self.settings.saved_api_key != "")),
      ("mode", Json::string(self.settings.tool_mode.to_string())),
      // Shown so that a reader who would rather edit the file knows which one to edit — the honest
      // fallback for everything the panel does not offer yet.
      ("path", Json::string(@platform.settings_path(self.home))),
    ]),
  )
}

///|
/// Save a key, and let it take effect on the next turn.
///
/// Written before it is adopted: a key held in memory and not on disk would be a setting that
/// disappears when the window closes, which is the one thing a saved key is for. The same order the
/// web panel uses.
///
/// An empty value clears the saved key, which is what "Clear saved key" means and what the panel
/// only ever sends deliberately. It does not remove a key that came from the environment: this
/// process cannot change another process's environment, and pretending otherwise would make the
/// panel describe a state it cannot reach.
async fn Shell::save_key(self : Shell, key : String) -> Unit {
  let updated = @core.AppSettings::with_saved_api_key(self.settings, key)
  @platform.save_settings(self.home, updated)
  self.settings = updated
  say_status(
    if updated.saved_api_key == "" {
      "saved key cleared"
    } else {
      "key saved — the next turn uses it"
    },
  )
  // `ready` again, because one of the four facts it carries has just changed: this is what turns the
  // window from "no API key" back into a shell that can send. It is the same event, re-sent, rather
  // than a second event the host would have to learn to combine with it.
  say_ready(self, key_source_name(resolve_key(self.settings)))
  self.say_settings()
}

///|
/// Switch which tools a turn gets.
///
/// Honoured on the next turn, not the one running: the mode decides which tools are *declared*, and
/// a declaration is only read when a request is built. An unknown word is the default mode, which is
/// the same rule `decode_app_settings` applies to a hand-edited file — a typo should cost a mode,
/// not the setting.
async fn Shell::set_mode(self : Shell, name : String) -> Unit {
  let updated = @core.AppSettings::with_tool_mode(
    self.settings,
    @core.parse_tool_mode(name),
  )
  @platform.save_settings(self.home, updated)
  self.settings = updated
  say_status(
    "tools: \{updated.tool_mode.to_string()} — the next turn uses them",
  )
  self.say_settings()
}
