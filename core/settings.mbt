///|
/// The parts of the configuration a reader can change from the UI.
///
/// Deliberately small, and chosen by one question: **can a running process honor it?** The model,
/// the base URL, the port and the store are decided at launch and cannot be changed from a page —
/// so a panel that appeared to change them would be lying about what it can do, and they are shown
/// as read-only facts instead. What is stored here is exactly what every turn reads fresh: a key,
/// the skills that should stay out of the catalog, the instructions a workspace with no `AGENTS.md`
/// of its own gets, and the limits that bound a turn.
///
/// The limits belong here for the same reason the skills do. They are read at the top of every
/// turn, so a change takes effect on the next one — which matters most in exactly the case the
/// guard exists for: a turn that just stopped at the limit is a turn whose limit the reader now
/// wants to raise, and making them restart to do it would be silly.
///
/// JSON, and a whole-file write, rather than the session log's append-only format. There is no
/// history to keep, because settings are a current state; the last write winning is the whole
/// semantics, and a format that recorded every edit would only give a reader something to
/// disagree with.
///
/// Everything in this file is pure: the path and the environment are the platform's business, and
/// keeping them out makes the decisions — which key wins, whether a skill is on, which limit is in
/// force — testable without a filesystem.

///|
/// A saved configuration.
pub(all) struct AppSettings {
  /// A key saved from the panel, or empty when the environment provides one.
  saved_api_key : String
  /// Skill names switched off. Names rather than paths, so a setting survives a skill being
  /// reinstalled elsewhere, and so a name that no longer exists is harmless rather than broken.
  disabled_skills : Array[String]
  /// The instructions a workspace gets when it has no `AGENTS.md` of its own, or empty for none.
  ///
  /// A fallback rather than an addition: a repository's own file is the more specific authority on
  /// how to work in it, and merging the two would leave every reader guessing which sentence won.
  /// Because this one is per-machine rather than per-repository it is the honest place for the
  /// things that are true of the person — how to run tests here, where the scratch space is —
  /// without committing them to somebody else's checkout.
  agents_md : String
  /// Most model calls one turn may make, or `None` when the reader has not said. `Some(0)`
  /// disables the bound, which is a different thing from not having an opinion.
  max_rounds : Int?
  /// Most one turn may cost, in US dollars, or `None` when the reader has not said.
  max_cost : Double?
  /// Longest one turn may take, in seconds, or `None` when the reader has not said.
  max_seconds : Int?
  /// Which tools a turn is given: the eight built-in ones, or code mode's two.
  ///
  /// Changeable mid-session, unlike the model or the endpoint, because it is honored on the next
  /// turn: the mode decides which tools are *declared*, and a declaration is only read when a
  /// request is built.
  tool_mode : ToolMode
} derive(Eq, Debug)

///|
pub fn AppSettings::new() -> AppSettings {
  {
    saved_api_key: "",
    disabled_skills: [],
    agents_md: "",
    max_rounds: None,
    max_cost: None,
    max_seconds: None,
    tool_mode: Tools,
  }
}

///|
/// A copy with a different tool mode.
pub fn AppSettings::with_tool_mode(
  self : AppSettings,
  mode : ToolMode,
) -> AppSettings {
  { ..self, tool_mode: mode, }
}

///|
/// Whether a discovered skill should reach the catalog.
pub fn AppSettings::skill_enabled(self : AppSettings, name : String) -> Bool {
  !self.disabled_skills.contains(name)
}

///|
/// A copy with one skill switched on or off.
///
/// Rebuilt rather than mutated in place: the array came from a decoded file or from an earlier
/// copy of this value, and mutating something the caller still holds is how one toggle turns out
/// to have changed two things.
pub fn AppSettings::with_skill_enabled(
  self : AppSettings,
  name : String,
  enabled : Bool,
) -> AppSettings {
  let out : Array[String] = []
  for existing in self.disabled_skills {
    if existing != name {
      out.push(existing)
    }
  }
  if !enabled {
    out.push(name)
  }
  // Sorted so two settings that mean the same thing are the same bytes on disk, which is what
  // makes the file diffable by eye.
  out.sort_by((a, b) => compare_names(a, b))
  {
    saved_api_key: self.saved_api_key,
    disabled_skills: out,
    agents_md: self.agents_md,
    max_rounds: self.max_rounds,
    max_cost: self.max_cost,
    max_seconds: self.max_seconds,
    tool_mode: self.tool_mode,
  }
}

