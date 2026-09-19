///|
/// The settings panel: what it shows, and what a post from it changes.
///
/// Three things are changeable, and the test is whether a running process can honour the change: a
/// saved key, the set of enabled skills, and the turn limits. Everything else in the panel is
/// shown read-only with the flag that would change it, because a field that appears to accept a value
/// the process will ignore is worse than no field. The model is changeable too, but it belongs to a
/// session rather than to the process, so it lives in `model.mbt`.
///
/// `apply_settings_post` is the one writer: it resolves the posted form to the settings that will
/// now be in force, writes the file before adopting the value, and returns the line the status bar
/// should carry. It lives here rather than beside the route that calls it so that the whole
/// decision — what was asked, what it means, what is now true — reads in one place.

///|
/// Re-derive the limits from the flags and the saved settings.
///
/// One place, called at startup and after every settings change, so the number a turn uses and the
/// number the panel shows cannot drift apart.
fn App::refresh_limits(self : App) -> Unit {
  self.limits = @core.choose_limits(
    self.flag_max_rounds,
    self.flag_max_cost,
    self.flag_max_seconds,
    self.settings,
  )
}

///|
/// One limit as the panel shows it.
///
/// A limit that came from a launch flag is rendered but not editable. Letting a reader type a value
/// into a field the process will ignore is worse than not offering the field: they would change
/// it, see it in the box, and be wrong about what bounds the next turn.
fn limit_view(
  limit : @core.Limit,
  flag : String,
  integer? : Bool = false,
) -> @html.LimitView {
  let source = match limit.source {
    @core.Flag => "set by \{flag}"
    @core.Saved => "saved"
    @core.Default => "default"
  }
  // The default is shown as a placeholder rather than as a value: an empty field means "no
  // opinion", and a field pre-filled with 200 would make saving it indistinguishable from never
  // having touched it — and would freeze the default forever the first time someone pressed Apply.
  let text = match limit.source {
    @core.Default => ""
    _ =>
      if integer {
        limit.value.to_int().to_string()
      } else {
        @html.format_limit_cost(limit.value)
      }
  }
  { text, source, editable: limit.source != @core.Flag, }
}

///|
/// The key this process should use, and where it came from.
///
/// The decision is `@core.choose_api_key`, so the precedence is pinned by a test instead of by
/// the order of two `if`s.
fn App::resolve_key(self : App) -> @core.KeyChoice? {
  @core.choose_api_key(self.env_key, self.settings.saved_api_key)
}

///|
/// What the panel calls each provider a key can come from.
///
/// A string rather than the enum, because it crosses into `html` and back out again as a form
/// field: the enum would have to be re-derived on the way in, and the mapping is the only thing
/// either side actually needs.
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
/// A name a status line can read, for where the key in use came from.
///
/// Separate from `key_source_name`, which is the panel's machine-readable value: "environment" is
/// the right word for a field the panel branches on and the wrong word for a sentence, where
/// naming the variable is what tells the reader which knob to turn.
fn key_source_label(source : String) -> String {
  match source {
    "environment" => "DEEPSEEK_API_KEY"
    "saved" => "the saved key"
    _ => "no key"
  }
}

///|
/// Adopt a key: it becomes what the next turn sends, and the panel's description of where it came
/// from. One place, so the three fields cannot describe different keys.
fn App::set_key(self : App, choice : @core.KeyChoice?) -> Unit {
  match choice {
    Some(chosen) => {
      self.api_key = chosen.key
      self.key_hint = @html.mask_key(chosen.key)
    }
    None => {
      // No key is a state, not an error: the panel is how a machine that has one saved gets one,
      // and the first turn without one fails with the model's own error rather than hiding the
      // page.
      self.api_key = ""
      self.key_hint = ""
    }
  }
  self.key_source = key_source_name(choice)
}

///|
/// The set of switched-off names a posted set of enabled ones means.
///
/// Computed from the list the panel was showing — every discovered skill, plus the names that are
/// already off and have no file — rather than from the previous disabled list alone. That is what
/// makes the set the form submits the same as the set the form displayed: a checkbox the reader
/// left unchecked means "off", including for a name that has no file this minute. A skill
/// installed in another tab, which this page never showed, is simply absent and so is absent from
/// the result — a set cannot switch off something it never named.
fn disabled_after_apply(
  discovered : Array[@core.Skill],
  previous : Array[String],
  enabled : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  for entry in @core.skill_entries(discovered, previous) {
    if !enabled.contains(entry.name) {
      out.push(entry.name)
    }
  }
  out
}

