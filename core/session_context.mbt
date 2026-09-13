///|
/// Deriving the model-visible conversation from a session.
///
/// A session is a tree; the active conversation is the path from the root to the
/// current leaf, with compaction applied. Nothing here mutates: the log stays
/// append-only, and "going back" is a matter of pointing `leaf_id` elsewhere.

///|
/// A model reference recorded by a `model_change` entry or an assistant message.
pub(all) struct ModelRef {
  provider : String
  model_id : String
} derive(Eq, Debug)

///|
/// One message as the model sees it.
///
/// Wider than `Message` because compaction and branching contribute entries that
/// the model must see as turns, even though they are not user or assistant
/// output. Keeping them distinct rather than flattening them into user text is
/// what lets a session read back byte-identically to pi's.
pub(all) enum ContextMessage {
  User(UserMessage)
  Assistant(AssistantMessage)
  ToolResult(ToolResultMessage)
  /// Stands in for the history a compaction replaced.
  CompactionSummary(summary~ : String, tokens_before~ : Int, timestamp~ : Int64)
  /// Stands in for the path a branch left behind.
  BranchSummary(summary~ : String, from_id~ : String, timestamp~ : Int64)
  /// A message an extension injected.
  Custom(
    custom_type~ : String,
    content~ : Json,
    display~ : Bool,
    details~ : Json?,
    timestamp~ : Int64
  )
} derive(Eq, Debug)

///|
pub fn ContextMessage::from_message(message : Message) -> ContextMessage {
  match message {
    User(m) => User(m)
    Assistant(m) => Assistant(m)
    ToolResult(m) => ToolResult(m)
  }
}

///|
/// What gets sent to the model, plus the settings in force at the leaf.
pub(all) struct SessionContext {
  messages : Array[ContextMessage]
  thinking_level : String
  model : ModelRef?
} derive(Eq, Debug)

// ── The session itself ─────────────────────────────────────────────────────

///|
/// A loaded session: the header, every entry, and where the leaf currently is.
///
/// `index` is a derived lookup kept alongside the entries rather than rebuilt on
/// each traversal — pi rebuilds it per call, which is fine for short sessions and
/// wasteful for long ones.
pub(all) struct Session {
  header : SessionHeader
  entries : Array[Entry]
  /// `None` means the session has no entries yet.
  leaf_id : String?
  index : Map[String, Entry]
} derive(Debug)

///|
pub fn Session::new(header : SessionHeader, entries : Array[Entry]) -> Session {
  let index : Map[String, Entry] = Map([])
  for entry in entries {
    index.set(entry.id, entry)
  }
  let leaf_id = match entries.length() {
    0 => None
    n => Some(entries[n - 1].id)
  }
  { header, entries, leaf_id, index, }
}

///|
/// Walk from the current leaf back to the root and return the path in
/// root-to-leaf order.
pub fn Session::path(self : Session) -> Array[Entry] {
  match self.leaf_id {
    None => []
    Some(leaf) => walk_path(self.index, leaf)
  }
}

///|
/// A copy of this session with entries appended, leaf moved to the last of them.
///
/// Appending in memory mirrors what was just written to the file. Anything else
/// would make the in-memory session and the log disagree, and the log is the one
/// that survives a restart.
pub fn Session::add_entries(self : Session, entries : Array[Entry]) -> Session {
  if entries.is_empty() {
    return self
  }
  let all : Array[Entry] = []
  for entry in self.entries {
    all.push(entry)
  }
  for entry in entries {
    all.push(entry)
  }
  Session::new(self.header, all)
}

///|
/// The path ending at a specific entry. `None` yields an empty path, which is
/// how "no leaf" is distinguished from "the current leaf".
pub fn Session::path_to(self : Session, leaf_id : String?) -> Array[Entry] {
  match leaf_id {
    None => []
    Some(id) => walk_path(self.index, id)
  }
}

///|
/// Walk from the current leaf back to the root.
///
/// A missing parent ends the walk: entries are appended with a parent that already exists, so
/// normally the only way to reach a gap is a truncated file. But "normally" is not "always" —
/// an entry can also point *forward*, at a parent that has not been written yet, and that is what
/// a log looks like when two writers interleave, when a file is merged or hand-edited, or when an
/// id collides. A forward link is a cycle, and following one does not terminate: before this was
/// guarded, a single such entry took the server to 100% CPU and gigabytes of memory, because every
/// element around the walk was rebuilt on each pass.
///
/// So the walk stops at the first entry it has already seen. That is not a repair — the log is
/// still wrong and the caller should treat the path as short rather than complete — but it is a
/// bounded answer instead of a hang, and a reader can still open the session.
fn walk_path(index : Map[String, Entry], leaf_id : String) -> Array[Entry] {
  let reversed : Array[Entry] = []
  let seen : Map[String, Unit] = Map([])
  let mut current = index.get(leaf_id)
  while true {
    match current {
      None => break
      Some(entry) =>
        if seen.get(entry.id) is Some(_) {
          break
        } else {
          seen.set(entry.id, ())
          reversed.push(entry)
          current = match entry.parent_id {
            Some(parent) => index.get(parent)
            None => None
          }
        }
    }
  }
  let path : Array[Entry] = []
  for i in 0..<reversed.length() {
    path.push(reversed[reversed.length() - 1 - i])
  }
  path
}

