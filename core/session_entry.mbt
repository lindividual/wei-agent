///|
/// Session entries: the append-only records that make up a session file.
///
/// The shape matches pi's JSONL format exactly, including its tree structure:
/// every entry names its parent, so a session is a path through a tree rather
/// than a flat list. That is what makes branching possible without rewriting
/// history.

///|
/// Every entry carries these, regardless of kind.
pub(all) struct Entry {
  /// Eight hex characters in pi's own files. Only needs to be unique per session.
  id : String
  /// `None` for the first entry; otherwise the entry this one follows from.
  parent_id : String?
  /// ISO 8601 UTC, formatted by `timestamp.mbt`.
  timestamp : String
  kind : EntryKind
} derive(Eq, Debug)

///|
/// The kind-specific payload.
///
/// Optional fields stay optional so a round trip does not invent values that the
/// source omitted — `fromHook` in particular is written as `true` or not at all,
/// and `false` and absent mean the same thing to pi.
pub(all) enum EntryKind {
  Message(message~ : Message)
  ModelChange(provider~ : String, model_id~ : String)
  ThinkingLevelChange(level~ : String)
  Compaction(
    summary~ : String,
    first_kept_entry_id~ : String,
    tokens_before~ : Int,
    details~ : Json?,
    usage~ : Usage?,
    from_hook~ : Bool?
  )
  BranchSummary(
    from_id~ : String,
    summary~ : String,
    details~ : Json?,
    usage~ : Usage?,
    from_hook~ : Bool?
  )
  Custom(custom_type~ : String, data~ : Json?)
  /// `content` stays raw JSON because it is either a plain string or an array of
  /// content blocks, and neither form needs interpreting here.
  CustomMessage(
    custom_type~ : String,
    content~ : Json,
    details~ : Json?,
    display~ : Bool
  )
  Label(target_id~ : String, label~ : String?)
  SessionInfo(name~ : String?)
  /// A kind this build does not know. The original object is kept verbatim so a
  /// session written by a newer pi still round trips without losing data.
  Unknown(type_name~ : String, raw~ : Json)
} derive(Eq, Debug)

///|
fn kind_name(kind : EntryKind) -> String {
  match kind {
    Message(..) => "message"
    ModelChange(..) => "model_change"
    ThinkingLevelChange(..) => "thinking_level_change"
    Compaction(..) => "compaction"
    BranchSummary(..) => "branch_summary"
    Custom(..) => "custom"
    CustomMessage(..) => "custom_message"
    Label(..) => "label"
    SessionInfo(..) => "session_info"
    Unknown(type_name~, ..) => type_name
  }
}

///|
fn opt_bool(j : Json, key : String) -> Bool? raise DecodeError {
  match opt(j, key) {
    None => None
    Some(v) => Some(as_bool(v, key))
  }
}

///|
fn opt_int(j : Json, key : String) -> Int? raise DecodeError {
  match opt(j, key) {
    None => None
    Some(v) => Some(as_int(v, key))
  }
}

///|
fn opt_usage(j : Json, key : String) -> Usage? raise DecodeError {
  match opt(j, key) {
    None => None
    Some(v) => Some(Usage::from_json(v))
  }
}

///|
pub fn Entry::to_json(self : Entry) -> Json {
  let fields : Array[(String, Json?)] = [
    ("type", Some(Json::string(kind_name(self.kind)))),
    ("id", Some(Json::string(self.id))),
    (
      "parentId",
      Some(
        match self.parent_id {
          Some(p) => Json::string(p)
          None => Json::null()
        },
      ),
    ),
    ("timestamp", Some(Json::string(self.timestamp))),
  ]
  match self.kind {
    Message(message~) => fields.push(("message", Some(message.to_json())))
    ModelChange(provider~, model_id~) => {
      fields.push(("provider", Some(Json::string(provider))))
      fields.push(("modelId", Some(Json::string(model_id))))
    }
    ThinkingLevelChange(level~) =>
      fields.push(("thinkingLevel", Some(Json::string(level))))
    Compaction(
      summary~,
      first_kept_entry_id~,
      tokens_before~,
      details~,
      usage~,
      from_hook~
    ) => {
      fields.push(("summary", Some(Json::string(summary))))
      fields.push(("firstKeptEntryId", Some(Json::string(first_kept_entry_id))))
      fields.push(
        ("tokensBefore", Some(Json::number(tokens_before.to_double()))),
      )
      fields.push(("details", details))
      fields.push(("usage", usage.map(u => u.to_json())))
      fields.push(("fromHook", from_hook.map(h => Json::boolean(h))))
    }
    BranchSummary(from_id~, summary~, details~, usage~, from_hook~) => {
      fields.push(("fromId", Some(Json::string(from_id))))
      fields.push(("summary", Some(Json::string(summary))))
      fields.push(("details", details))
      fields.push(("usage", usage.map(u => u.to_json())))
      fields.push(("fromHook", from_hook.map(h => Json::boolean(h))))
    }
    Custom(custom_type~, data~) => {
      fields.push(("customType", Some(Json::string(custom_type))))
      fields.push(("data", data))
    }
    CustomMessage(custom_type~, content~, details~, display~) => {
      fields.push(("customType", Some(Json::string(custom_type))))
      fields.push(("content", Some(content)))
      fields.push(("details", details))
      fields.push(("display", Some(Json::boolean(display))))
    }
    Label(target_id~, label~) => {
      fields.push(("targetId", Some(Json::string(target_id))))
      fields.push(("label", label.map(l => Json::string(l))))
    }
    SessionInfo(name~) => fields.push(("name", name.map(n => Json::string(n))))
    // Already a complete object, base fields included.
    Unknown(raw~, ..) => return raw
  }
  Json::object(obj_opt_pairs(fields))
}

