///|
/// Rendering a block that is still growing.
///
/// Everything in this file exists to answer one question cheaply: *how much of a growing block can
/// be kept from one parse to the next*. Re-parsing the whole of it on every frame is quadratic —
/// measured on this machine, 400 parses of a document that averaged 20KB took 2.16 seconds — so the
/// answer has to be "almost all of it".
///
/// The rule is a boundary plus a diff:
///
/// - `safe_boundary` finds the end of the part that **cannot change again**: the last blank line at
///   the top level. Everything before it is finished markdown, parsed once and never re-sent, which
///   is what keeps the reader's screen from reflowing under them while the model writes. Everything
///   after it is the one block being written — an open paragraph, an open fence, an open table — and
///   it is not parsed at all while it grows: it crosses as deltas and the host draws it as text. The
///   boundary goes out with the frame (`parsed`, in `macos/appffi/events.mbt`), which is how the host
///   knows where the blocks stop. It is parsed once, when it stops being the newest thing that
///   happened.
/// - `diff_prefix` says how much of a **finished** block's parse is unchanged, for the moment a
///   block stops growing. That is the one point where a block is re-parsed whole (there is no
///   boundary left to prefer, because it is over), and the diff is what keeps the result from being
///   re-sent whole.

///|
/// Where the part of `text` that can no longer change ends.
///
/// The boundary is the end of the last top-level blank line, and it is 0 when there is none — a
/// document that has not written a blank line yet has no finished block in it, so every parse before
/// then is of the whole thing. That is the honest answer rather than a small one: a single paragraph
/// of forty kilobytes is re-parsed on every frame, which costs a few milliseconds and cannot be
/// avoided without cutting the paragraph in two.
///
/// A blank line **inside a fenced block** is not a boundary. A fence is the one thing in markdown
/// whose contents are not markdown, and a code block cut in half at its own blank line would come
/// out as two blocks on screen and as garbage in the reader's copy-paste.
///
/// The known distortion, stated rather than hidden: a blank line between two list items is a
/// boundary here and a *loose* list there — the parse of `- a` alone is a tight list, and the full
/// document is one loose list. The items and their numbers survive (markdown numbers are written by
/// the author), so what a reader sees is a little more or less space between items while the model
/// writes the list. It is the cheapest of the available lies: the alternative is re-parsing the whole
/// block on every frame.
pub fn safe_boundary(text : String) -> Int {
  let mut boundary = 0
  // The current line, as far as this scanner cares about it: how far it is indented, the run of one
  // character it starts with, and whether anything else is on it.
  let line = Line::new()
  // An open fence, if there is one: its character and the length of its opening run.
  let mut fence : UInt16? = None
  let mut fence_len = 0
  // Code units, not characters: the answer is used as a `String` index, and an index in characters
  // is off by one for every emoji above the boundary — which reasoning text is full of.
  for index in 0..<text.length() {
    let unit = text.at(index)
    if unit == NEWLINE {
      let (next_fence, next_len, is_boundary) = line.close(fence, fence_len)
      fence = next_fence
      fence_len = next_len
      if is_boundary {
        // Just past the newline: the prefix ends *with* the blank line, so the tail never starts on
        // the far side of a blank line the prefix already consumed.
        boundary = index + 1
      }
      line.reset()
    } else {
      line.write(unit)
    }
  }
  // A last line with no newline of its own is judged by the same rule; a blank one is a boundary at
  // the end of the text, which is what makes a document ending in a blank line fully finished.
  if line.close(fence, fence_len).2 {
    boundary = text.length()
  }
  boundary
}

///|
/// The code unit a fence is written with. The scanner is over code units rather than characters
/// because its answer is a `String` index.
const BACKTICK : UInt16 = 0x60

///|
const TILDE : UInt16 = 0x7E

///|
const SPACE : UInt16 = 0x20

///|
const NEWLINE : UInt16 = 0x0A

