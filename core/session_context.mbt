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
/// The path ending at a specific entry. `None` yields an empty path, which is
/// how "no leaf" is distinguished from "the current leaf".
pub fn Session::path_to(self : Session, leaf_id : String?) -> Array[Entry] {
  match leaf_id {
    None => []
    Some(id) => walk_path(self.index, id)
  }
}

///|
fn walk_path(index : Map[String, Entry], leaf_id : String) -> Array[Entry] {
  let reversed : Array[Entry] = []
  let mut current = index.get(leaf_id)
  // A parent missing from the index ends the walk. Entries are appended with a
  // parent that already exists, so a dangling link means a truncated file rather
  // than a cycle.
  while true {
    match current {
      None => break
      Some(entry) => {
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