///|
/// The entries that actually form the conversation.
///
/// When the path contains compaction, only the newest one is honoured: it
/// replaces everything it summarized, keeps the entries from
/// `first_kept_entry_id` onward, and leaves anything appended after it alone.
/// Older compactions stay in the file but stop affecting the result.
pub fn Session::context_entries(self : Session) -> Array[Entry] {
  let path = self.path()
  let mut latest : Entry? = None
  for entry in path {
    if entry.kind is Compaction(..) {
      latest = Some(entry)
    }
  }
  let compaction = match latest {
    None => return path
    Some(c) => c
  }
  let compaction_id = compaction.id
  let first_kept = match compaction.kind {
    Compaction(first_kept_entry_id~, ..) => first_kept_entry_id
    _ => return path
  }
  let mut cut = -1
  for i in 0..<path.length() {
    if path[i].id == compaction_id {
      cut = i
      break
    }
  }
  if cut < 0 {
    return path
  }
  let out : Array[Entry] = [compaction]
  let mut keeping = false
  for i in 0..<cut {
    if path[i].id == first_kept {
      keeping = true
    }
    if keeping {
      out.push(path[i])
    }
  }
  for i in (cut + 1)..<path.length() {
    out.push(path[i])
  }
  out
}

///|
/// Project one entry into model-visible messages. Entries that are bookkeeping
/// rather than conversation produce nothing.
fn context_messages_of(entry : Entry) -> Array[ContextMessage] {
  let timestamp = match parse_iso_utc(entry.timestamp) {
    Some(ms) => ms
    None => 0L
  }
  match entry.kind {
    Message(message~) => [ContextMessage::from_message(message)]
    Compaction(summary~, tokens_before~, ..) =>
      [CompactionSummary(summary~, tokens_before~, timestamp~)]
    BranchSummary(summary~, from_id~, ..) =>
      [BranchSummary(summary~, from_id~, timestamp~)]
    CustomMessage(custom_type~, content~, details~, display~) =>
      [Custom(custom_type~, content~, display~, details~, timestamp~)]
    // Model and thinking-level changes are settings, not conversation.
    _ => []
  }
}

///|
fn context_settings(path : Array[Entry]) -> (String, ModelRef?) {
  let mut thinking_level = "off"
  let mut model : ModelRef? = None
  for entry in path {
    match entry.kind {
      ThinkingLevelChange(level~) => thinking_level = level
      ModelChange(provider~, model_id~) => model = Some({ provider, model_id, })
      Message(message~) =>
        match message {
          // An assistant message is also a record of which model produced it.
          Assistant(a) =>
            model = Some({ provider: a.provider, model_id: a.model, })
          _ => ()
        }
      _ => ()
    }
  }
  (thinking_level, model)
}

///|
pub fn Session::context(self : Session) -> SessionContext {
  let entries = self.context_entries()
  let (thinking_level, model) = context_settings(self.path())
  let messages : Array[ContextMessage] = []
  for entry in entries {
    for message in context_messages_of(entry) {
      messages.push(message)
    }
  }
  { messages, thinking_level, model, }
}

///|
/// The conversation a compaction would replace: everything before
/// `first_kept_entry_id` on the active path, in model-visible form.
///
/// Honours the newest compaction exactly as `context_entries` does, so a second
/// compaction summarizes the previous summary plus what came after it, rather
/// than the history that summary already replaced.
///
/// An empty result means there is nothing to summarize — either the cut is at the
/// very start of the conversation, or the id is not on this path. Both cases
/// should stop the compaction rather than produce a summary of nothing.
pub fn Session::messages_before(
  self : Session,
  first_kept_entry_id : String,
) -> Array[ContextMessage] {
  let out : Array[ContextMessage] = []
  let mut found = false
  for entry in self.context_entries() {
    if entry.id == first_kept_entry_id {
      found = true
      break
    }
    for message in context_messages_of(entry) {
      out.push(message)
    }
  }
  if found {
    out
  } else {
    []
  }
}

// ── What the model actually receives ──────────────────────────────────────

///|
/// The framing pi puts around a summary when replaying it to the model.
///
/// Copied verbatim rather than paraphrased. These strings are part of the wire
/// format the model has seen, and `harness/gen-deepseek-requests.mjs` captures
/// them from pi-ai, so the pair is checked against the oracle instead of trusted
/// to memory.
pub fn compaction_summary_prefix() -> String {
  "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
}

