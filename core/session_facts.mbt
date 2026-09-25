///|
/// What a session file says, kept so that the sidebar does not have to read the file to know it.
///
/// The sidebar needs two things out of every log, and they sit at opposite ends of it: **what the
/// reader first asked** (near the head — `@core.session_label`) and **what they later called it** (a
/// `session_info` entry, which a rename puts wherever the conversation had got to). Nothing between
/// the two matters to a list.
///
/// **This value exists because both of those are stable in a way the file is not.** A log is appended
/// to on every turn and grows without bound, while the first question never changes once it is written
/// and a name changes only when somebody renames the session. Deriving them from the log every time
/// therefore reads whole conversations — tens of megabytes each, in this machine's own store — to
/// rediscover two strings that have not moved. What is here is the answer to *what did this file say*,
/// kept beside enough of the file's identity to know when the answer is still true.
///
/// **It is a cache and is allowed to be wrong; it is never allowed to be silently wrong.** Losing the
/// file costs a re-read, which is what the program did before it existed, and every rule about
/// staleness below is written to fail towards reading too much rather than towards a stale name. The
/// one thing this must never do is make a rename invisible, because a session drawn under its first
/// question looks exactly like a session nobody has renamed — the failure has no symptom to notice.

///|
/// The truths a section of a session file established, and its label.
pub(all) struct SessionFacts {
  /// The file. The key everything else here is about.
  path : String
  /// Milliseconds since the epoch, as the store's own listing reported it.
  ///
  /// The store walks the directory and stats every file already, so this is the one number that comes
  /// free — and the one that decides whether any of the rest is worth asking about. A log the reader
  /// is not writing to has the modification time it had last time, which is what keeps a refresh from
  /// opening a single file.
  modified : Int64
  /// How many bytes of the log have been searched for a rename entry.
  ///
  /// Equal to the file's size at the moment `name` was decided, which is what makes it a place a
  /// later search can resume from — and the reason it is stored rather than derived: the bytes below
  /// it have been swept, and sweeping them again is the whole cost this type exists to avoid.
  scanned : Int64
  /// The first thing the reader asked, or empty for a log whose first turn is not written yet.
  ///
  /// Empty is a real answer and is cached like any other — a session is created before it is written,
  /// and it will change exactly when the file does.
  label : String
  /// The reader's own name for the session, or `None` when the log holds no rename *on its leaf
  /// chain*. `None` and "no rename entry" are deliberately the same answer: see `Session::name`.
  name : String?
} derive(Eq, Debug)

///|
/// How much of a log has to be read to bring its facts up to date.
pub(all) enum FactsRead {
  /// Everything below `from` has already been swept and is not worth sweeping again. Search from
  /// there to the end, and read the head again only when `label` — which is true when there is no
  /// first question yet, because that is the one fact an append can still be the first to supply.
  Appended(from~ : Int64, relabel~ : Bool)
  /// Read the whole log: the label from its head, and a rename entry from anywhere in it.
  Whole
} derive(Eq, Debug)

///|
/// Whether the store's own clock says this file is still the one these facts describe.
///
/// One comparison, and the one that does the work: every refresh asks it of every session in the
/// store, and answering `true` is what a refresh costs when nothing has happened — no open, no read,
/// no stat of its own.
///
/// A modification time is trusted as the identity of a log, which is the same trust the in-memory
/// cache kept before this one, one process deep. It is sound for the same reason: the only writers
/// that touch a session file append to it, and an append moves the clock. What it cannot see is a
/// rewrite that restores the old clock deliberately, which is not a thing any writer here does.
pub fn facts_unchanged(prev : SessionFacts?, modified : Int64) -> Bool {
  match prev {
    Some(prev) => prev.modified == modified && prev.scanned >= 0L
    None => false
  }
}

