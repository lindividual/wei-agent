///|
/// Forking a session: a copy with a file of its own, and nothing else.
///
/// ## What a fork is, and what it is not
///
/// A fork is a **snapshot**, not a mirror. Nothing connects the two files afterwards: the parent goes on
/// growing where it was, the child grows here, and neither will ever see the other's turns. That is the
/// whole point — it is a way to try something without risking the conversation that got you there — and
/// it is why the code says "fork" and not "duplicate", which would promise a copy that keeps up.
///
/// It is also **not** a branch *inside* one log. The format could express that (`leaf_id` can point back
/// at any entry, and a `branch_summary` stands in for the path left behind), and this deliberately does
/// not use it. Two reasons, and the second is the one that decides it:
///
/// 1. **Every layer here is built on "one row is one file"** — the list, the search, the delete, the
///    undo, the background spinner. A branch inside a log is a second state for all of them to learn.
/// 2. **A mis-click costs a conversation.** Moving the leaf is how you would switch branches, and the
///    leaf is where the next turn is appended: a click in the wrong place discards everything after it.
///    A fork that produced a file too many costs a row, and the row can be deleted.
///
/// The one thing that makes a fork more than `cp` is here rather than in the caller, because it is a
/// fact about the *log* and not about the filesystem: the copied history is made **acceptable to a
/// provider**. A conversation that ends mid-turn, or with a tool call nobody answered, is one whose
/// first request is refused — with the reason at a byte offset, which reads as "the model is broken".
/// See `fork_session`.

///|
/// The header and entries of a fork of `parent`, ready to be written as this session's file.
///
/// Pure: the id, the timestamp, the name and the parent's path all arrive as arguments, so the whole
/// decision is testable without a disk. The caller is what writes the file.
///
/// `parent_path` is the parent *file*, not its entries: it is what `parentSession` records, and it is
/// what a reader would follow to open the conversation this one came from.
pub fn fork_session(
  parent : Session,
  parent_path : String,
  id : String,
  name : String,
  timestamp : Int64,
) -> (SessionHeader, Array[Entry]) {
  let header : SessionHeader = {
    id,
    timestamp: format_iso_utc(timestamp),
    cwd: parent.header.cwd,
    parent_session: Some(parent_path),
    version: Some(3),
  }
  // **The entries are copied as they are, ids included.** An entry is referred to by its id — a
  // child's `parent_id`, a tool result's `call_id` — so renumbering them would break the chain and
  // the tool results at once. Copies that share ids with their parent are not a collision: ids only
  // have to be unique within a session, and that is what the comment on `new_entry_id` already says.
  let entries : Array[Entry] = []
  for entry in parent.entries {
    entries.push(entry)
  }
  let mut leaf = match parent.leaf_id {
    Some(id) => Some(id)
    None => None
  }
  // **A turn left open is closed here.** The parent may have been interrupted, or may be running right
  // now — a fork does not wait for it, since a fork takes a copy and touches nothing. Either way the
  // child must not open on "this turn was interrupted — continue or start over": that question is about
  // work that happened in a conversation the reader has just walked away from.
  //
  // The same entry the driver writes when it abandons a turn (`plan_repair`'s `Abandon` step), so the
  // two ways a turn is given up on produce the same log.
  if parent.turn_in_flight() {
    let entry = turn_outcome_entry(Abandoned, 0, 0.0, leaf, timestamp)
    leaf = Some(entry.id)
    entries.push(entry)
  }
  // The fork point, as an entry of its own. `custom` rather than a message, which is what keeps it out
  // of the conversation: `context_messages_of` answers with nothing for a type it does not know, so
  // this is invisible to the model and to the transcript, and a reader that does not know the type
  // skips it. What it is *for* is the two things a copy cannot say by itself — which session this came
  // from (`forked_from`), and **where this session's own spending starts** (`Session::usage`), which is
  // the reason it cannot be a field on the header: a field would have to be read by every version of
  // the format, and the arithmetic would be a baseline to keep rather than an entry to read.
  let marker = fork_entry(parent_path, leaf, leaf, timestamp)
  leaf = Some(marker.id)
  entries.push(marker)
  // **And a name, because a copy is otherwise indistinguishable from its parent.** The label falls back
  // to the first question, which is exactly what the parent's is — two rows reading "how do I make the
  // banner smaller" next to each other, with nothing to say which is which. The rule is the literal
  // prefix and nothing cleverer: the parent's displayed name, whatever it happens to be, so a fork of a
  // fork reads `(fork) (fork) …`. Stripping the prefix instead would make a child and its parent look
  // the same, and would claim the fork was taken from the grandparent, which is not true.
  let named = session_name_entry(Some(name), leaf, timestamp)
  entries.push(named)
  (header, entries)
}

///|
/// What to call a fork: the literal prefix and the parent's name, and nothing cleverer.
///
/// The parent's **displayed** name — what the reader gave it, else its first question, else its id —
/// because that is the name the two rows in the list have to be told apart by. So the rule is one line,
/// and what it deliberately does not do is *strip* a prefix it finds: a fork of a fork reads
/// `(fork) (fork) …`, which is ugly and true. Stripping would make a child look exactly like its parent
/// (both ending up as `(fork) grandfather`, with the parent's own name in between), and it would report
/// the fork as having come from the grandparent, which is a different conversation.
pub fn fork_name(parent_label : String) -> String {
  "(fork) " + parent_label
}

///|
/// The session this one was forked from, if it was.
///
/// The newest marker on the path, so a fork of a fork names the session it came from rather than the
/// whole ancestry — the same "last one wins" rule the name follows, and for the same reason: what a
/// reader is asking is "where did *this* come from".
pub fn Session::forked_from(self : Session) -> String? {
  let mut found : String? = None
  for entry in self.path() {
    match entry.kind {
      Custom(custom_type~, data~) =>
        if custom_type == fork_type() {
          found = match data {
            Some(Json::Object(fields)) =>
              match fields.get("parent") {
                Some(String(path)) => Some(path)
                _ => found
              }
            _ => found
          }
        }
      _ => ()
    }
  }
  found
}