///|
/// A copy with a whole set of names switched off.
///
/// What the skills form applies. Rebuilding from the posted set rather than toggling each name
/// means the outcome does not depend on what the list looked like when the page was rendered:
/// two readers with one tab each end up at the last set submitted, not at an intersection of
/// two sets of clicks.
pub fn AppSettings::with_disabled_skills(
  self : AppSettings,
  names : Array[String],
) -> AppSettings {
  let out : Array[String] = []
  for name in names {
    if name != "" && !out.contains(name) {
      out.push(name)
    }
  }
  out.sort_by((a, b) => compare_names(a, b))
  {
    saved_api_key: self.saved_api_key,
    disabled_skills: out,
    agents_md: self.agents_md,
    max_rounds: self.max_rounds,
    max_cost: self.max_cost,
    max_seconds: self.max_seconds,
    tool_mode: self.tool_mode,
  }
}

///|
/// A copy with a different saved key. Surrounding whitespace is dropped: a key pasted from a
/// chat window arrives with a newline often enough that storing it is a bug report waiting.
pub fn AppSettings::with_saved_api_key(
  self : AppSettings,
  key : String,
) -> AppSettings {
  {
    saved_api_key: key.trim().to_owned(),
    disabled_skills: self.disabled_skills,
    agents_md: self.agents_md,
    max_rounds: self.max_rounds,
    max_cost: self.max_cost,
    max_seconds: self.max_seconds,
    tool_mode: self.tool_mode,
  }
}

///|
/// A copy with different fallback instructions.
///
/// Trimmed on the way in and not otherwise touched: this is prose a reader wrote for the model, so
/// the only thing worth normalizing is the whitespace a textarea leaves around it. What is stored
/// is what the panel renders back and what the model will read, with nothing in between that could
/// disagree with it.
pub fn AppSettings::with_agents_md(
  self : AppSettings,
  text : String,
) -> AppSettings {
  {
    saved_api_key: self.saved_api_key,
    disabled_skills: self.disabled_skills,
    agents_md: text.trim().to_owned(),
    max_rounds: self.max_rounds,
    max_cost: self.max_cost,
    max_seconds: self.max_seconds,
    tool_mode: self.tool_mode,
  }
}

///|
/// A copy with the limits changed.
///
/// `None` clears a limit rather than setting it to zero: cleared means "no opinion, use the flag
/// or the built-in default", while `Some(0)` means "explicitly no bound". The two are different
/// intentions and the panel shows them differently.
pub fn AppSettings::with_limits(
  self : AppSettings,
  max_rounds : Int?,
  max_cost : Double?,
  max_seconds : Int?,
) -> AppSettings {
  {
    saved_api_key: self.saved_api_key,
    disabled_skills: self.disabled_skills,
    agents_md: self.agents_md,
    max_rounds,
    max_cost,
    max_seconds,
    tool_mode: self.tool_mode,
  }
}

///|
/// The skills that should reach the catalog: the discovered ones, minus the disabled, with
/// same-named duplicates collapsed exactly the way the full catalog collapses them.
///
/// Deduplication happens first so that disabling a name disables every skill of that name —
/// otherwise a global and a project skill with one name would take two switches to silence.
pub fn enabled_skills(
  skills : Array[Skill],
  disabled : Array[String],
) -> Array[Skill] {
  let kept : Array[Skill] = []
  for skill in dedup_skills(skills) {
    let mut off = false
    for name in disabled {
      if name == skill.name {
        off = true
      }
    }
    if !off {
      kept.push(skill)
    }
  }
  kept
}

///|
/// One line of the skill panel: what it is called, what it does, where it lives, and whether it
/// reaches the model.
///
/// The panel needs all four, and it needs *disabled* skills in the list as much as enabled ones —
/// a list that only showed what is on would have nothing to click to turn something off.
pub(all) struct SkillEntry {
  name : String
  /// One line from the skill's frontmatter. Empty for a name that has no file behind it.
  description : String
  /// Where the file is, or empty for a name that no longer matches anything discovered.
  path : String
  enabled : Bool
} derive(Eq, Debug)

