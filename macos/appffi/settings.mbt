///|
/// What a reader can change from the native settings panel: the API key, and which tools a turn
/// gets.
///
/// The same question the web panel asks decides what is here — **can a running process honour it?**
/// The store, the endpoint and the session are decided at launch, so a control for them would be
/// lying about what it can do; they are shown as facts instead, or not at all. A key and a tool mode
/// are read at the top of every turn (`Shell::api_key`, `Shell::run_turn`), so saving either one
/// means the next turn uses it rather than the next process.
///
/// Deliberately not the whole of `AppSettings`: skills, the fallback instructions and the turn
/// limits are all in the file and all changeable from the web UI, and each needs its own control to
/// be worth a place here. The panel grows one honest control at a time.

///|
/// What this process calls each place a key can come from.
///
/// The same four words the web panel uses, because they name the same fact; a third vocabulary for
/// "where is the key coming from" would be a third thing to keep in step.
fn key_source_name(choice : @core.KeyChoice?) -> String {
  match choice {
    Some(chosen) =>
      match chosen.source {
        @core.Environment => "environment"
        @core.Saved => "saved"
      }
    None => "none"
  }
}

///|
/// `DEEPSEEK_API_KEY` as this process sees it, or the empty string.
///
/// One reader, because two things compare it: `resolve_key` decides against it, and the settings
/// event reports whether it is set. Two reads would be two answers the day one of them changes.
///
/// A GUI app launched from Finder does not inherit a login shell's environment, so on the machine
/// this app is *installed* on this is empty and the saved key is the one that matters — which is the
/// whole reason the panel exists.
fn env_key() -> String {
  match @env.get_env_var("DEEPSEEK_API_KEY") {
    Some(value) => value
    None => ""
  }
}

///|
/// The settings as they stand, for the panel to draw.
///
/// The key itself never crosses: the panel is told where the key in use comes from and whether one
/// has been saved, which is everything it needs to say what the next turn will do. Sending the value
/// would put a secret in a place that only ever draws it dimmed — and the host has no use for it.
///
/// Everything a running process can honour is here, which is the same judgement the web panel makes:
/// the store and the endpoint were decided at launch, so a control for them would be a control that
/// lies. Skills, instructions and turn limits are all read at the top of a turn, so all three are
/// changeable from here.
async fn Shell::say_settings(self : Shell) -> Unit {
  let limits = @core.choose_limits(None, None, None, self.settings)
  // The directory of the session on screen: the panel shows the instructions that session would be
  // sent, and a session opened in another repository has its own AGENTS.md.
  let cwd = self.shown().cwd
  let instructions = @core.choose_instructions(
    self.settings,
    @platform.workspace_agents_md(cwd),
  )
  let skills : Array[Json] = []
  for
    entry in @core.skill_entries(
      // Through the cache, so the panel and `/skill:` cannot disagree about what exists.
      self.skills_here(cwd),
      self.settings.disabled_skills,
    ) {
    skills.push(
      Json::object(
        Map([
          ("name", Json::string(entry.name)),
          ("description", Json::string(entry.description)),
          ("path", Json::string(entry.path)),
          ("enabled", Json::boolean(entry.enabled)),
        ]),
      ),
    )
  }
  let servers : Array[Json] = []
  for entry in self.server_entries(cwd) {
    servers.push(
      Json::object(
        Map([
          ("name", Json::string(entry.name)),
          ("transport", Json::string(entry.transport)),
          ("description", Json::string(entry.description)),
          ("tool_count", Json::number(entry.tool_count.to_double())),
          ("enabled", Json::boolean(entry.enabled)),
          ("note", Json::string(entry.note)),
        ]),
      ),
    )
  }
  self.emit(
    settings_event(
      key_source_name(resolve_key(self.settings)),
      env_key() != "",
      self.settings.saved_api_key != "",
      self.settings.tool_mode,
      @platform.settings_path(self.home),
      skills,
      servers,
      instructions,
      limits,
    ),
  )
}

