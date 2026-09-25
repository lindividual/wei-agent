///|
/// The rules that decide when a remembered fact is still true, and how much of a log has to be read.
///
/// These are the whole of the design's safety: everything else is plumbing. A wrong answer here does
/// not make the list slower, it makes it *lie* — and the lie has no symptom, because a session drawn
/// under its first question looks exactly like a session nobody has renamed.

///|
/// A stored fact, for the tests below.
fn fact(
  path : String,
  modified : Int64,
  scanned : Int64,
  label : String,
  name : String?,
) -> @core.SessionFacts {
  { path, modified, scanned, label, name, }
}

///|
test "a fact is trusted exactly when the file has not moved" {
  let known = fact("/s/a.jsonl", 100L, 500L, "hello", None)
  assert_true(@core.facts_unchanged(Some(known), 100L))
  // The clock moved: the file is not the one these facts describe.
  assert_false(@core.facts_unchanged(Some(known), 101L))
  // Nothing known is not a fact to trust, whatever the clock says.
  assert_false(@core.facts_unchanged(None, 100L))
}

///|
/// **A negative sweep mark is not a place.** It says "we cannot say where the sweep got to", and the
/// only safe reading of that is to sweep again — the zero-length file it would otherwise describe is
/// a log nobody has written, which would make a real session look empty forever.
test "a fact with a nonsense sweep mark is not trusted" {
  let broken = fact("/s/a.jsonl", 100L, -1L, "hello", None)
  assert_false(@core.facts_unchanged(Some(broken), 100L))
}

///|
/// The one property that makes an incremental search sound: **a log only grows.**
///
/// Everything the resume rule rests on is here. A longer file was appended to, so the bytes below the
/// mark are the same bytes and a rename entry that was not among them is still not among them.
test "a longer log is searched from the mark, a rewritten one from the start" {
  let known = fact("/s/a.jsonl", 100L, 500L, "hello", None)
  assert_eq(
    @core.plan_read(Some(known), 900L),
    @core.Appended(from=500L, relabel=false),
  )

  // **Did not grow: read it all.** Reaching this at all means the clock moved, so a file the same
  // length as before was rewritten in place — `repair_session`, or somebody's editor — and an entry
  // may have moved to anywhere in it. An entry that *moved into* the swept region would be invisible
  // to an incremental search forever, which is the one failure with no way back.
  assert_eq(@core.plan_read(Some(known), 500L), @core.Whole)
  // Shorter: unambiguously rewritten.
  assert_eq(@core.plan_read(Some(known), 100L), @core.Whole)
}

///|
/// A fact that has never been written is read whole, and so is one whose mark is nonsense.
test "no fact, or no mark, means read the whole log" {
  assert_eq(@core.plan_read(None, 900L), @core.Whole)
  let no_mark = fact("/s/a.jsonl", 100L, -1L, "", None)
  // Negative is not greater than the size, so this lands on `Whole` — which is the answer, and it is
  // reached by the size comparison rather than by a second rule about negative marks.
  assert_eq(@core.plan_read(Some(no_mark), 900L), @core.Whole)
}

///|
/// A session whose first question has not been written yet is re-labelled on every append.
///
/// **This is the one asymmetry between the two facts.** A name is settled once a rename entry exists,
/// so new bytes can only add to it; a *label* is settled once a first question exists, and an empty one
/// is a question still waiting to be asked. A refresh that took the cached empty label at face value
/// would draw a session as its id for the rest of its life — the first prompt would never appear.
test "an empty label is re-read on every append, a real one never is" {
  let unlabelled = fact("/s/a.jsonl", 100L, 500L, "", None)
  assert_eq(
    @core.plan_read(Some(unlabelled), 900L),
    @core.Appended(from=500L, relabel=true),
  )
  let labelled = fact("/s/a.jsonl", 100L, 500L, "what did I ask", None)
  assert_eq(
    @core.plan_read(Some(labelled), 900L),
    @core.Appended(from=500L, relabel=false),
  )
}

