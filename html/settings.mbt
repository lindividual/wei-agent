///|
/// The settings panel.
///
/// Server-rendered like everything else, and for the same reason: it is a view of state the
/// server owns, so "what is in the panel" and "what the process will do" cannot drift. There is
/// no client-side model of a form here — the reader types a key, the server writes it and
/// re-renders the panel, and what comes back is what is actually in effect.
///
/// The panel is a native `<details>`, so the browser remembers whether it is open and no
/// JavaScript is involved in opening it. It is deliberately a *live* view rather than a page of
/// editable settings: the model, the endpoint and the store are fixed at launch, and a form that
/// appeared to change them would be lying. What is editable is exactly what a running process can
/// honor — a saved key, and the skills in the catalog.
///
/// The key is never rendered back. The panel shows which provider the key in use came from and a
/// masked fingerprint of it, which is enough to answer "is the key I just pasted the one being
/// used" without putting a credential in a page that the browser may cache, screenshot or hand to
/// an extension.

///|
/// Everything the panel displays.
pub(all) struct SettingsView {
  /// The model this process calls. Read-only: it is a launch flag.
  model : String
  /// Where the model is served from. Read-only, for the same reason.
  base_url : String
  /// The model's context window, in tokens.
  context_window : Int
  /// The address the server listens on.
  address : String
  /// The session store, as this process resolved it.
  store : String
  /// The workspace the agent is currently in.
  cwd : String
  /// Which provider the key in use came from: `environment`, `saved`, `pi` or `none`.
  key_source : String
  /// The key in use, identified but not revealed: `sk-…4f2a`, or empty when there is none.
  key_hint : String
  /// Whether `DEEPSEEK_API_KEY` is set. When it is, a saved key is a fallback and the panel says
  /// so, because otherwise "I saved a key and it still uses the old one" reads as a bug.
  env_key_set : Bool
  /// Whether a key has been saved. With `env_key_set`, this is the case the panel has to explain:
  /// a key the reader saved is being overruled.
  saved_key_set : Bool
  /// The limits in force for a turn, and where each came from: `flag`, `saved` or `default`.
  /// A limit set by a flag is shown but not editable, because a field that appears to accept a
  /// value the process will ignore is worse than no field.
  max_rounds : LimitView
  max_cost : LimitView
  max_seconds : LimitView
  /// Where the instructions this workspace will carry came from: a file in the workspace, the
  /// saved text, or nowhere.
  instructions_source : String
  /// Those instructions, exactly as the next turn will append them. Empty when there are none.
  instructions_preview : String
  /// The saved fallback text as the textarea holds it, so a reader can edit what they wrote
  /// rather than retyping it.
  agents_md : String
  /// Its length, for the block's heading: the panel can say how large the fallback is without
  /// anyone having to count, and "0 characters" is the honest way to show an empty one.
  agents_md_chars : Int
  /// Every skill the panel knows about, on or off.
  skills : Array[@core.SkillEntry]
  /// The tools a turn gets: `tools` or `code`.
  ///
  /// Two words rather than the enum, because the panel posts a form and a form carries text. The
  /// spellings are the ones `@core.parse_tool_mode` reads, and that is the only parser either of
  /// them goes through.
  tool_mode : String
} derive(Eq, Debug)

///|
/// One limit as the panel shows it: the value, and where it came from.
pub(all) struct LimitView {
  /// The value in force, formatted for the field. Empty when the reader has never set one.
  text : String
  source : String
  /// Whether the reader can change it. False only when a launch flag pinned it.
  editable : Bool
} derive(Eq, Debug)

///|
/// Format a dollar limit so it round-trips through the field that shows it.
///
/// The four decimals are the status line's, so a value copied out of the folder and pasted back is the
/// same number. A value with no cents does not grow four of them, because `1` reads better than
/// `1.0000` in a field someone is about to edit.
pub fn format_limit_cost(value : Double) -> String {
  if value == 0.0 {
    return "0"
  }
  if value == value.to_int().to_double() {
    return value.to_int().to_string()
  }
  // Four decimals, trimmed of trailing zeros so `0.5` does not become `0.5000`.
  let scaled = (value * 10000.0).round().to_int()
  let whole = scaled / 10000
  let frac = scaled % 10000
  if frac == 0 {
    return whole.to_string()
  }
  let mut digits = frac.to_string()
  while digits.length() < 4 {
    digits = "0\{digits}"
  }
  while digits.has_suffix("0") {
    digits = digits[:digits.length() - 1].to_owned()
  }
  "\{whole}.\{digits}"
}

