///|
/// The sessions a reader has pinned: where they sit, and how that list is kept.
///
/// A pin is a fact about **the reader's list**, not about the conversation. Nothing inside a session
/// changes when it is pinned, the agent never reads it, and a session that was never opened on this
/// machine has no opinion about where it belongs. That is why this is not a `session_info` entry in
/// the log the way a name is: the log travels with the file, so one reader's shelf would become a
/// claim about the conversation that every other reader — another front end, another machine, the
/// next person to open the file — would see.
///
/// Paths rather than names, because a name is a thing the reader can change: a pin that fell off when
/// a session was renamed would be a pin that could not be relied on. The cost is a pin that stops
/// matching if the store moves, which is the honest kind of failure — the file is not there anyway.
///
/// Pure, so a file that is missing, empty or hand-mangled is a decided answer here rather than a
/// crash there: the path and the bytes are the platform's business (`platform/pins.mbt`), exactly as
/// the settings split it.

///|
/// Read a pins file back.
///
/// Anything unparsable, or of the wrong shape, or with entries that are not strings, is read as the
/// pins that *are* legible rather than as an error. The file is a convenience: a process that refused
/// to start because of it would be trading a small feature for the whole program, and the window is
/// where a reader sees what actually came through.
pub fn parse_pins(text : String) -> Array[String] {
  let parsed = try @json.parse(text) catch {
    _ => return []
  } noraise {
    json => json
  }
  let out : Array[String] = []
  match parsed {
    Array(items) =>
      for item in items {
        match item {
          String(path) =>
            if path != "" && !out.contains(path) {
              out.push(path)
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Write the pins out.
///
/// A plain array of paths rather than an object per pin, because there is exactly one fact per pin
/// and the file is meant to be readable — and, when something goes wrong, editable — by hand.
pub fn encode_pins(pins : Array[String]) -> String {
  let items : Array[Json] = []
  for path in pins {
    if path != "" {
      items.push(Json::string(path))
    }
  }
  Json::array(items).stringify()
}

///|
/// A copy with one session pinned or unpinned.
///
/// Rebuilt rather than mutated in place, for the reason `AppSettings::with_skill_enabled` is: the
/// array came from a decoded file or from an earlier copy of this value, and mutating something the
/// caller still holds is how one click turns out to have changed two things.
///
/// **The order of the file is not an order on screen.** A pin is a yes-or-no fact, and each front end
/// draws the pinned sessions in the order its own list is already in — the macOS list keeps them in
/// "most recently used first", the same axis the rest of the list uses. Sorting here instead would
/// make the file's order a second opinion about a question the list has already answered.
pub fn pins_set(
  pins : Array[String],
  path : String,
  pinned : Bool,
) -> Array[String] {
  let out : Array[String] = []
  for existing in pins {
    if existing != path && existing != "" && !out.contains(existing) {
      out.push(existing)
    }
  }
  if pinned && path != "" {
    out.push(path)
  }
  out
}
