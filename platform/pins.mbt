///|
/// Where the pinned sessions live, and reading and writing them.
///
/// The decisions — what a mangled file decodes to, whether a path is already pinned — are in
/// `core/pins.mbt`. This file only knows a path and how to move bytes, which is the same split as
/// the settings, the job records and the skills: pure parsing in `core`, the filesystem here.
///
/// One file per home directory rather than per workspace, deliberately, and for the settings'
/// reason: which sessions a reader keeps at the top of the list is a fact about the person, not
/// about the repository they happen to be standing in.

///|
/// The pins file: `~/.wei/pins.json`.
///
/// Beside the sessions, the settings and the jobs rather than under `~/.upstream/`, for the reason
/// all of those are there: this is a second implementation keeping its own state, and sharing
/// upstream's configuration invites two processes editing one file.
pub fn pins_path(home : String) -> String {
  "\{home}/.wei/pins.json"
}

///|
/// How much of the file to read.
///
/// A pin is a path and a store holds tens of them, so this is generous by orders of magnitude. The
/// cap is here because the file is on disk and therefore editable: a read that cannot be bounded is
/// one that can run out of memory on start.
fn pins_max_bytes() -> Int {
  262144
}

///|
/// The pinned sessions, or none when there is nothing to read.
///
/// Never raises: a missing file is a first run and a mangled one reads as no pins, both of which are
/// ordinary states for a list a reader is free to delete.
pub async fn load_pins(home : String) -> Array[String] {
  @core.parse_pins(read_prefix(pins_path(home), pins_max_bytes()))
}

///|
/// Write the pinned sessions out.
///
/// Temp file and rename, like the settings: the rename is atomic, so a reader either sees the pins
/// they had or the pins they just asked for, and a crash mid-write cannot leave a file that parses
/// as "nothing is pinned" — which is a state the reader did not ask for and could not tell from the
/// one they did.
pub async fn save_pins(home : String, pins : Array[String]) -> Unit {
  let path = pins_path(home)
  let temp = "\{path}.tmp"
  make_dirs(@core.parent_of(path))
  write_text(temp, @core.encode_pins(pins) + "\n")
  @fs.rename(temp, path)
}