///|
/// The fingerprint of a key: enough to tell two apart, not enough to use.
///
/// A short prefix and the last four characters, which is what every console on the internet does
/// and what a reader checking "did my paste land" actually needs. A key too short to mask is shown
/// as dots rather than echoed, because the point of the mask is not to leak it.
pub fn mask_key(key : String) -> String {
  if key == "" {
    return ""
  }
  if key.length() <= 8 {
    return "…"
  }
  let tail = key[key.length() - 4:]
  "\{key[:4]}…\{tail}"
}

///|
/// Which skills are on, out of how many.
pub fn skills_summary(skills : Array[@core.SkillEntry]) -> String {
  let mut on = 0
  for skill in skills {
    if skill.enabled {
      on += 1
    }
  }
  "\{on}/\{skills.length()} on"
}

///|
/// The panel's sections, in the order they are rendered.
///
/// One list, used by the navigation and by the sections themselves, so the anchors cannot point
/// at an id that was renamed. The label is what the reader clicks; the id is what it points at.
pub fn settings_sections() -> Array[(String, String)] {
  [
    ("settings-model", "model"),
    ("settings-mode", "tools"),
    ("settings-limits", "turn limits"),
    ("settings-instructions", "instructions"),
    ("settings-key", "api key"),
    ("settings-skills", "skills"),
    ("settings-paths", "paths"),
  ]
}

///|
/// The control that opens the panel.
///
/// A button rather than a `<summary>`: the panel is a modal dialog now, and a modal is opened by
/// script (`showModal`), not by the element that holds it. What was worth keeping from the
/// `<details>` version is that this control never moves — it sits outside every region a refresh
/// replaces, so a turn arriving mid-edit cannot take it away.
///
/// It carries `data-attention` when there is something to act on, and that is the whole of the
/// prompt to open it. The panel used to open *itself* on the first paint for this case, which was
/// affordable when it was a small anchored box and is not when it is a modal: taking the screen
/// before the reader has asked is the kind of interruption a missing key does not justify. A mark
/// on the button says the same thing without the takeover.
pub fn render_settings_trigger(view : SettingsView) -> Node {
  let key_overruled = view.env_key_set && view.saved_key_set
  let attention = view.key_source == "none" || key_overruled
  let attrs : Array[Attr] = [
    attr("id", "settings-open"),
    attr("type", "button"),
    cls("settings-open"),
    attr("aria-haspopup", "dialog"),
  ]
  if attention {
    attrs.push(attr("data-attention", ""))
  }
  el(Button, attrs~, children=[txt("settings")])
}

///|
/// The panel: a modal dialog with its sections in a scrollable column and their names beside them.
///
/// A dialog rather than the anchored `<details>` it was: the box had to be narrow enough to sit in
/// the sidebar's column without covering the composer, and at that width every section was worse to
/// read than it needed to be — the skills list, the instructions editor and the limit rows all
/// wanted more room than one column. A modal gets that room by taking the whole surface for as long
/// as the reader is using it, which is what they asked for by opening it.
///
/// The navigation is a **sibling** of `render_settings_body`, not a child. That is the load-bearing
/// part: a settings post replaces the body, and a navigation inside it would be re-rendered on every
/// save — losing which section the reader was in, and briefly offering nothing to click. Outside the
/// patched region it is drawn once and never touched.
pub fn render_settings(view : SettingsView) -> Node {
  let nav : Array[Node] = []
  for entry in settings_sections() {
    let (id, label) = entry
    nav.push(
      el(
        Button,
        attrs=[
          attr("type", "button"),
          cls("settings-nav-item"),
          attr("data-section", id),
        ],
        children=[txt(label)],
      ),
    )
  }
  el(Dialog, attrs=[attr("id", "settings"), cls("settings")], children=[
    el(Div, attrs=[cls("settings-shell")], children=[
      el(Header, attrs=[cls("settings-head")], children=[
        el(H2, attrs=[attr("id", "settings-title"), cls("settings-title")], children=[
          txt("settings"),
        ]),
        // A visible way out, beside the two the browser gives (`Esc` and clicking away). Named for
        // a screen reader rather than with a bare glyph: "✕" is not a word.
        el(
          Button,
          attrs=[
            attr("id", "settings-close"),
            attr("type", "button"),
            cls("settings-close"),
            attr("aria-label", "Close settings"),
          ],
          children=[txt("✕")],
        ),
      ]),
      el(Div, attrs=[cls("settings-main")], children=[
        el(
          Nav,
          attrs=[attr("id", "settings-nav"), cls("settings-nav")],
          children=nav,
        ),
        render_settings_body(view),
      ]),
    ]),
  ])
}