///|
/// Where to start reading a log, given how long it is now.
///
/// **`Appended` rests on one property of this program: a session log only grows.** Every writer
/// appends — one line per entry, never a read-modify-write, which `platform/session.mbt` gives as the
/// reason the log is a log — so a longer file is the same file with more on the end, and a rename
/// entry that was not in the first `scanned` bytes is still not there. The single writer that rewrites
/// anything is `@agent.repair_session`, and it rewrites a **suffix**: entries before the first
/// misplaced one are left where they are, and it *moves* entries rather than adding or removing them,
/// so the rename entry whose absence we recorded cannot have been removed by it.
///
/// **A file that did not grow is read whole**, and that is the rule that makes the property load
/// bearing rather than assumed. Reaching here at all means the clock moved, so a log the same length
/// as before was rewritten in place — `repair_session`, or somebody's editor — and an entry may have
/// moved anywhere in it. Reading it is what is correct there, and it is what happens.
///
/// **One hole in this is not closable and is worth naming.** If the file shrinks below the mark and
/// then grows past it again *between two of our reads*, the comparison above sees a longer file and
/// resumes — while the rewrite that happened in between is below the mark and invisible. Nothing in a
/// modification time and a length can see that; it would take watching the file (an fswatch) or
/// hashing its contents, and both cost more than the read they are protecting. What it can cost is a
/// stale *name*: a rename entry that the rewrite moved below the mark, in a session this process has
/// open while another host repairs the same file. The label survives it — a label is re-derived from
/// the head on any relabel — and the next full read corrects the name. Left as a known limit rather
/// than papered over, because every way of papering over it is more expensive than the bug.
pub fn plan_read(prev : SessionFacts?, size : Int64) -> FactsRead {
  let prev = match prev {
    None => return Whole
    Some(prev) => prev
  }
  // **A mark that is not a position is not a place to start from.** A negative sweep mark says "we
  // cannot say where the sweep got to" — an older file, a hand-edit, a truncated write — and the only
  // reading of that which cannot lose an entry is to sweep the file again. Without this it would come
  // out as `Appended(from=-1)`, which is correct only because the search happens to clamp its own
  // offset, and a rule that is right by accident is one refactor away from being wrong.
  if prev.scanned < 0L {
    return Whole
  }
  if size > prev.scanned {
    Appended(from=prev.scanned, relabel=prev.label == "")
  } else {
    Whole
  }
}

///|
/// Read a facts file back, skipping anything malformed.
///
/// Tolerant on purpose, and in the direction the type's own note gives: this file is written by a
/// process that may have been killed mid-write, and a single unreadable record must cost the reader
/// one session's re-read rather than every other record in the file. A file that does not parse at
/// all reads as nothing known, which is the same thing a first run sees.
pub fn parse_facts(text : String) -> Array[SessionFacts] {
  let parsed = try @json.parse(text) catch {
    _ => return []
  } noraise {
    json => json
  }
  let items = match parsed {
    Array(items) => items
    _ => return []
  }
  let out : Array[SessionFacts] = []
  for item in items {
    let path = match json_string(item, "path") {
      Some(value) if value != "" => value
      // A record with no path is a record about nothing: there is no key to file it under, and a
      // guess would be a fact attributed to the wrong session.
      _ => continue
    }
    let modified = match json_int64(item, "modified") {
      Some(value) => value
      None => continue
    }
    let scanned = match json_int64(item, "scanned") {
      Some(value) if value >= 0L => value
      // Absent or negative means "we cannot say where the sweep got to", which is answered by
      // sweeping the file again. An older file written before this field existed reads this way.
      _ => 0L
    }
    let name = match json_string(item, "name") {
      Some(value) if value != "" => Some(value)
      _ => None
    }
    out.push({
      path,
      modified,
      scanned,
      label: json_string(item, "label").unwrap_or(""),
      name,
    })
  }
  out
}

///|
/// Write the facts out.
///
/// One object per session rather than a list of lists, because the file is meant to be diagnosable —
/// "why does this row show that name" is answered by reading the record for it — and because the
/// fields are of three types, two of which are not strings.
///
/// **Sorted by path, so the file is the same bytes for the same facts.** That is the property, and the
/// only one: the direction is an implementation detail that nothing reads, because a session is found
/// in this file by searching for its path. What determinism buys is a file whose diff means something —
/// a store that has not changed produces the file it produced last time, byte for byte — and a file
/// that is rewritten in a fresh order every launch is one whose diff says only "everything moved".
pub fn encode_facts(facts : Array[SessionFacts]) -> String {
  let ordered = facts.copy()
  ordered.sort_by((a, b) => a.path.compare(b.path))
  let items : Array[Json] = []
  for fact in ordered {
    if fact.path == "" {
      continue
    }
    let fields : Map[String, Json] = Map([])
    fields.set("path", Json::string(fact.path))
    fields.set(
      "modified",
      Json::number(fact.modified.to_double(), repr=fact.modified.to_string()),
    )
    fields.set(
      "scanned",
      Json::number(fact.scanned.to_double(), repr=fact.scanned.to_string()),
    )
    fields.set("label", Json::string(fact.label))
    match fact.name {
      Some(name) => fields.set("name", Json::string(name))
      // Absent rather than `null`: the field's presence is the whole of what it says, and a reader
      // looking at the file sees a session with a name or one without.
      None => ()
    }
    items.push(Json::object(fields))
  }
  Json::array(items).stringify()
}