///|
/// A round trip through the file's own format, with and without a name.
///
/// The file is meant to be readable by a person — that is why the records are objects rather than
/// lists — so what is pinned here is that a fact survives as the same fact and that an absent name
/// stays absent. `None` and "no rename entry" are the same answer everywhere in this design, so a round
/// trip that turned one into the other would be turning a fact into a different fact.
///
/// Looked up by path rather than by position. Encoding sorts the records — which matters, and is
/// asserted below — but the *direction* of that sort is not a promise to anybody, so a test that read
/// them by index would be pinning an accident.
test "facts survive a round trip, and an absent name stays absent" {
  let named = fact("/s/b.jsonl", 200L, 900L, "the second one", Some("named it"))
  let bare = fact("/s/a.jsonl", 100L, 500L, "the first one", None)
  let decoded = @core.parse_facts(@core.encode_facts([named, bare]))
  assert_eq(decoded.length(), 2)

  let mut seen_named = false
  let mut seen_bare = false
  for fact in decoded {
    if fact.path == "/s/b.jsonl" {
      seen_named = true
      assert_eq(fact.name, Some("named it"))
      assert_eq(fact.scanned, 900L)
      assert_eq(fact.label, "the second one")
      assert_eq(fact.modified, 200L)
    } else if fact.path == "/s/a.jsonl" {
      seen_bare = true
      assert_eq(fact.name, None)
      assert_eq(fact.scanned, 500L)
    }
  }
  assert_true(seen_named, msg="the named fact came back")
  assert_true(seen_bare, msg="the unnamed fact came back")

  // An empty label is a fact, not an absence of one — and so is a sweep mark of zero, which is the
  // whole of how a deferred session is recorded.
  let blank = @core.parse_facts(
    @core.encode_facts([fact("/s/c.jsonl", 1L, 0L, "", None)]),
  )
  assert_eq(blank.length(), 1)
  assert_eq(blank[0].label, "")
  assert_eq(blank[0].scanned, 0L)
  assert_eq(blank[0].name, None)

  // **The same facts are the same bytes**, whichever order they were learned in. This is what makes
  // the file worth looking at: a diff of it says what changed rather than that everything moved.
  assert_eq(
    @core.encode_facts([named, bare]),
    @core.encode_facts([bare, named]),
  )
}

///|
/// A record that cannot name a session is dropped; one that merely lost a field is kept.
///
/// The file is written by a process that may be killed mid-write and it is hand-editable, so a list
/// that refused to load because of one bad record would trade a whole feature for one entry. Dropping
/// the unkeyable record costs a re-read of whatever session it was about, and nothing else.
test "an unreadable record costs itself and not the file" {
  let text =
    #|[{"modified":100,"scanned":500,"label":"kept"},{"path":"/s/a.jsonl","modified":100,"scanned":500,"label":"the first one"},{"path":"/s/b.jsonl","label":"no modified"}]
  let decoded = @core.parse_facts(text)
  // The first record has no path — a fact about nothing, with no key to file it under — and the third
  // has no modification time, without which the fact could never be judged stale or fresh. Both go,
  // and the good record between them survives.
  assert_eq(decoded.length(), 1)
  assert_eq(decoded[0].path, "/s/a.jsonl")
}

///|
/// A file that is not a list of records at all reads as nothing known.
///
/// A first run, a truncated write and a hand-edit into nonsense are the same answer: read the
/// sessions. That is what the program did before this file existed, so it cannot be worse than the
/// behaviour it replaced.
test "nonsense decodes to nothing known" {
  assert_eq(@core.parse_facts("not json at all").length(), 0)
  assert_eq(@core.parse_facts("").length(), 0)
  assert_eq(@core.parse_facts("{\"facts\":[]}").length(), 0)
  assert_eq(@core.parse_facts("[]").length(), 0)
}