///|
/// The panel's contents, and the region a settings post replaces.
///
/// It carries its own id so a refresh replaces *this* rather than the dialog around it: replacing
/// the dialog would close it under the reader's hands, and the reader is looking at it precisely
/// because they are in the middle of changing something.
pub fn render_settings_body(view : SettingsView) -> Node {
  let blocks = [
    ("settings-model", render_model_block(view)),
    ("settings-mode", render_tool_mode_block(view)),
    ("settings-limits", render_limits_block(view)),
    ("settings-instructions", render_instructions_block(view)),
    ("settings-key", render_key_block(view)),
    ("settings-skills", render_skills_block(view)),
    ("settings-paths", render_paths_block(view)),
  ]
  let children : Array[Node] = []
  for entry in blocks {
    let (id, block) = entry
    // Each section is addressable by the navigation, and the id lives here rather than in the
    // block's own renderer so that the two lists above and below cannot disagree.
    children.push(
      el(Section, attrs=[attr("id", id), cls("settings-section")], children=[
        block,
      ]),
    )
  }
  el(Div, attrs=[attr("id", "settings-body"), cls("settings-body")], children~)
}

///|
/// The instructions a workspace gets, and the fallback for the ones that have none.
///
/// Two things in one block because they are one rule, and the panel is where that rule has to be
/// legible: the source line above the preview says which of the two this workspace is actually
/// getting, so a reader who has just written a page of instructions into the box can see whether
/// they are the ones being sent. Showing the preview without the source, or the source without the
/// preview, would each leave half the question open.
///
/// The preview is rendered as text rather than as markup. What it is previewing is prompt prose,
/// not a document, and making it look like a document would invite the reader to trust it as one.
fn render_instructions_block(view : SettingsView) -> Node {
  let source = el(P, attrs=[cls("instruction-source")], children=[
    txt("In force here: "),
    el(B, children=[txt(view.instructions_source)]),
  ])
  // Rendered only when there is something to render. An empty frame with a label on it reads as a
  // feature that is broken rather than as a workspace that has not asked for anything.
  let preview = if view.instructions_preview == "" {
    el(P, attrs=[cls("hint")], children=[
      txt("No instructions are being sent for this workspace."),
    ])
  } else {
    el(Pre, attrs=[cls("instruction-preview")], children=[
      txt(view.instructions_preview),
    ])
  }
  el(Section, attrs=[cls("settings-block")], children=[
    el(H3, children=[txt("instructions")]),
    source,
    preview,
    el(Form, attrs=[cls("agents-form"), attr("id", "agents-form")], children=[
      // The marker the instructions form always sends. Without it an emptied textarea posts an
      // empty body, which is indistinguishable from a request the panel never made — so clearing
      // the fallback would be the one edit the panel could not express.
      el(Input, attrs=[
        attr("type", "hidden"),
        attr("name", "agents"),
        attr("value", "1"),
      ]),
      el(Label, attrs=[cls("agents-label")], children=[
        txt("Used where a workspace has no AGENTS.md"),
      ]),
      el(
        Textarea,
        attrs=[
          attr("name", "agents_md"),
          attr("id", "agents-input"),
          attr("rows", "6"),
          attr(
            "placeholder", "How you want the agent to work when a repository does not say.",
          ),
          attr("spellcheck", "false"),
        ],
        children=[txt(view.agents_md)],
      ),
      el(Div, attrs=[cls("btn-row")], children=[
        el(Button, attrs=[attr("type", "submit")], children=[txt("Apply")]),
        el(Span, attrs=[cls("hint")], children=[
          txt("\{view.agents_md_chars} characters saved"),
        ]),
      ]),
    ]),
    el(P, attrs=[cls("hint")], children=[
      txt(
        "A workspace's own AGENTS.md, at the top of the directory the session runs in, is used instead of this. Applies from the next turn.",
      ),
    ]),
  ])
}