///|
/// Collect the present fields of an optional array into a map.
fn obj_opt_pairs(fields : Array[(String, Json?)]) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for entry in fields {
    let (key, value) = entry
    match value {
      Some(v) => out.set(key, v)
      None => ()
    }
  }
  out
}

///|
pub fn Entry::from_json(j : Json) -> Entry raise DecodeError {
  let type_name = as_string(req(j, "type"), "entry.type")
  let id = as_string(req(j, "id"), "entry.id")
  let parent_id = match opt(j, "parentId") {
    Some(String(p)) => Some(p)
    _ => None
  }
  let timestamp = as_string(req(j, "timestamp"), "entry.timestamp")
  // Unknown kinds keep the whole object: reconstructing it field by field would
  // drop whatever this build does not model.
  if !is_known_kind(type_name) {
    return { id, parent_id, timestamp, kind: Unknown(type_name~, raw=j), }
  }
  let kind : EntryKind = match type_name {
    "message" => Message(message=Message::from_json(req(j, "message")))
    "model_change" =>
      ModelChange(
        provider=as_string(req(j, "provider"), "entry.provider"),
        model_id=as_string(req(j, "modelId"), "entry.modelId"),
      )
    "thinking_level_change" =>
      ThinkingLevelChange(
        level=as_string(req(j, "thinkingLevel"), "entry.thinkingLevel"),
      )
    "compaction" =>
      Compaction(
        summary=as_string(req(j, "summary"), "entry.summary"),
        first_kept_entry_id=as_string(
          req(j, "firstKeptEntryId"),
          "entry.firstKeptEntryId",
        ),
        tokens_before=as_int(req(j, "tokensBefore"), "entry.tokensBefore"),
        details=opt(j, "details"),
        usage=opt_usage(j, "usage"),
        from_hook=opt_bool(j, "fromHook"),
      )
    "branch_summary" =>
      BranchSummary(
        from_id=as_string(req(j, "fromId"), "entry.fromId"),
        summary=as_string(req(j, "summary"), "entry.summary"),
        details=opt(j, "details"),
        usage=opt_usage(j, "usage"),
        from_hook=opt_bool(j, "fromHook"),
      )
    "custom" =>
      Custom(
        custom_type=as_string(req(j, "customType"), "entry.customType"),
        data=opt(j, "data"),
      )
    "custom_message" =>
      CustomMessage(
        custom_type=as_string(req(j, "customType"), "entry.customType"),
        content=req(j, "content"),
        details=opt(j, "details"),
        display=as_bool(req(j, "display"), "entry.display"),
      )
    "label" =>
      Label(
        target_id=as_string(req(j, "targetId"), "entry.targetId"),
        label=match opt(j, "label") {
          Some(String(l)) => Some(l)
          _ => None
        },
      )
    "session_info" =>
      SessionInfo(
        name=match opt(j, "name") {
          Some(String(n)) => Some(n)
          _ => None
        },
      )
    _ => Unknown(type_name~, raw=j)
  }
  { id, parent_id, timestamp, kind, }
}

///|
fn is_known_kind(type_name : String) -> Bool {
  match type_name {
    "message"
    | "model_change"
    | "thinking_level_change"
    | "compaction"
    | "branch_summary"
    | "custom"
    | "custom_message"
    | "label"
    | "session_info" => true
    _ => false
  }
}

///|
/// The first line of a session file.
pub(all) struct SessionHeader {
  id : String
  timestamp : String
  cwd : String
  /// Set when this session was forked from another.
  parent_session : String?
  /// `None` for v1 sessions, which predate the field.
  version : Int?
} derive(Eq, Debug)

///|
pub fn SessionHeader::to_json(self : SessionHeader) -> Json {
  let fields : Array[(String, Json?)] = [
    ("type", Some(Json::string("session"))),
    ("version", self.version.map(v => Json::number(v.to_double()))),
    ("id", Some(Json::string(self.id))),
    ("timestamp", Some(Json::string(self.timestamp))),
    ("cwd", Some(Json::string(self.cwd))),
    ("parentSession", self.parent_session.map(p => Json::string(p))),
  ]
  Json::object(obj_opt_pairs(fields))
}

///|
pub fn SessionHeader::from_json(j : Json) -> SessionHeader raise DecodeError {
  {
    id: as_string(req(j, "id"), "header.id"),
    timestamp: as_string(req(j, "timestamp"), "header.timestamp"),
    cwd: as_string(req(j, "cwd"), "header.cwd"),
    parent_session: match opt(j, "parentSession") {
      Some(String(p)) => Some(p)
      _ => None
    },
    version: opt_int(j, "version"),
  }
}
