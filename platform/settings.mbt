///|
/// Where the settings file lives, and reading and writing it.
///
/// The decisions — what a key means, whether a skill is off, what a corrupt file decodes to —
/// are in `core/settings.mbt`. This file only knows a path and how to move bytes, which is the
/// same split as skills: pure parsing in `core`, the filesystem here.
///
/// One file per home directory rather than per workspace, deliberately. A saved key and a
/// switched-off skill are facts about the person using the machine, not about the repository
/// they happen to be standing in — and a per-project copy would mean the same skill had to be
/// silenced again in every checkout.

///|
/// The settings file: `~/.wei/settings.json`.
///
/// Beside the sessions rather than under `~/.upstream/`, for the same reason the session store is:
/// this is a second implementation reading and writing its own state, and sharing upstream's
/// credential or config files invites two processes editing one file.
pub fn settings_path(home : String) -> String {
  "\{home}/.wei/settings.json"
}

///|
/// How much of the file to read.
///
/// A cap rather than a whole-file read because the file is hand-editable and the panel should
/// not be the place a stray multi-megabyte file is found out: a key and a list of names fit in a
/// few kilobytes, and the read is lossy as well as bounded, so this cannot raise.
fn settings_max_bytes() -> Int {
  65536
}

///|
/// The saved settings, or the empty settings when there are none to read.
pub async fn load_settings(home : String) -> @core.AppSettings {
  @core.decode_app_settings(
    read_prefix(settings_path(home), settings_max_bytes()),
  )
}

///|
/// The DeepSeek key this process should send, or `None` when there is none to send.
///
/// The *choice* is `@core.choose_api_key`'s and is not restated here; what this adds is the reading
/// of the two sources it decides between, so that a front end does not have to know the name of an
/// environment variable to ask for a key. Two front ends had their own copy of that, and the day
/// the precedence changes they would have gone on using the old one.
///
/// The file is opened only when the environment has nothing: the environment wins anyway, so a
/// settings file that cannot be read must not be able to fail a run that never needed it.
pub async fn api_key(home : String) -> String? {
  let from_environment = match @env.get_env_var("DEEPSEEK_API_KEY") {
    Some(key) => key
    None => ""
  }
  let saved = if from_environment == "" {
    load_settings(home).saved_api_key
  } else {
    ""
  }
  @core.choose_api_key(from_environment, saved).map(choice => choice.key)
}

///|
/// Write the settings out.
///
/// Written beside the real file and renamed over it, because a reader who opens the panel twice
/// in a hurry can otherwise catch a half-written file: the rename is atomic, so the file is
/// always either the old settings or the new ones. Renaming is also why this creates the parent
/// directory first — the first save is the one that has to make `~/.wei/`.
pub async fn save_settings(home : String, settings : @core.AppSettings) -> Unit {
  let path = settings_path(home)
  let temp = "\{path}.tmp"
  make_dirs(@core.parent_of(path))
  write_text(temp, @core.encode_app_settings(settings) + "\n")
  @fs.rename(temp, path)
}