///|
/// Switch one MCP server on or off for the next turn.
///
/// The status sentence carries the *state after*, read back from the settings value rather than
/// assumed, because `with_server_enabled` is where "was this name already off" is decided — the same
/// arrangement `toggle_skill` uses, and for the same reason: two places deciding one thing is how a
/// message comes to describe a state that never happened.
async fn Shell::toggle_server(self : Shell, name : String) -> Unit {
  let trimmed = name.trim().to_owned()
  if trimmed == "" {
    return
  }
  let updated = @core.AppSettings::with_server_enabled(
    self.settings,
    trimmed,
    !self.settings.server_enabled(trimmed),
  )
  @platform.save_settings(self.home, updated)
  self.settings = updated
  self.say_status(
    self.current,
    if updated.server_enabled(trimmed) {
      "mcp \{trimmed}: on — the next turn can reach it"
    } else {
      "mcp \{trimmed}: off — the next turn cannot"
    },
  )
  self.say_settings()
}

///|
/// The settings event, from the facts rather than from the shell.
///
/// Split out for the reason the other emitters are: the field names are the contract with the host,
/// and this one is the widest contract in the program — nine fields, none of which a test could
/// assert while they were built inline inside an `async fn Shell::` the test cannot construct. The
/// key's *source* crosses and its value never does, which is the rule this function is the last
/// place to enforce.
fn settings_event(
  key_source : String,
  env : Bool,
  saved : Bool,
  mode : @core.ToolMode,
  path : String,
  skills : Array[Json],
  servers : Array[Json],
  instructions : @core.Instructions,
  limits : @core.Limits,
) -> Json {
  event("settings", [
    ("key", Json::string(key_source)),
    // Both flags, because with both set the panel has something to explain: a key the reader
    // saved is being overruled by the environment, and "I saved it and it still uses the old one"
    // reads as a bug otherwise.
    ("env", Json::boolean(env)),
    ("saved", Json::boolean(saved)),
    ("mode", Json::string(mode.to_string())),
    // Shown so that a reader who would rather edit the file knows which one to edit — the honest
    // fallback for everything the panel does not offer yet.
    ("path", Json::string(path)),
    ("skills", Json::array(skills)),
    // The MCP servers this workspace has, switched on or off, with a reason when one is not up.
    // Read from the same map the turn's tool set is built from, so the panel and the request cannot
    // disagree about which servers a turn can reach.
    ("servers", Json::array(servers)),
    ("instructions", Json::string(instructions.text)),
    (
      "instructions_source",
      Json::string(instruction_source_name(instructions.source)),
    ),
    ("limits", limits_json(limits)),
  ])
}

///|
/// Which of the three places a turn's instructions are coming from.
///
/// The panel shows the text *and* where it came from, because the two disagreeing is the confusing
/// case: a reader who saved instructions and sees a repository's file in the box has to be told why,
/// or they will save again and watch nothing change.
fn instruction_source_name(source : @core.InstructionSource) -> String {
  match source {
    @core.File => "file"
    @core.Saved => "saved"
    @core.Absent => "none"
  }
}

///|
/// The three limits in force, each with where it came from.
///
/// A source per limit rather than one for the group: a flag can set one of the three, so "this panel
/// is showing defaults" is not a fact about all of them. A limit whose source is `flag` is shown
/// rather than edited, because a field that appears to accept a value the process will ignore is
/// worse than no field — the same rule the web panel applies.
fn limits_json(limits : @core.Limits) -> Json {
  Json::object(
    Map([
      ("rounds", limit_json(limits.max_rounds)),
      ("cost", limit_json(limits.max_cost)),
      ("seconds", limit_json(limits.max_seconds)),
    ]),
  )
}

///|
fn limit_json(limit : @core.Limit) -> Json {
  let source = match limit.source {
    @core.Flag => "flag"
    @core.Saved => "saved"
    @core.Default => "default"
  }
  // The value travels as a string, in the same spelling the panel's field shows: `0.05` for a cost
  // and `200` for a count. A number would make the host decide how many decimals a limit has, and
  // the file's own spelling is the one a reader would type back.
  Json::object(
    Map([
      ("value", Json::string(limit_spelling(limit.value))),
      ("source", Json::string(source)),
    ]),
  )
}