///|
/// The whole skills list as the panel shows it, enabled or not.
///
/// In the catalog's own order, so the panel and the system prompt agree about what exists; names
/// that are switched off but no longer have a file behind them — a skill uninstalled while it was
/// disabled — are appended, because a setting a reader cannot see is a setting they cannot undo.
pub fn skill_entries(
  skills : Array[Skill],
  disabled : Array[String],
) -> Array[SkillEntry] {
  let out : Array[SkillEntry] = []
  let known : Array[String] = []
  for skill in dedup_skills(skills) {
    known.push(skill.name)
    out.push({
      name: skill.name,
      description: skill.description,
      path: skill.path,
      enabled: !disabled.contains(skill.name),
    })
  }
  let extras = disabled.copy()
  extras.sort_by((a, b) => compare_names(a, b))
  for name in extras {
    if !known.contains(name) {
      out.push({ name, description: "", path: "", enabled: false, })
    }
  }
  out
}

///|
/// Where the key the process is using came from. Shown in the panel, because "which of the two
/// keys on this machine is actually in use" is the question a key panel exists to answer.
pub(all) enum KeySource {
  /// `DEEPSEEK_API_KEY`.
  Environment
  /// `~/.wei/settings.json`, written by this panel.
  Saved
} derive(Eq, Debug)

///|
/// The key to use and where it came from.
pub(all) struct KeyChoice {
  key : String
  source : KeySource
} derive(Eq, Debug)

///|
/// Pick the key to use.
///
/// Two sources, and the order between them is deliberate: the environment wins. Putting the saved
/// key first would have been the obvious reading of "the UI's key", and it would have silently
/// overridden `DEEPSEEK_API_KEY` — a variable someone set on purpose, in a shell they are looking
/// at, in favor of a value they saved once in the panel.
///
/// There used to be a third source: the credential store of the agent this project was forked
/// from. It is gone deliberately. The app owns the key it sends, so that the panel can always say
/// where the key in use came from — a key it can read but not explain is a key it has no business
/// sending.
pub fn choose_api_key(env_key : String, saved_key : String) -> KeyChoice? {
  if env_key != "" {
    return Some({ key: env_key, source: Environment, })
  }
  if saved_key != "" {
    return Some({ key: saved_key, source: Saved, })
  }
  None
}

// ── limits ─────────────────────────────────────────────────────────────────

///|
/// The built-in bound on model calls in one turn.
///
/// From measurement rather than taste: over 2280 real turns the longest ran 165 calls, so 200 is a
/// turn that did not happen — the guard catches a model looping, not a long turn.
pub fn default_max_rounds() -> Int {
  200
}

///|
/// The built-in bound on what one turn may cost, in US dollars.
///
/// The same measurement: the median turn cost $0.004 and the most expensive $0.295, so a dollar is
/// a turn that did not happen. It is the limit that actually bounds the bill, because a turn can be
/// expensive without being long.
pub fn default_max_cost() -> Double {
  1.0
}

///|
/// The built-in bound on how long one turn may take, in seconds.
///
/// The third dimension, and the one the other two cannot see: a command can sit for an hour making
/// no model calls and costing nothing while the reader waits. From the same kind of measurement —
/// over 50,000 real assistant turns, half finished within 2s and 99% within 50s, but the longest
/// ran 34 minutes — half an hour is past everything measured and still bounds a stuck turn.
pub fn default_max_seconds() -> Int {
  1800
}

///|
/// Where a limit in force came from.
pub(all) enum LimitSource {
  /// A command-line flag for this run.
  Flag
  /// `~/.wei/settings.json`, written by the panel.
  Saved
  /// The built-in default.
  Default
} derive(Eq, Debug)

///|
/// One limit and where it came from.
pub(all) struct Limit {
  /// The value in force. `0` means the bound is off.
  value : Double
  source : LimitSource
} derive(Eq, Debug)

///|
/// The limits in force for a turn.
pub(all) struct Limits {
  max_rounds : Limit
  max_cost : Limit
  max_seconds : Limit
} derive(Eq, Debug)

///|
/// Where the instructions a turn will send came from.
pub(all) enum InstructionSource {
  /// The `AGENTS.md` in the session's own working directory.
  File
  /// `~/.wei/settings.json`, for a workspace that has no file of its own.
  Saved
  /// Neither: the prompt is the tool list and the catalog, as it was before this existed.
  ///
  /// Not spelled `None`, which would shadow `Option::None` for every match in this package.
  Absent
} derive(Eq, Debug)