///|
/// The guards on a turn, and the one place in the panel where a reader changes how much the
/// agent may spend or how long it may keep trying.
///
/// A number field rather than a slider: these are safety bounds, and a reader who wants exactly
/// `$0.25` should be able to type it. An empty field is "no opinion" — which falls back to the flag
/// or the built-in default — and `0` is "no bound at all", stated plainly in the hint, because the
/// one thing a guard must never do is disable itself without saying so. The special-casing is
/// exactly how the driver already reads the numbers; the panel is the first place that distinction
/// has been visible to anyone but the person who wrote the flag.
pub fn render_limits_block(view : SettingsView) -> Node {
  let fields = [
    ("model calls per turn", "max_rounds", "40", view.max_rounds),
    ("max cost per turn ($)", "max_cost", "0.25", view.max_cost),
    ("max seconds per turn", "max_seconds", "1800", view.max_seconds),
  ]
  let rows : Array[Node] = []
  for field in fields {
    let (label, name, placeholder, limit) = field
    let input : Array[Attr] = [
      attr("name", name),
      attr("type", "text"),
      attr("inputmode", "decimal"),
      attr("autocomplete", "off"),
      attr("placeholder", placeholder),
      attr("aria-label", label),
    ]
    if limit.editable {
      input.push(attr("value", limit.text))
    } else {
      input.push(attr("value", limit.text))
      input.push(attr("readonly", ""))
    }
    let source = el(Span, attrs=[cls("source")], children=[txt(limit.source)])
    rows.push(
      el(
        Label,
        attrs=[cls(if limit.editable { "limit" } else { "limit pinned" })],
        children=[
          el(Span, attrs=[cls("limit-name")], children=[txt(label)]),
          el(Span, attrs=[cls("limit-value")], children=[
            el(Input, attrs=input),
            source,
          ]),
        ],
      ),
    )
  }
  // Every limit pinned by launch flags: there is nothing a page can change, so there is no form.
  // The rows are still shown — a reader wondering why saving did nothing has to be able to see
  // what actually bounds the next turn — but as a plain list rather than a form that could post a
  // change the process would ignore.
  let editable = view.max_rounds.editable ||
    view.max_cost.editable ||
    view.max_seconds.editable
  let body = if editable {
    el(Form, attrs=[cls("limits-form"), attr("id", "limits-form")], children=[
      el(Input, attrs=[
        attr("type", "hidden"),
        attr("name", "limits"),
        attr("value", "1"),
      ]),
      el(Div, attrs=[cls("limit-list")], children=rows),
      el(Div, attrs=[cls("btn-row")], children=[
        el(Button, attrs=[attr("type", "submit")], children=[txt("Apply")]),
      ]),
    ])
  } else {
    el(Div, attrs=[cls("limit-list")], children=rows)
  }
  el(Section, attrs=[cls("settings-block")], children=[
    el(H3, children=[txt("turn limits")]),
    body,
    // Dropping every saved limit is its own form carrying only the marker, which is exactly what
    // "no saved limits" decodes to — so it needs no JavaScript beyond the one submit listener, and
    // no submit button whose value would have to survive `FormData`.
    if editable {
      el(Form, attrs=[cls("limits-clear"), attr("id", "limits-clear")], children=[
        el(Input, attrs=[
          attr("type", "hidden"),
          attr("name", "limits"),
          attr("value", "1"),
        ]),
        el(Div, attrs=[cls("btn-row")], children=[
          el(Button, attrs=[attr("type", "submit"), cls("ghost")], children=[
            txt("Reset to defaults"),
          ]),
        ]),
      ])
    } else {
      nothing()
    },
    el(P, attrs=[cls("hint")], children=[
      txt(
        if editable {
          "A turn stops when it has made this many model calls, cost this much, or taken this long. Leave a field empty for the default (200 calls, $1, 1800s); put 0 in it to remove the bound. Applies from the next turn."
        } else {
          "A limit set on the command line is fixed for this run, and the pinned field shows which one. Restart without those flags to change them here."
        },
      ),
    ]),
  ])
}