///|
/// A limit as the file spells it: a whole number without a decimal point, a cost with as many as it
/// needs. `200.0` in a field that takes a count reads as a mistake.
fn limit_spelling(value : Double) -> String {
  if value == value.round() && value.abs() < 1.0e15 {
    "\{value.round().to_int()}"
  } else {
    "\{value}"
  }
}

///|
/// Save a key, and let it take effect on the next turn.
///
/// Written before it is adopted: a key held in memory and not on disk would be a setting that
/// disappears when the window closes, which is the one thing a saved key is for. The same order the
/// web panel uses.
///
/// An empty value clears the saved key, which is what "Clear saved key" means and what the panel
/// only ever sends deliberately. It does not remove a key that came from the environment: this
/// process cannot change another process's environment, and pretending otherwise would make the
/// panel describe a state it cannot reach.
async fn Shell::save_key(self : Shell, key : String) -> Unit {
  let updated = @core.AppSettings::with_saved_api_key(self.settings, key)
  @platform.save_settings(self.home, updated)
  self.settings = updated
  self.say_status(
    self.current,
    if updated.saved_api_key == "" {
      "saved key cleared"
    } else {
      "key saved — the next turn uses it"
    },
  )
  // `ready` again, because one of the four facts it carries has just changed: this is what turns the
  // window from "no API key" back into a shell that can send. It is the same event, re-sent, rather
  // than a second event the host would have to learn to combine with it.
  self.say_ready(self.shown(), key_source_name(resolve_key(self.settings)))
  self.say_settings()
}

///|
/// Switch which tools a turn gets.
///
/// Honoured on the next turn, not the one running: the mode decides which tools are *declared*, and
/// a declaration is only read when a request is built. An unknown word is the default mode, which is
/// the same rule `decode_app_settings` applies to a hand-edited file — a typo should cost a mode,
/// not the setting.
async fn Shell::set_mode(self : Shell, name : String) -> Unit {
  let updated = @core.AppSettings::with_tool_mode(
    self.settings,
    @core.parse_tool_mode(name),
  )
  @platform.save_settings(self.home, updated)
  self.settings = updated
  self.say_status(
    self.current,
    "tools: \{updated.tool_mode.to_string()} — the next turn uses them",
  )
  self.say_settings()
}

///|
/// Put a session on another model, keeping its thinking level one the new model can run at.
///
/// **The whole reason this is a function rather than an assignment.** The level is per model
/// (`ModelSpec::thinking_levels`) and it belongs to the session rather than to the model — a log
/// records it, a fork copies it, and a new session inherits the reader's last choice — so the two can
/// disagree, and the disagreement has a wrong answer that is easy to write: keep the level and send
/// `reasoning_effort: low` to a model that does not have it. Settling it here means the level a
/// session is on is always one its model has, which is what makes "keep to the levels this model
/// offers" a rule `say_think` can rely on.
///
/// Nothing is written to the log: the session's model and level are recorded by the driver at the top
/// of the next turn (`agent/driver.mbt`), which is the one place that knows a turn is being run at
/// all. A reader who changes their mind twice before asking anything leaves no trace of either
/// decision, which is what they should.
fn retarget(open : Open, model_id : String) -> Unit {
  open.model_id = model_id
  let levels = @core.model_spec_for(model_id).0.thinking_levels
  open.think_level = levels.in_force(Some(open.think_level))
}