///|
/// The instructions one turn will append to the system prompt, and where they came from.
///
/// One value rather than two functions, because the text and its source are one decision: the
/// panel shows the source of the text it is previewing, and a second function answering "which
/// won" could disagree with the first about what "won" means.
pub(all) struct Instructions {
  /// What a turn appends. Empty when there is nothing to add.
  text : String
  source : InstructionSource
} derive(Eq, Debug)

///|
/// Pick the limits a turn should run under.
///
/// A command-line flag wins over the saved setting, which wins over the built-in default. The order
/// is the opposite of the key's, and deliberately so. For a key, the environment is the thing a
/// reader is looking at in their shell, and a value saved once in a browser months ago should not
/// quietly overrule it. For a limit, the flag *is* the deliberate act: `--max-cost 0.10` is a hard
/// cap someone typed for this run, and letting a saved five dollars override it would turn a safety
/// bound into a suggestion.
///
/// What the two orders share is that the surprising case is surfaced rather than hidden: the panel
/// shows each limit's source, and a flag-set limit is shown rather than editable, because a field
/// that appears to accept a value the process will ignore is worse than no field.
pub fn choose_limits(
  flag_rounds : Int?,
  flag_cost : Double?,
  flag_seconds : Int?,
  settings : AppSettings,
) -> Limits {
  let rounds = match flag_rounds {
    Some(value) => { value: value.to_double(), source: Flag, }
    None =>
      match settings.max_rounds {
        Some(value) => { value: value.to_double(), source: Saved, }
        None => { value: default_max_rounds().to_double(), source: Default, }
      }
  }
  let cost = match flag_cost {
    Some(value) => { value, source: Flag, }
    None =>
      match settings.max_cost {
        Some(value) => { value, source: Saved, }
        None => { value: default_max_cost(), source: Default, }
      }
  }
  let seconds = match flag_seconds {
    Some(value) => { value: value.to_double(), source: Flag, }
    None =>
      match settings.max_seconds {
        Some(value) => { value: value.to_double(), source: Saved, }
        None => { value: default_max_seconds().to_double(), source: Default, }
      }
  }
  { max_rounds: rounds, max_cost: cost, max_seconds: seconds, }
}

///|
/// Pick the instructions a turn in this workspace should carry.
///
/// A file at the root of the workspace wins over the saved text, and the saved text only applies
/// where there is no file. The order is the opposite of the limits', and for the same kind of
/// reason: a flag is a person acting deliberately on this run, and so is writing an `AGENTS.md`
/// into the repository they are working in. The saved text is the fallback for everywhere else —
/// it is what makes "how I like to work" apply to a checkout nobody has committed instructions to.
///
/// Read at the root of the workspace rather than from the working directory upward. The ancestor
/// walk is where the design gets expensive: which directories count, what to do when two of them
/// disagree, and whether a file outside the repository applies at all. One file, at the top of the
/// workspace, is the whole rule — and a reader who wants per-directory instructions can put them
/// in the one file and say which directory they are about.
pub fn choose_instructions(
  settings : AppSettings,
  workspace_file : String,
) -> Instructions {
  // The file itself is sent as it is on disk, with only its margins used to decide whether it says
  // anything. Rewriting a repository's file on its way into a prompt would be the kind of quiet
  // edit that makes a reader distrust every later diff.
  if workspace_file.trim() != "" {
    return { text: workspace_file, source: File, }
  }
  // The saved text, on the other hand, is stored trimmed — by the panel when it saved, and by the
  // file decoder when a hand-written settings file did not parse one — so it is used as it is.
  if settings.agents_md != "" {
    return { text: settings.agents_md, source: Saved, }
  }
  { text: "", source: Absent, }
}

// ── the file ───────────────────────────────────────────────────────────────