///|
/// The settings panel as HTML, for the session being displayed.
///
/// The catalog is loaded first: the panel is the one place a reader can be looking at skills
/// before any turn has been run, and a directory whose skills have never been scanned would
/// otherwise read as a directory with no skills — which is a different, more alarming thing.
async fn render_settings_panel(app : App, shown : Runner) -> String {
  app.load_skills(shown.cwd)
  @html.render_settings(settings_view(app, shown)).render()
}

///|
/// The control that opens the panel, as HTML.
///
/// Separate from the panel because it belongs somewhere else on the page: the control is pinned to
/// the corner and the dialog is a modal, and they must not be replaced together — a refresh that
/// re-rendered the dialog would close it.
async fn render_settings_trigger(app : App, shown : Runner) -> String {
  @html.render_settings_trigger(settings_view(app, shown)).render()
}

///|
/// Just the panel's contents, as the region a settings post replaces.
///
/// Deliberately not `render_settings_panel`: the patch targets `settings-body`, so sending the
/// surrounding `<details>` would nest a second panel inside the first. That nesting renders — the
/// ids are unchanged and the buttons still work — which is why it took a review rather than a
/// test to notice; the browser check now counts the elements too.
async fn render_settings_body(app : App, shown : Runner) -> String {
  app.load_skills(shown.cwd)
  @html.render_settings_body(settings_view(app, shown)).render()
}

///|
/// Everything the panel shows, gathered from the process's own state.
///
/// One builder for both renderings, so a fact cannot appear in the page and be missing from the
/// refreshed copy.
///
/// Async because the instructions block reports what this workspace will actually send, which
/// means reading its `AGENTS.md` — the same read the next turn will do, so the panel cannot
/// describe a prompt that is not the one coming.
async fn settings_view(app : App, shown : Runner) -> @html.SettingsView {
  let instructions = app.instructions(shown.cwd)
  {
    // The id comes along, because this panel is where a reader looks up "which string am I calling",
    // and the id is the answer they would type (the web UI has no price columns to compare, so nothing
    // is paying for the extra characters here).
    model: @core.model_spec_for(shown.model_id).0.label_with_id(),
    base_url: app.base_url,
    context_window: @core.model_spec_for(shown.model_id).0.context_window,
    address: app.address,
    store: app.root,
    cwd: shown.cwd,
    key_source: app.key_source,
    key_hint: app.key_hint,
    env_key_set: app.env_key_set,
    saved_key_set: app.settings.saved_api_key != "",
    max_rounds: limit_view(app.limits.max_rounds, "--max-rounds", integer=true),
    max_cost: limit_view(app.limits.max_cost, "--max-cost", integer=false),
    max_seconds: limit_view(
      app.limits.max_seconds,
      "--max-seconds",
      integer=true,
    ),
    // Both in one field, because they are one decision: the source says which of the two the
    // workspace is getting, and the text is what it is getting. A panel that reported only the
    // source would leave "my file is being ignored" and "my saved text is being ignored"
    // indistinguishable.
    instructions_source: instruction_source_label(instructions.source),
    instructions_preview: instructions.text,
    agents_md: app.settings.agents_md,
    agents_md_chars: app.settings.agents_md.length(),
    skills: @core.skill_entries(
      app.discovered_skills(shown.cwd),
      app.settings.disabled_skills,
    ),
    tool_mode: app.settings.tool_mode.to_string(),
  }
}

///|
/// Where the instructions in force came from, as the panel says it.
///
/// The phrase for each source names the directory it is read from, because that is the question
/// the reader is answering when they are puzzled: a workspace file is read from the workspace, and
/// the saved one is read from `~/.wei/settings.json` and applies everywhere.
fn instruction_source_label(source : @core.InstructionSource) -> String {
  match source {
    @core.File => "AGENTS.md in this workspace"
    @core.Saved => "saved in settings"
    @core.Absent => "none"
  }
}