///|
/// Which tools a turn works with, as two choices.
///
/// The one setting whose effect the reader cannot see from the panel, because the tools are in the
/// prompt rather than in the page — so the block says what each mode costs as well as what it is:
/// code mode drops the file tools, and every read becomes a command the model has to write.
///
/// The form carries the chosen radio and nothing else, so the marker and the value are the same
/// field. Which is why an unknown mode is refused by the parser rather than defaulting: a post that
/// said nothing would otherwise be the same thing as a post that said `tools`.
pub fn render_tool_mode_block(view : SettingsView) -> Node {
  let choices = [
    (
      "tools", "tools", "Eight tools, one verb each: read, write, edit, glob, grep, bash, script, note.",
    ),
    (
      "code", "code", "Two tools: exec runs a shell command or a MoonBit program, wait collects what one left running. Reading a file is a command; output is capped and keeps the end.",
    ),
  ]
  let rows : Array[Node] = []
  for choice in choices {
    let (value, name, about) = choice
    let on = view.tool_mode == value
    let attrs : Array[Attr] = [
      attr("type", "radio"),
      attr("name", "tool_mode"),
      attr("value", value),
    ]
    if on {
      attrs.push(attr("checked", ""))
    }
    rows.push(
      el(Label, attrs=[cls(if on { "mode" } else { "mode off" })], children=[
        el(Input, attrs~),
        el(Span, attrs=[cls("mode-text")], children=[
          el(B, children=[txt(name)]),
          el(I, children=[txt(about)]),
        ]),
      ]),
    )
  }
  el(Section, attrs=[cls("settings-block")], children=[
    el(H3, children=[txt("tools")]),
    el(Form, attrs=[cls("mode-form"), attr("id", "mode-form")], children=[
      el(Div, attrs=[cls("mode-list")], children=rows),
      el(Div, attrs=[cls("btn-row")], children=[
        el(Button, attrs=[attr("type", "submit")], children=[txt("Apply")]),
      ]),
    ]),
    el(P, attrs=[cls("hint")], children=[
      txt(
        "A mode applies from the next turn — the tools a turn is given are part of the request, so a turn already running finishes with the ones it started with. `--mode` on the command line pins it for the run.",
      ),
    ]),
  ])
}

///|
/// What is being called, where, and how big its window is.
pub fn render_model_block(view : SettingsView) -> Node {
  el(Section, attrs=[cls("settings-block")], children=[
    el(H3, children=[txt("model")]),
    facts([
      ("model", view.model, "a launch flag: restart with --model to change it"),
      ("endpoint", view.base_url, "the base URL of the API"),
      (
        "context window",
        "\{compact_number(view.context_window)} tokens",
        "what the conversation is measured against",
      ),
    ]),
  ])
}

///|
/// The key: which one is in use, and the one form the panel can change.
fn render_key_block(view : SettingsView) -> Node {
  let state = match view.key_source {
    "environment" => "in use, from DEEPSEEK_API_KEY"
    "saved" => "in use, saved by this panel"
    "pi" => "in use, from pi's credential store"
    _ => "no key: the first turn will fail"
  }
  let rows : Array[Node] = [
    el(Div, attrs=[cls("key-state")], children=[
      el(Span, attrs=[cls("state")], children=[txt(state)]),
      el(B, children=[txt(view.key_hint)]),
    ]),
  ]
  if view.env_key_set {
    rows.push(
      el(P, attrs=[cls("hint")], children=[
        txt(
          "DEEPSEEK_API_KEY is set, so it wins over anything saved here. Unset it to use the saved key.",
        ),
      ]),
    )
  }
  el(Section, attrs=[cls("settings-block")], children=[
    el(H3, children=[txt("api key")]),
    frag(rows),
    el(Form, attrs=[cls("key-form"), attr("id", "key-form")], children=[
      el(Input, attrs=[
        attr("id", "key-input"),
        attr("name", "key"),
        attr("type", "password"),
        attr("autocomplete", "off"),
        attr("spellcheck", "false"),
        attr("placeholder", "paste a key to save it here"),
      ]),
      el(Div, attrs=[cls("btn-row")], children=[
        el(Button, attrs=[attr("type", "submit")], children=[txt("Save key")]),
      ]),
    ]),
    // Clearing is its own form, not a second submit button in the one above. A button's name and
    // value reach the server only when the button is the submitter, and `new FormData(form)`
    // deliberately leaves submit buttons out — so a `clear=1` button sharing the key form would
    // post an empty `key` instead and be read as "save nothing", which swallows the message that
    // tells the reader what is in use now. A hidden field in its own form cannot be missed.
    if view.saved_key_set {
      el(Form, attrs=[cls("key-clear"), attr("id", "key-clear")], children=[
        el(Input, attrs=[
          attr("type", "hidden"),
          attr("name", "clear"),
          attr("value", "1"),
        ]),
        el(Div, attrs=[cls("btn-row")], children=[
          el(Button, attrs=[attr("type", "submit"), cls("ghost")], children=[
            txt("Clear saved key"),
          ]),
        ]),
      ])
    } else {
      nothing()
    },
    el(P, attrs=[cls("hint")], children=[
      txt(
        "Stored in ~/.pi-mb/settings.json, readable only by you. It is never sent back to the browser.",
      ),
    ]),
  ])
}