///|
/// The settings file as text.
///
/// Every field is always written, so the file is a complete description of the state rather than a
/// patch over defaults someone has to remember. The names are sorted first, so two settings that
/// mean the same thing are the same bytes on disk — which is what lets a reader diff the file by
/// eye, and what makes the round trip in the tests an equality.
///
/// A cleared limit is written as `null` rather than omitted and not as `0`: the three states are
/// "no opinion", "explicitly off" and a number, and a file that spelled the first two the same way
/// would lose which one the reader meant.
pub fn encode_app_settings(settings : AppSettings) -> String {
  let ordered = settings.disabled_skills.copy()
  // `compare_names` rather than `sort`, which would order strings by length first and put
  // "beta" before "alpha".
  ordered.sort_by((a, b) => compare_names(a, b))
  let disabled : Array[Json] = []
  for name in ordered {
    disabled.push(Json::string(name))
  }
  let rounds : Json = match settings.max_rounds {
    Some(value) => Json::number(value.to_double())
    None => Json::null()
  }
  let cost : Json = match settings.max_cost {
    Some(value) => Json::number(value)
    None => Json::null()
  }
  let seconds : Json = match settings.max_seconds {
    Some(value) => Json::number(value.to_double())
    None => Json::null()
  }
  Json::object(
    Map([
      ("saved_api_key", Json::string(settings.saved_api_key)),
      ("disabled_skills", Json::array(disabled)),
      ("agents_md", Json::string(settings.agents_md)),
      ("max_rounds", rounds),
      ("max_cost", cost),
      ("max_seconds", seconds),
      ("tool_mode", Json::string(settings.tool_mode.to_string())),
    ]),
  ).stringify()
}

///|
/// Read a settings file back.
///
/// Anything unreadable, unparsable or of the wrong shape is the empty settings rather than an
/// error. A settings file is a convenience; a process that refused to start because of one would
/// be trading a small feature for the whole program, and the panel is where a reader finds out
/// what actually took effect.
pub fn decode_app_settings(text : String) -> AppSettings {
  let parsed = try @json.parse(text) catch {
    _ => return AppSettings::new()
  } noraise {
    json => json
  }
  let saved_api_key = match settings_field(parsed, "saved_api_key") {
    Some(String(key)) => key
    _ => ""
  }
  let disabled_skills : Array[String] = []
  match settings_field(parsed, "disabled_skills") {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(name) =>
            if name != "" && !disabled_skills.contains(name) {
              disabled_skills.push(name)
            }
          _ => ()
        }
      }
    _ => ()
  }
  disabled_skills.sort_by((a, b) => compare_names(a, b))
  // A limit that is not a non-negative number is read as "no opinion" rather than as a bound. The
  // file is hand-editable, and the alternative — accepting `-5` and passing it to a guard that
  // treats `> 0` as "on" — would turn a typo into a silently disabled bound.
  let max_rounds = match settings_field(parsed, "max_rounds") {
    Some(Number(value, ..)) if value >= 0.0 => Some(value.to_int())
    _ => None
  }
  let max_cost = match settings_field(parsed, "max_cost") {
    Some(Number(value, ..)) if value >= 0.0 && !value.is_nan() => Some(value)
    _ => None
  }
  let max_seconds = match settings_field(parsed, "max_seconds") {
    Some(Number(value, ..)) if value >= 0.0 => Some(value.to_int())
    _ => None
  }
  let agents_md = match settings_field(parsed, "agents_md") {
    // Trimmed here as well as in `with_agents_md`, so a hand-edited file behaves like one the
    // panel wrote. Not trimming would make the box and the preview disagree about the same text,
    // because the preview renders what a turn would send and the box renders what is stored.
    Some(String(text)) => text.trim().to_owned()
    _ => ""
  }
  // An unrecognised word reads as the default mode: a typo in a hand-edited file should cost the
  // reader a mode, not the file.
  let tool_mode = match settings_field(parsed, "tool_mode") {
    Some(String(name)) => parse_tool_mode(name)
    _ => Tools
  }
  {
    saved_api_key,
    disabled_skills,
    agents_md,
    max_rounds,
    max_cost,
    max_seconds,
    tool_mode,
  }
}

///|
/// One field of a JSON object, or `None` when the value is not an object or has no such field.
fn settings_field(json : Json, key : String) -> Json? {
  match json {
    Object(fields) => fields.get(key)
    _ => None
  }
}

// ── the panel's posts ──────────────────────────────────────────────────────

