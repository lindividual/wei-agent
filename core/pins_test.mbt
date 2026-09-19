///|
/// The pin list and its file format.
///
/// Pure, so these run without a filesystem: what matters is what a corrupt file means, that one
/// session cannot be pinned twice, and that a pin survives a write and a read. The file itself is
/// written by `platform/pins.mbt`.

///|
test "a round trip preserves the pinned paths, in order" {
  let pins = ["/store/a/one.jsonl", "/store/b/two.jsonl"]
  assert_eq(parse_pins(encode_pins(pins)), pins)
  // Empty is a file with no pins in it, not a file that cannot be read.
  assert_eq(parse_pins(encode_pins([])).length(), 0)
}

///|
/// What the shell writes when a reader pins something.
test "pinning adds a path and unpinning takes it away" {
  let first = pins_set([], "/store/a/one.jsonl", true)
  assert_eq(first, ["/store/a/one.jsonl"])
  let both = pins_set(first, "/store/b/two.jsonl", true)
  assert_eq(both, ["/store/a/one.jsonl", "/store/b/two.jsonl"])
  // The second pin does not duplicate the first, and neither does pinning the same one twice: the
  // list is a set of paths, and a doubled entry would be two rows for one session.
  //
  // The *order* of the file is deliberately not asserted here, because nothing reads it: the list
  // each front end draws is in its own order ("most recently used first"), and a pin is a yes-or-no
  // fact on a row of it. What has to hold is that both paths are in the set, once each.
  let again = pins_set(both, "/store/a/one.jsonl", true)
  assert_eq(again.length(), 2)
  assert_true(again.contains("/store/a/one.jsonl"))
  assert_true(again.contains("/store/b/two.jsonl"))
  // Unpinning is by path, and it leaves the rest alone.
  assert_eq(pins_set(both, "/store/a/one.jsonl", false), ["/store/b/two.jsonl"])
  // Unpinning something that was never pinned is not an error, because the shell's answer to a
  // session that is already gone from the list is the same click twice.
  assert_eq(pins_set(both, "/store/c/three.jsonl", false), both)
  assert_eq(pins_set([], "", true).length(), 0)
}

///|
/// A file that is not a list of paths is read as the paths that *are* legible.
///
/// The file is hand-editable, so every one of these is a state a reader can produce: a truncated
/// write, a stray entry, a whole-file mistake. None of them is worth refusing to draw the list for.
test "a file that cannot be read is read as no pins" {
  assert_eq(parse_pins("").length(), 0)
  assert_eq(parse_pins("not json").length(), 0)
  assert_eq(parse_pins("{\"pins\":[]}").length(), 0)
  // An entry that is not a string is dropped rather than taken as a path, and so is an empty one.
  assert_eq(parse_pins("[\"/a\", 7, null, \"\"]"), ["/a"])
  // Duplicates collapse: two identical entries are one pin, because the list is a set of paths.
  assert_eq(parse_pins("[\"/a\",\"/a\"]"), ["/a"])
}
