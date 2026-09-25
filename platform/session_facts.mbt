///|
/// Where a shell keeps what it has learned about the session files, and the reads that maintain it.
///
/// The decisions — when a cached fact is still true, and how much of a log has to be read to know —
/// are in `core/session_facts.mbt`. This file only knows a path, a size, a clock and how to move
/// bytes, which is the same split the pins, the jobs and the settings use.
///
/// **The file is a cache and its loss is not a failure.** Every fact in it can be rebuilt by reading
/// the session it is about, which is what the program did before this existed. So every read here is
/// tolerant, every write is best-effort, and nothing in this file reports an error to anybody: a shell
/// that could not save what it learned is a shell that works exactly as it did yesterday.

///|
/// The facts file: `~/.wei/session_facts.json`.
///
/// Beside the sessions, the pins and the jobs, and for the reason the pins file gives for being there
/// rather than in the store: this is state this program keeps for itself. It is not inside the session
/// directory because that directory is the reader's — a store can be pointed elsewhere with
/// `WEI_STORE`, copied between machines and read by other front ends, and a sidecar of our own
/// bookkeeping is the one thing that should not travel with it.
///
/// Records are keyed by the full path of the session they describe, which is what makes that safe: a
/// record from a different store names paths that store has, so it can never be mistaken for a fact
/// about a session in this one.
pub fn facts_path(home : String) -> String {
  "\{home}/.wei/session_facts.json"
}

///|
/// How much of the file to read.
///
/// A record is a path, two numbers and two short strings, so this holds tens of thousands of sessions
/// with room to spare. The cap is here for the reason the pins file has one: this file is on disk and
/// therefore editable, and a read that cannot be bounded is one that can exhaust memory at startup.
/// Past it the oldest records are lost, which costs a re-read and nothing else.
fn facts_max_bytes() -> Int {
  4194304
}

///|
/// Everything known about the sessions, or nothing when there is nothing to read.
///
/// Never raises. A missing file is a first run and a mangled one reads as "nothing known", and both of
/// those are answered the same way — by reading the sessions themselves.
pub async fn load_facts(home : String) -> Array[@core.SessionFacts] {
  @core.parse_facts(read_prefix(facts_path(home), facts_max_bytes()))
}

///|
/// Write what is known out, replacing the file.
///
/// Temp file and rename, like the pins: the rename is atomic, so a process killed mid-write leaves the
/// file it had rather than a truncated one. A truncated file would still parse — `parse_facts` skips
/// what it cannot read — but it would do so by *losing* every record after the cut, which is a fresh
/// read of every session in the store on the next launch. That is the cost this file exists to avoid,
/// so it is worth a rename to avoid it.
///
/// Silent on failure, deliberately: the caller is a shell that has just sent the host a list, and it
/// has nothing to say about its own bookkeeping. It will simply read the sessions again next time.
pub async fn save_facts(
  home : String,
  facts : Array[@core.SessionFacts],
) -> Unit {
  let path = facts_path(home)
  try {
    make_dirs(@core.parent_of(path))
    let temp = temp_beside(path)
    write_text(temp, @core.encode_facts(facts) + "\n")
    @fs.rename(temp, path)
  } catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// A session file's size and modification time, or `None` when it cannot be measured.
///
/// **This is the whole cost of a refresh that has nothing to do**, so it is one `open` and two reads of
/// the handle the caller already has: an `open` plus a `size` plus an `mtime`. The store's own listing
/// hands the modification time over for free — it stats every file anyway, to order the list — which
/// is why this is called only for files that listing already said had changed, and its job is the one
/// number the listing does not carry: how long the file is now.
///
/// `None` rather than a guess: a file that cannot be opened cannot be compared, and a guess would be a
/// licence to skip re-reading something.
pub async fn facts_stamp(path : String) -> (Int64, Int64)? {
  let file = try @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    _ => return None
  } noraise {
    file => file
  }
  defer file.close()
  let (seconds, nanos) = file.mtime()
  let modified = seconds * 1000L + nanos.to_int64() / 1000000L
  Some((file.size(), modified))
}

///|
/// Whether a log holds a rename entry after byte `from`.
///
/// The one caller is the sidebar, which records how far it has already swept a session log and is
/// appended to far more often than it is renamed. So the usual question is not "does this file hold a
/// rename" but "does the part written since last time" — and on this machine's own store that was the
/// difference between 218 ms to refresh after a single appended line and a read of a few hundred bytes.
///
/// **Searched as text, not as bytes, and deliberately.** A byte-wise search was written here first and
/// thrown away: measured, `Bytes::find` over a 21-byte needle costs about 1.5x what `String::contains`
/// does over the same text (411 ms against 273 ms for this machine's 103 MiB store), while decoding the
/// bytes is close to free because a session log is ASCII. Building a byte scanner to avoid a decode
/// that is not being paid for is the shape of mistake this whole change started as.
///
/// `from <= 0` is the whole file and goes through the same read the label uses. Anything else reads
/// only the tail — from a little **before** `from`, because a needle can straddle the boundary: those
/// bytes were swept last time, so re-sweeping them cannot invent a match, and not re-sweeping them
/// would lose one that spans the two sweeps.
pub async fn has_rename_entry(path : String, from : Int64) -> Bool {
  let token = @core.name_entry_token()
  let back = token.length().to_int64() - 1L
  let start = if from > back { from - back } else { 0L }
  if start <= 0L {
    // The whole file: the read the old whole-file test did, at the cost it had.
    return read_text_or_none(path).unwrap_or("").contains(token)
  }
  let (tail, _, _) = read_slice(path, start.to_int(), rest_of_file())
  tail.contains(token)
}

///|
/// How much of a file to ask for when the caller wants everything from an offset to the end.
///
/// Not a cap anybody is expected to hit — `read_slice` clamps to the file's own length, so this
/// only has to be larger than any session log. It is a number rather than `Int::max_value()` so that
/// the intent reads as "the rest" and not as "an overflow waiting to happen".
fn rest_of_file() -> Int {
  1 << 30
}