///|
/// A settings form, decoded from what the browser sent.
///
/// The two forms are told apart by a field each one always sends — `skills` for the catalog form,
/// `key` for the key form — rather than by which URL they were posted to. The transport is
/// deliberately not the thing that knows what a key or a skill is, and this makes the decoding a
/// pure function of a body, which is where the percent-decoding edge cases live rather than in the
/// socket.
///
/// The marker matters most in the one case that would otherwise be unrepresentable: a skills form
/// with every box unchecked is an empty body, and an empty body cannot be distinguished from a
/// request that was not from the panel at all. Without the marker, switching off the last skill
/// would be the one edit the panel could not make.
pub(all) enum SettingsPost {
  /// `key=…` — save this key, or `clear=1` — drop the saved one and fall back.
  SaveKey(key~ : String, clear~ : Bool)
  /// The complete set of skill names that should be on. A set rather than a toggle, so applying
  /// it has one outcome: what was posted is what is enabled afterwards.
  ApplySkills(enabled~ : Array[String])
  /// The turn limits. `None` clears the saved value, which is different from `Some(0)` — that
  /// is the reader saying "no bound at all".
  ApplyLimits(max_rounds~ : Int?, max_cost~ : Double?, max_seconds~ : Int?)
  /// The fallback instructions, whole. Wholesale rather than patched, like the skills: what the
  /// textarea contained is what the next workspace without an `AGENTS.md` will get, and an empty
  /// one is a reader saying they want no fallback.
  ApplyAgentsMd(text~ : String)
  /// Which tools a turn gets. Its own form rather than a field on another, because it is the one
  /// edit whose whole effect is on the next request.
  ApplyToolMode(mode~ : String)
} derive(Eq, Debug)

///|
/// Decode a form body from the settings panel, or `None` when it is neither form.
///
/// Form-encoded rather than JSON because the skills are a list of checkboxes, and a form is
/// exactly the encoding the browser already has for one.
pub fn parse_settings_post(body : String) -> SettingsPost? {
  let fields = parse_form_body(body)
  let mut key : String? = None
  let mut clear = false
  let mut is_skills = false
  let mut is_limits = false
  let mut is_agents = false
  let mut is_mode = false
  let mut tool_mode : String? = None
  let mut agents_md : String? = None
  let mut max_rounds : Int? = None
  let mut max_cost : Double? = None
  let mut max_seconds : Int? = None
  // Which limit fields the form carried at all, as distinct from carrying them empty. An empty
  // field means "no opinion"; a field that is not there means the form was not about limits.
  let mut saw_rounds = false
  let mut saw_cost = false
  let mut saw_seconds = false
  let skills : Array[String] = []
  for field in fields {
    let (name, value) = field
    if name == "key" {
      key = Some(value)
    } else if name == "clear" {
      clear = true
    } else if name == "skills" {
      // The marker the catalog form always sends, whether or not it has any boxes checked.
      is_skills = true
    } else if name == "limits" {
      // The same idea for the limits form: a form with both fields cleared is otherwise an empty
      // body, and clearing both is exactly what a reader does after raising them once.
      is_limits = true
    } else if name == "agents" {
      // And for the instructions form, where the empty body is the case that matters most: a
      // reader who wants no fallback instructions empties the textarea and presses Apply.
      is_agents = true
    } else if name == "tool_mode" {
      // Its own marker as well as its own value: the form is a pair of radio buttons, and the one
      // that is chosen is the only field it sends.
      is_mode = true
      tool_mode = Some(value)
    } else if name == "agents_md" {
      agents_md = Some(value)
    } else if name == "max_rounds" {
      saw_rounds = true
      max_rounds = parse_limit_int(value)
    } else if name == "max_cost" {
      saw_cost = true
      max_cost = parse_limit_cost(value)
    } else if name == "max_seconds" {
      saw_seconds = true
      max_seconds = parse_limit_int(value)
    } else if name == "skill" && value != "" && !skills.contains(value) {
      skills.push(value)
    }
  }
  // The markers first, since each one is what makes an otherwise-empty body mean something.
  if is_mode {
    return Some(
      ApplyToolMode(
        mode=match tool_mode {
          Some(value) => value
          None => ""
        },
      ),
    )
  }
  if is_limits {
    return Some(ApplyLimits(max_rounds~, max_cost~, max_seconds~))
  }
  if is_skills {
    return Some(ApplySkills(enabled=skills))
  }
  if is_agents {
    // A form that carries the marker but no field at all is the emptied textarea, which is the
    // one post whose meaning would otherwise have to be inferred from a missing field.
    let text = match agents_md {
      Some(value) => value
      None => ""
    }
    return Some(ApplyAgentsMd(text~))
  }
  // Then `clear` before `key`: the clearing form has a key field too, empty, and reading it as a
  // save would store the empty string and look like a no-op to the reader.
  if clear {
    return Some(SaveKey(key="", clear=true))
  }
  match key {
    Some(value) => Some(SaveKey(key=value, clear=false))
    None =>
      // A limit field with no marker is still a limits post: `curl -d 'max_cost=0.5'` is a
      // reasonable thing to type, and rejecting it would only teach the wrong thing.
      if saw_rounds || saw_cost || saw_seconds {
        Some(ApplyLimits(max_rounds~, max_cost~, max_seconds~))
      } else {
        None
      }
  }
}