///|
/// One line, as the scanner reads it.
///
/// A little mutable thing with three facts and two questions, rather than four parallel variables in
/// the loop above: the fence rules are the only subtle part of the boundary, and they are about a
/// line's *shape*, so the shape gets a name.
priv struct Line {
  /// Code units before the first non-space one.
  mut spaces : Int
  /// The first non-space code unit, and how many of it the line starts with.
  mut lead : UInt16
  mut lead_run : Int
  /// Whether the leading run has been broken — by a different code unit or by a space. A fence is
  /// the whole line, so a line with anything after its run is not one.
  mut broken : Bool
  /// Non-space code units other than the leading run.
  mut extra : Int
}

///|
fn Line::new() -> Line {
  { spaces: 0, lead: 0, lead_run: 0, broken: false, extra: 0, }
}

///|
/// Start reading the next line. A line's facts are about *that* line, so the scanner hands its state
/// back after judging each one.
fn Line::reset(self : Line) -> Unit {
  self.spaces = 0
  self.lead = 0
  self.lead_run = 0
  self.broken = false
  self.extra = 0
}

///|
fn Line::write(self : Line, unit : UInt16) -> Unit {
  if unit == SPACE {
    if self.lead_run > 0 {
      self.broken = true
    } else if !self.broken {
      self.spaces += 1
    }
    return
  }
  if self.lead_run == 0 && !self.broken {
    self.lead = unit
    self.lead_run = 1
  } else if !self.broken && unit == self.lead {
    self.lead_run += 1
  } else {
    self.broken = true
    self.extra += 1
  }
}

///|
/// A line with nothing on it but spaces.
fn Line::blank(self : Line) -> Bool {
  self.lead_run == 0 && self.extra == 0
}

///|
/// A line that **opens** a fence: a run of `unit`, at least three long, at the start of the line.
///
/// An info string after the run is allowed, and that is the whole difference between this and
/// `Line::closes_fence`: ```moonbit is an opener, and only the *closer* has to be nothing but the run.
fn Line::opens_fence(self : Line, unit : UInt16) -> Bool {
  self.spaces <= 3 && self.lead == unit && self.lead_run >= 3
}

///|
/// A line that **closes** a fence: nothing but a run of `unit` at least as long as the opener's, and
/// indented by no more than three spaces. The run length is what makes ````` not close ````.
fn Line::closes_fence(self : Line, unit : UInt16, at_least : Int) -> Bool {
  !self.broken &&
  self.extra == 0 &&
  self.spaces <= 3 &&
  self.lead == unit &&
  self.lead_run >= at_least
}

///|
/// What this line means: the fence after it, and whether it is a boundary.
fn Line::close(
  self : Line,
  fence : UInt16?,
  fence_len : Int,
) -> (UInt16?, Int, Bool) {
  match fence {
    Some(open) =>
      // Inside a fence nothing is markdown, so no line is a boundary and the only interesting one
      // is the closer.
      if self.closes_fence(open, fence_len) {
        (None, 0, false)
      } else {
        (fence, fence_len, false)
      }
    None =>
      if self.blank() {
        (None, 0, true)
      } else if self.opens_fence(BACKTICK) {
        (Some(BACKTICK), self.lead_run, false)
      } else if self.opens_fence(TILDE) {
        (Some(TILDE), self.lead_run, false)
      } else {
        (None, 0, false)
      }
  }
}

///|
/// How much of a previous parse is still the beginning of a new one.
///
/// The use is a block that has stopped growing: its text is parsed whole, and this says how many of
/// the leading blocks are the ones the host already has. The host keeps those and replaces the rest,
/// so what crosses the wire is the changed tail rather than the whole document again.
///
/// Blocks are compared by value, which is what `Eq` on `Block` is for — the JSON is the transport,
/// not the identity.
pub fn diff_prefix(previous : Array[Block], next : Array[Block]) -> Int {
  let limit = if previous.length() < next.length() {
    previous.length()
  } else {
    next.length()
  }
  let mut i = 0
  while i < limit && previous[i] == next[i] {
    i += 1
  }
  i
}