///|
/// Apply one settings post, and return what the status line should say about it.
///
/// The write happens before the in-memory value is adopted, so a failure to persist leaves the
/// process doing what it was doing before — the alternative is a panel that shows a saved key
/// which is gone after a restart, which is the one wrong answer here that is invisible until
/// later. The reader is told instead, on the status line.
async fn apply_settings_post(
  app : App,
  shown : Runner,
  post : @core.SettingsPost,
) -> String {
  // The catalog first, for the same reason the panel loads it before rendering: a workspace whose
  // skills have never been scanned has an empty cache, and `ApplySkills` derives the new disabled
  // list *from the catalog*. Without this, switching a skill off in a workspace no turn has run in
  // yet computes an empty list from an empty catalog and silently discards the change — and the
  // render that follows loads the catalog, so the panel then shows the skill back on. Measured:
  // the log said `discovered=0 enabled=[]` for a workspace whose skills existed all along.
  app.load_skills(shown.cwd)
  let next = match post {
    SaveKey(key~, clear~) =>
      if clear {
        app.settings.with_saved_api_key("")
      } else {
        app.settings.with_saved_api_key(key)
      }
    ApplySkills(enabled~) =>
      app.settings.with_disabled_skills(
        disabled_after_apply(
          app.discovered_skills(shown.cwd),
          app.settings.disabled_skills,
          enabled,
        ),
      )
    ApplyLimits(max_rounds~, max_cost~, max_seconds~) =>
      app.settings.with_limits(max_rounds, max_cost, max_seconds)
    ApplyAgentsMd(text~) => app.settings.with_agents_md(text)
    ApplyToolMode(mode~) =>
      app.settings.with_tool_mode(@core.parse_tool_mode(mode))
  }
  let saved = try {
    @platform.save_settings(app.home, next)
    true
  } catch {
    _ => false
  } noraise {
    ok => ok
  }
  if !saved {
    return "could not write ~/.wei/settings.json"
  }
  app.settings = next
  // Re-derived before the message, so what the status line reports is what the next turn will use
  // rather than what was typed. A flag still wins, and the reader is told which limit is actually
  // in force — the one case where a saved value silently does nothing.
  app.refresh_limits()
  match post {
    SaveKey(key~, clear~) => {
      // Re-resolved rather than assigned: whether a saved key is the one in use depends on the
      // environment, and that is a decision `@core.choose_api_key` already makes. Assigning it
      // here would have meant a second, subtly different answer to the same question.
      app.set_key(app.resolve_key())
      if clear {
        if app.key_source == "environment" {
          "saved key cleared; DEEPSEEK_API_KEY is still in use"
        } else {
          "saved key cleared: no key is set now"
        }
      } else if key.trim() == "" {
        "no key saved"
      } else if app.key_source == "saved" {
        "key saved: the next turn uses it"
      } else {
        "key saved, but \{key_source_label(app.key_source)} is in use"
      }
    }
    ApplySkills(..) => {
      let on = app.skills_for(shown.cwd).length()
      "\{on} skill(s) enabled: applied on the next turn"
    }
    ApplyAgentsMd(..) =>
      // Reported from what was just saved rather than from the source in force, because the two
      // answer different questions when a workspace has a file of its own: the reader needs to
      // know their save landed *and* that it is not the text being sent. A workspace with its own
      // `AGENTS.md` is the one case where saving looks like nothing happened, so it is the case
      // that gets a message of its own.
      match app.instructions(shown.cwd).source {
        @core.File =>
          if app.settings.agents_md == "" {
            "saved instructions cleared; this workspace uses its own AGENTS.md"
          } else {
            "instructions saved, but this workspace's AGENTS.md takes precedence"
          }
        @core.Saved =>
          "instructions saved: the next turn in a workspace without AGENTS.md uses them"
        @core.Absent => "saved instructions cleared: no instructions are sent"
      }
    ApplyToolMode(..) =>
      // Said in terms of what changes rather than in terms of the word that was posted: "code"
      // alone would restate the click, and the number is the part the reader is deciding about.
      "\{app.settings.tool_mode.to_string()} mode: \{app.tools().length()} tools on the next turn"
    ApplyLimits(..) => {
      let rounds = app.limits.max_rounds
      let cost = app.limits.max_cost
      let seconds = app.limits.max_seconds
      if rounds.source == @core.Flag ||
        cost.source == @core.Flag ||
        seconds.source == @core.Flag {
        "saved; \{flag_limit_note(app)} still in force"
      } else {
        let calls = if rounds.value <= 0.0 {
          "no call bound"
        } else {
          "\{limit_summary(rounds)} calls"
        }
        let spend = if cost.value <= 0.0 {
          "no cost bound"
        } else {
          "$\{limit_summary(cost)}"
        }
        let time = if seconds.value <= 0.0 {
          "no time bound"
        } else {
          "\{limit_summary(seconds)}s"
        }
        "limits saved: \{calls}, \{spend}, \{time} per turn"
      }
    }
  }
}

///|
/// One limit as a status line reads it. `0` is the case worth naming, because it means the bound
/// is off rather than that it is zero.
fn limit_summary(limit : @core.Limit) -> String {
  if limit.value <= 0.0 {
    "no"
  } else {
    "\{@html.format_limit_cost(limit.value)}"
  }
}

///|
/// Which launch flags are pinning a limit, for a message that has to explain why saving did not
/// change what the next turn uses.
fn flag_limit_note(app : App) -> String {
  let names : Array[String] = []
  if app.limits.max_rounds.source == @core.Flag {
    names.push("--max-rounds")
  }
  if app.limits.max_cost.source == @core.Flag {
    names.push("--max-cost")
  }
  if app.limits.max_seconds.source == @core.Flag {
    names.push("--max-seconds")
  }
  names.join(" and ")
}
