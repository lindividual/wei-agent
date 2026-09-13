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
/// The settings file: `~/.pi-mb/settings.json`.
///
/// Beside the sessions rather than under `~/.pi/`, for the same reason the session store is:
/// this is a second implementation reading and writing its own state, and sharing pi's
/// credential or config files invites two processes editing one file.
pub fn settings_path(home : String) -> String {
  "\{home}/.pi-mb/settings.json"
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
/// Write the settings out.
///
/// Written beside the real file and renamed over it, because a reader who opens the panel twice
/// in a hurry can otherwise catch a half-written file: the rename is atomic, so the file is
/// always either the old settings or the new ones. Renaming is also why this creates the parent
/// directory first — the first save is the one that has to make `~/.pi-mb/`.
pub async fn save_settings(home : String, settings : @core.AppSettings) -> Unit {
  let path = settings_path(home)
  let temp = "\{path}.tmp"
  make_dirs(@core.parent_of(path))
  write_text(temp, @core.encode_app_settings(settings) + "\n")
  @fs.rename(temp, path)
}