///|
/// One integer limit field.
///
/// Empty is `None` — no opinion — and unparsable is also `None`, because the honest reading of
/// "abc" in a box meant for a number is that the reader has not committed to one. A negative
/// number is `None` for the same reason the file decoder drops it: the guard is `> 0`, so a
/// negative value would silently disable the bound the reader thought they were setting.
///
/// `0` is kept as `Some(0)`, which is the one value that means something other than a number: no
/// bound at all.
pub fn parse_limit_int(value : String) -> Int? {
  let text = value.trim()
  if text == "" {
    return None
  }
  let parsed = try @string.parse_int(text) catch {
    _ => return None
  } noraise {
    number => number
  }
  if parsed < 0 {
    None
  } else {
    Some(parsed)
  }
}

///|
/// One dollar limit field, with the same reading as the integer one.
pub fn parse_limit_cost(value : String) -> Double? {
  // A leading `$` is what a reader pastes from the status line, which writes costs that way.
  let text = value.trim()
  let text = if text.has_prefix("$") {
    text[1:].trim().to_owned()
  } else {
    text.to_owned()
  }
  if text == "" {
    return None
  }
  let parsed = try @string.parse_double(text) catch {
    _ => return None
  } noraise {
    number => number
  }
  if parsed < 0.0 || parsed.is_nan() || parsed.is_inf() {
    None
  } else {
    Some(parsed)
  }
}

///|
/// A form body as name/value pairs.
///
/// Chromium always sends the percent-encoded form, but a body that is already plain — hand-typed
/// into `curl`, or sent by a client that decided not to bother — is more useful decoded leniently
/// than rejected, so both are accepted.
fn parse_form_body(body : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for pair in body.split("&") {
    if pair == "" {
      continue
    }
    let (name, value) = match pair.find("=") {
      Some(index) => (pair[:index].to_owned(), pair[index + 1:].to_owned())
      None => (pair.to_owned(), "")
    }
    out.push((form_decode(name), form_decode(value)))
  }
  out
}

///|
/// Percent-decode one form field.
///
/// Walked over the UTF-8 bytes rather than over characters, so a `%E4%B8%AD` in a skill name
/// decodes to the character it names instead of to three unrelated ones. A `%` that does not
/// start a hex pair is left as itself, which is what a form field containing a literal percent
/// looks like.
fn form_decode(text : String) -> String {
  let raw = @utf8.encode(text)
  let out : Array[Byte] = []
  let mut i = 0
  while i < raw.length() {
    let byte = raw[i]
    if byte == b'+' {
      // A form encodes a space as `+`, which no URI does — so this is a form decoder, not a
      // general one.
      out.push(b' ')
      i += 1
    } else if byte == b'%' && i + 2 < raw.length() {
      match (hex_digit(raw[i + 1]), hex_digit(raw[i + 2])) {
        (Some(high), Some(low)) => {
          out.push((high * 16 + low).to_byte())
          i += 3
        }
        _ => {
          out.push(byte)
          i += 1
        }
      }
    } else {
      out.push(byte)
      i += 1
    }
  }
  @utf8.decode_lossy(Bytes::from_array(out))
}

///|
fn hex_digit(byte : Byte) -> Int? {
  let value = byte.to_int()
  if value >= 48 && value <= 57 {
    // '0'-'9'
    Some(value - 48)
  } else if value >= 97 && value <= 102 {
    // 'a'-'f'
    Some(value - 87)
  } else if value >= 65 && value <= 70 {
    // 'A'-'F'
    Some(value - 55)
  } else {
    None
  }
}