///|
pub fn compaction_summary_suffix() -> String {
  "\n</summary>"
}

///|
pub fn branch_summary_prefix() -> String {
  "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n"
}

///|
pub fn branch_summary_suffix() -> String {
  "</summary>"
}

///|
/// A summary as the model reads it: framed, and attributed to the user.
pub fn framed_summary(summary : String, branch~ : Bool) -> String {
  if branch {
    branch_summary_prefix() + summary + branch_summary_suffix()
  } else {
    compaction_summary_prefix() + summary + compaction_summary_suffix()
  }
}

///|
/// One context message as the model sees it.
///
/// summaries and custom messages are not user or assistant output, but the model
/// has to see them as turns. pi's mapping is the reference here: a summary
/// arrives as a user turn wrapped in `<summary>` framing, and a custom message as
/// a user turn carrying its own content.
pub fn ContextMessage::to_message(self : ContextMessage) -> Message {
  match self {
    User(m) => Message::User(m)
    Assistant(m) => Message::Assistant(m)
    ToolResult(m) => Message::ToolResult(m)
    CompactionSummary(summary~, timestamp~, ..) =>
      Message::User({
        content: [Text(framed_summary(summary, branch=false))],
        timestamp,
      })
    BranchSummary(summary~, timestamp~, ..) =>
      Message::User({
        content: [Text(framed_summary(summary, branch=true))],
        timestamp,
      })
    Custom(content~, timestamp~, ..) =>
      Message::User({ content: custom_blocks(content), timestamp, })
  }
}

///|
/// The blocks of an extension-injected message.
///
/// pi passes a string through as one text part and an array through unchanged.
/// Anything else has no part shape to preserve, so the JSON is shown as text
/// rather than dropped: a message the model cannot read is worse than one it
/// reads awkwardly.
fn custom_blocks(content : Json) -> Array[Content] {
  match content {
    String(value) => [Text(value)]
    Array(items) => {
      let blocks : Array[Content] = []
      let mut usable = true
      for item in items {
        // A part that will not decode makes the whole content unusable, so the
        // JSON is kept as text rather than half-rendered.
        try Content::from_json(item) catch {
          _ => usable = false
        } noraise {
          block => if usable { blocks.push(block) }
        }
      }
      if usable {
        blocks
      } else {
        [Text(content.stringify())]
      }
    }
    _ => [Text(content.stringify())]
  }
}

///|
/// The whole conversation in the shape the request builder expects.
pub fn SessionContext::messages_for_model(
  self : SessionContext,
) -> Array[Message] {
  context_messages_for_model(self.messages)
}

///|
/// The same conversion for a slice of conversation — the prefix a compaction is
/// about to replace, for instance.
pub fn context_messages_for_model(
  messages : Array[ContextMessage],
) -> Array[Message] {
  messages.map(message => ContextMessage::to_message(message))
}

// ── Serialization ──────────────────────────────────────────────────────────

///|
pub fn ContextMessage::to_json(self : ContextMessage) -> Json {
  match self {
    User(m) => m.to_json()
    Assistant(m) => m.to_json()
    ToolResult(m) => m.to_json()
    CompactionSummary(summary~, tokens_before~, timestamp~) =>
      Json::object(
        Map([
          ("role", Json::string("compactionSummary")),
          ("summary", Json::string(summary)),
          ("tokensBefore", Json::number(tokens_before.to_double())),
          ("timestamp", Json::number(timestamp.to_double())),
        ]),
      )
    BranchSummary(summary~, from_id~, timestamp~) =>
      Json::object(
        Map([
          ("role", Json::string("branchSummary")),
          ("summary", Json::string(summary)),
          ("fromId", Json::string(from_id)),
          ("timestamp", Json::number(timestamp.to_double())),
        ]),
      )
    Custom(custom_type~, content~, display~, details~, timestamp~) => {
      let fields : Array[(String, Json?)] = [
        ("role", Some(Json::string("custom"))),
        ("customType", Some(Json::string(custom_type))),
        ("content", Some(content)),
        ("display", Some(Json::boolean(display))),
        ("details", details),
        ("timestamp", Some(Json::number(timestamp.to_double()))),
      ]
      Json::object(obj_opt_pairs(fields))
    }
  }
}

///|
/// The name the reader gave this session, if they gave one.
///
/// The name is an entry in the log rather than a field somewhere else, which is what makes it
/// survive a restart and stay visible to pi: it writes `/name` the same way. The newest entry
/// wins, so renaming twice keeps one name rather than a history of them.
pub fn Session::name(self : Session) -> String? {
  let mut name : String? = None
  for entry in self.path() {
    match entry.kind {
      // An entry without a name is a clear, and it clears like any other rename: the last one wins.
      SessionInfo(name=entry_name) => name = entry_name
      _ => ()
    }
  }
  name
}