///|
/// Ask for more or less thinking on the next turn.
///
/// Clamped to this session's model rather than saved and disbelieved later: a level the model does
/// not have is answered with the level that will really be used
/// (`ThinkingLevels::in_force`), and the menu is re-said so the tick cannot be left somewhere else.
/// The tool mode's neighbour above is the same shape of decision — a setting read when the next
/// request is built, so changing it mid-turn is a decision about the turn after this one, which is
/// exactly when a reader wants it.
///
/// Not gated on being idle, for that reason, and not persisted anywhere either: it is the session's,
/// and the driver writes it into the session's own log at the top of the next turn.
fn Shell::set_think_level(self : Shell, open : Open, level : String) -> Unit {
  let wanted = level.trim().to_owned()
  let levels = @core.model_spec_for(open.model_id).0.thinking_levels
  let resolved = levels.in_force(Some(wanted))
  // A word the model has not got is said out loud rather than silently obeyed as a fallback: the
  // reader asked for something that will not happen, and the sentence is the only place that says so.
  if wanted != resolved {
    self.say_status(
      open.path,
      "\{@core.model_spec_for(open.model_id).0.label()} has no \{wanted} level — thinking stays \{resolved}",
    )
  } else {
    // The tools sentence's shape, word for word, because it is the same kind of fact: a choice read
    // when the next request is built, said in the word the reader just used.
    self.say_status(
      open.path,
      "thinking: \{resolved} — the next turn uses it",
    )
  }
  open.think_level = resolved
  self.say_think(open)
}

///|
/// Turn one skill on or off.
///
/// Read when the next request is built, like the tool mode, so it takes effect on the next turn
/// rather than this one — which is also the only thing it could mean, since the system prompt of a
/// turn in flight has already been sent.
///
/// A name that matches nothing discovered is still saved. That is not a typo being honoured: a skill
/// disabled on one machine and installed on another has to arrive switched off, and the file is the
/// only thing that carries the decision. It costs one line in the file and nothing in a request.
async fn Shell::toggle_skill(self : Shell, name : String) -> Unit {
  // A `StringView` until it is owned: the settings file holds strings, and a view into the command
  // buffer would outlive the buffer.
  let trimmed = name.trim().to_owned()
  if trimmed == "" {
    return
  }
  let updated = @core.AppSettings::with_skill_enabled(
    self.settings,
    trimmed,
    !self.settings.skill_enabled(trimmed),
  )
  @platform.save_settings(self.home, updated)
  self.settings = updated
  self.say_status(
    self.current,
    if updated.skill_enabled(trimmed) {
      "skill \{trimmed}: on — the next turn uses it"
    } else {
      "skill \{trimmed}: off"
    },
  )
  self.say_settings()
}

///|
/// Save the fallback instructions: what a turn appends in a workspace that has no `AGENTS.md`.
///
/// An empty value clears them, which is a thing the panel asks for deliberately rather than a thing
/// a field can do by accident — the same rule the key's Clear button follows.
///
/// Not trimmed here. `with_agents_md` is where the store's own rule lives (the text is stored
/// trimmed), and a second opinion about whitespace in this file would be a second rule.
async fn Shell::set_instructions(self : Shell, text : String) -> Unit {
  let updated = @core.AppSettings::with_agents_md(self.settings, text)
  @platform.save_settings(self.home, updated)
  self.settings = updated
  self.say_status(
    self.current,
    if updated.agents_md == "" {
      "instructions cleared"
    } else {
      "instructions saved — used where there is no AGENTS.md"
    },
  )
  self.say_settings()
}

///|
/// Save the turn limits. An empty field means "no opinion", which is not the same as zero: zero
/// switches a bound off, and a reader who deletes a number wants the built-in default back.
///
/// All three at once rather than one at a time, because they are one form: a panel with three fields
/// and one Apply button has no way to say which field it meant, and a partial write would leave the
/// file describing a state nobody chose.
async fn Shell::set_limits(
  self : Shell,
  rounds : String,
  cost : String,
  seconds : String,
) -> Unit {
  let updated = @core.AppSettings::with_limits(
    self.settings,
    @core.parse_limit_int(rounds),
    @core.parse_limit_cost(cost),
    @core.parse_limit_int(seconds),
  )
  @platform.save_settings(self.home, updated)
  self.settings = updated
  self.say_status(self.current, "limits saved — the next turn uses them")
  self.say_settings()
}