///|
/// The catalog, with a switch per skill.
///
/// Checked means the skill reaches the model. The list is submitted as a whole rather than
/// toggled one request per click, because the state that matters is the set, and applying a set
/// has one outcome to report instead of one per click to race with.
fn render_skills_block(view : SettingsView) -> Node {
  if view.skills.length() == 0 {
    return el(Section, attrs=[cls("settings-block")], children=[
      el(H3, children=[txt("skills")]),
      el(P, attrs=[cls("hint")], children=[
        txt(
          "none found. A skill is <dir>/SKILL.md or <name>.md under ~/.pi/agent/skills, ~/.agents/skills, or .pi/skills in this project.",
        ),
      ]),
    ])
  }
  let rows : Array[Node] = []
  for skill in view.skills {
    let checked : Array[Attr] = [
      attr("type", "checkbox"),
      attr("name", "skill"),
      attr("value", skill.name),
    ]
    if skill.enabled {
      checked.push(attr("checked", ""))
    }
    let meta = if skill.path == "" {
      el(Span, attrs=[cls("missing")], children=[txt("no file found")])
    } else {
      el(Span, attrs=[cls("where")], children=[txt(skill.path)])
    }
    rows.push(
      el(
        Label,
        attrs=[cls(if skill.enabled { "skill" } else { "skill off" })],
        children=[
          el(Input, attrs=checked),
          el(Span, attrs=[cls("skill-text")], children=[
            el(B, children=[txt(skill.name)]),
            el(I, children=[txt(skill.description)]),
            meta,
          ]),
        ],
      ),
    )
  }
  el(Section, attrs=[cls("settings-block")], children=[
    el(H3, children=[
      txt("skills "),
      el(Span, attrs=[cls("count")], children=[txt(skills_summary(view.skills))]),
    ]),
    el(Form, attrs=[cls("skills-form"), attr("id", "skills-form")], children=[
      // Always sent, even with every box unchecked: without it an all-unchecked form posts an
      // empty body, which is indistinguishable from a request the panel did not make — and a
      // reader switching off their last skill would see nothing happen.
      el(Input, attrs=[
        attr("type", "hidden"),
        attr("name", "skills"),
        attr("value", "1"),
      ]),
      el(Div, attrs=[cls("skill-list")], children=rows),
      el(Div, attrs=[cls("btn-row")], children=[
        el(Button, attrs=[attr("type", "submit")], children=[txt("Apply")]),
      ]),
    ]),
    el(P, attrs=[cls("hint")], children=[
      txt(
        "A skill switched off stays off by name, and its file is left alone. The catalog reaches the model on the next turn.",
      ),
    ]),
  ])
}

///|
/// Where the process keeps things. Not editable, but the question "where did my sessions go" is
/// asked here first.
fn render_paths_block(view : SettingsView) -> Node {
  el(Section, attrs=[cls("settings-block")], children=[
    el(H3, children=[txt("where things are")]),
    facts([
      ("listening", view.address, "change with --port"),
      ("workspace", view.cwd, "the directory tools run in for this session"),
      ("sessions", view.store, "change with --store"),
    ]),
  ])
}

///|
/// A two-column list of labelled facts, each with a tooltip saying why it is not editable when it
/// is not.
fn facts(rows : Array[(String, String, String)]) -> Node {
  let items : Array[Node] = []
  for row in rows {
    let (label, value, detail) = row
    items.push(el(Dt, children=[txt(label)]))
    items.push(el(Dd, attrs=[attr("title", detail)], children=[txt(value)]))
  }
  el(Dl, attrs=[cls("facts")], children=items)
}
