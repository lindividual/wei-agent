///|
/// The settings panel.
///
/// The assertions are about the contract the client script and the server depend on: the ids a
/// submit is intercepted by, the form field names the POST is decoded from, and — the one that
/// matters most — that a key reaches the page as a fingerprint rather than as itself.

///|
fn entry(name : String, enabled : Bool) -> @core.SkillEntry {
  {
    name,
    description: "does \{name}",
    path: "/skills/\{name}/SKILL.md",
    enabled,
  }
}

///|
fn view() -> SettingsView {
  {
    model: "deepseek-v4-flash",
    base_url: "https://api.deepseek.com",
    context_window: 1000000,
    address: "127.0.0.1:8790",
    store: "/home/u/.pi-mb/sessions",
    cwd: "/work/proj",
    key_source: "saved",
    key_hint: "sk-a…1234",
    env_key_set: false,
    saved_key_set: true,
    max_rounds: { text: "40", source: "saved", editable: true, },
    max_cost: { text: "0.25", source: "saved", editable: true, },
    instructions_source: "AGENTS.md in this workspace",
    instructions_preview: "Run moon test before committing.",
    agents_md: "Prefer small diffs.",
    agents_md_chars: 18,
    skills: [entry("alpha", true), entry("beta", false)],
  }
}

///|
test "a key is identified by a fingerprint, never echoed" {
  assert_eq(mask_key("sk-1234567890abcdef"), "sk-1…cdef")
  // Too short to mask without giving it away is not echoed at all.
  assert_eq(mask_key("sk-123"), "…")
  assert_eq(mask_key(""), "")
  assert_false(mask_key("sk-1234567890abcdef").contains("567890"))
}

///|
/// The instructions block: the marker the client posts, the source line, and that the box holds
/// what was saved rather than what is in force.
test "the instructions block carries the ids and field names the client posts" {
  let html = render_settings(view()).render()
  assert_true(html.contains("id=\"agents-form\""), msg=html)
  assert_true(html.contains("name=\"agents\""), msg=html)
  assert_true(html.contains("name=\"agents_md\""), msg=html)
  // The saved fallback is in the textarea, and the preview is what this workspace actually sends —
  // two different things on purpose, and the whole reason the source line is above them.
  assert_true(html.contains("Prefer small diffs."), msg=html)
  assert_true(html.contains("Run moon test before committing."), msg=html)
  assert_true(html.contains("AGENTS.md in this workspace"), msg=html)
  assert_true(html.contains("18 characters saved"), msg=html)
}

///|
/// A workspace with nothing to send says so, rather than showing an empty frame that reads as a
/// feature which is broken.
test "an empty instructions preview is stated rather than shown blank" {
  let empty : SettingsView = {
    ..view(),
    instructions_source: "none",
    instructions_preview: "",
    agents_md: "",
    agents_md_chars: 0,
  }
  let html = render_settings(empty).render()
  assert_true(html.contains("No instructions are being sent"), msg=html)
  assert_false(html.contains("instruction-preview"), msg=html)
  assert_true(html.contains("0 characters saved"), msg=html)
}

///|
/// The client script finds a form by id and posts what is in it, so an id that changes silently
/// turns the panel into a form that navigates away from the page.
test "the forms carry the ids and field names the client posts" {
  let html = render_settings(view()).render()
  assert_true(html.contains("id=\"key-form\""), msg=html)
  assert_true(html.contains("id=\"skills-form\""), msg=html)
  assert_true(html.contains("name=\"skill\""), msg=html)
  // The catalog form sends a marker whether or not a box is checked: an all-unchecked form posts
  // an empty body otherwise, and the server could not tell it from a request the panel did not
  // make.
  assert_true(html.contains("name=\"skills\""), msg=html)
  // The key field is masked on screen, and named `key` for the one way in.
  assert_true(html.contains("name=\"key\""), msg=html)
  assert_true(html.contains("type=\"password\""), msg=html)
}

///|
/// Clearing the saved key is its own form with a hidden field, not a second submit button sharing
/// the key form: `new FormData(form)` leaves submit buttons out, so a shared button would post an
/// empty `key`, be read as "save nothing", and quietly lose the message that says what the process
/// will use instead.
test "clearing the saved key has its own form, present only when there is one" {
  let html = render_settings(view()).render()
  assert_true(html.contains("id=\"key-clear\""), msg=html)
  let clear = html.find("id=\"key-clear\"").unwrap()
  assert_true(html[clear:].contains("name=\"clear\""), msg=html)
  // The save form does not carry a clear field, so the two actions cannot be confused by the
  // client posting the wrong one.
  let save = html.find("id=\"key-form\"").unwrap()
  let clear_at = html.find("id=\"key-clear\"").unwrap()
  assert_false(html[save:clear_at].contains("name=\"clear\""))
  // Nothing saved means nothing to clear, so the control is not offered at all.
  let no_saved : SettingsView = { ..view(), saved_key_set: false, }
  assert_false(render_settings(no_saved).render().contains("id=\"key-clear\""))
}

///|
test "an enabled skill is checked and a disabled one is not" {
  let html = render_settings(view()).render()
  let alpha = html.find("value=\"alpha\"").unwrap()
  assert_true(html[alpha:].has_prefix("value=\"alpha\" checked"), msg=html)
  let beta = html.find("value=\"beta\"").unwrap()
  assert_false(
    html[beta:].has_prefix("value=\"beta\" checked"),
    msg="a disabled skill must not render as checked",
  )
  assert_true(html.contains("1/2 on"), msg=html)
  // The description and the file are both shown: the first is how a reader decides, the second
  // is how they find the file to edit.
  assert_true(html.contains("does alpha"), msg=html)
  assert_true(html.contains("/skills/alpha/SKILL.md"), msg=html)
}

///|
test "a disabled name with no file is listed, and says it has no file" {
  let stale : SettingsView = {
    ..view(),
    skills: [{ name: "gone", description: "", path: "", enabled: false, }],
  }
  let html = render_settings(stale).render()
  assert_true(html.contains("value=\"gone\""), msg=html)
  assert_true(html.contains("no file found"), msg=html)
  assert_true(html.contains("0/1 on"), msg=html)
}

///|
test "an empty catalog explains what a skill is instead of showing nothing" {
  let empty : SettingsView = { ..view(), skills: [], }
  let html = render_settings(empty).render()
  assert_true(html.contains("none found"), msg=html)
  assert_true(html.contains("SKILL.md"), msg=html)
  // No form to submit when there is nothing to submit, so the button cannot post an empty set.
  assert_false(html.contains("id=\"skills-form\""), msg=html)
}

///|
/// The body is replaced on every change, and the navigation is deliberately outside it.
///
/// The split is what makes the panel usable: a save replaces the sections, and if the navigation
/// were inside them it would be re-rendered on every save — losing which section the reader was in,
/// and briefly offering nothing to click.
test "the body is a replaceable region, and the navigation is not part of it" {
  let html = render_settings(view()).render()
  // Exactly one of each: a refresh sends the body, and sending the dialog instead would nest a
  // second panel inside the first — which still renders and still works, because the ids inside are
  // unchanged, so only a count catches it.
  assert_eq(count_of(html, "id=\"settings-body\""), 1)
  assert_eq(count_of(html, "id=\"settings\""), 1)
  assert_eq(count_of(html, "<dialog"), 1)
  assert_eq(count_of(html, "<nav"), 1)
  // The dialog must not be open on the first paint. A modal takes the whole surface, so opening it
  // is something the reader asks for; the stylesheet shows the open attribute would be wrong here.
  assert_false(
    html.contains("<dialog id=\"settings\" class=\"settings\" open"),
    msg=html,
  )
  // The navigation is a sibling of the body, not a child: a patch that replaces the body cannot
  // take the navigation with it.
  let nav = html.find("id=\"settings-nav\"").unwrap()
  let body = html.find("id=\"settings-body\"").unwrap()
  assert_true(nav < body, msg=html)
  let body_end = html.find("</div></div></div></dialog>").unwrap()
  assert_true(nav < body && body < body_end, msg=html)
  // And the two renderings agree: the body on its own is the body inside the dialog.
  let full = render_settings(view()).render()
  assert_true(full.contains(render_settings_body(view()).render()), msg=full)
}

///|
/// Every navigation anchor points at a section that exists, and every section is reachable.
///
/// Two lists that have to agree, so the test is that they do — a renamed id would otherwise leave a
/// button that scrolls nowhere.
test "the navigation and the sections are the same list" {
  let html = render_settings(view()).render()
  for entry in settings_sections() {
    let (id, label) = entry
    assert_true(
      html.contains("data-section=\"\{id}\"") &&
      html.contains(">\{label}</button>"),
      msg="nav is missing \{id} / \{label}",
    )
    assert_eq(count_of(html, "id=\"\{id}\""), 1)
    // A section, not a bare div: the anchors are a table of contents for the panel.
    assert_true(html.contains("<section id=\"\{id}\""), msg=html)
  }
  // The dialog has a way out that is not the browser's, and a name for it that a screen reader can
  // read — "✕" is not a word.
  assert_eq(count_of(html, "id=\"settings-close\""), 1)
  assert_true(html.contains("aria-label=\"Close settings\""), msg=html)
}

///|
/// The turn limits: the two guards a reader can actually move at runtime.
test "the limits are shown with their source, and a flag-pinned one is not editable" {
  let html = render_settings(view()).render()
  assert_true(html.contains("id=\"limits-form\""), msg=html)
  assert_true(html.contains("name=\"max_rounds\""), msg=html)
  assert_true(html.contains("name=\"max_cost\""), msg=html)
  // The form always carries its marker, for the same reason the skills one does: clearing both
  // fields is an otherwise empty body.
  assert_true(html.contains("name=\"limits\""), msg=html)
  assert_true(html.contains("value=\"40\""), msg=html)
  assert_true(html.contains("value=\"0.25\""), msg=html)
  assert_true(html.contains("saved"), msg=html)
  // A resolved default is a placeholder, not a value: an empty box means "no opinion", and a box
  // pre-filled with the default would freeze that default the first time Apply was pressed.
  let by_default : SettingsView = {
    ..view(),
    max_rounds: { text: "", source: "default", editable: true, },
    max_cost: { text: "", source: "default", editable: true, },
  }
  let default_html = render_settings(by_default).render()
  assert_true(default_html.contains("placeholder=\"40\""), msg=default_html)
  assert_true(default_html.contains("placeholder=\"0.25\""), msg=default_html)
  assert_false(default_html.contains("value=\"40\""), msg=default_html)
  // A limit a launch flag set is shown but readonly, with the flag named: the one case where
  // saving a setting does nothing, and the worst one to leave unexplained.
  let pinned : SettingsView = {
    ..view(),
    max_rounds: { text: "5", source: "set by --max-rounds", editable: false, },
    max_cost: { text: "0", source: "set by --max-cost", editable: false, },
  }
  let pinned_html = render_settings(pinned).render()
  assert_true(pinned_html.contains("readonly"), msg=pinned_html)
  assert_true(pinned_html.contains("set by --max-rounds"), msg=pinned_html)
  assert_true(pinned_html.contains("set by --max-cost"), msg=pinned_html)
  assert_true(pinned_html.contains("class=\"limit pinned\""), msg=pinned_html)
  // Nothing is editable when both are pinned, so there is no form that could post a change the
  // process would ignore.
  assert_false(pinned_html.contains("id=\"limits-form\""), msg=pinned_html)
}

///|
/// A dollar limit is written the way the field has to read it back.
test "a cost limit is formatted so the field round-trips it" {
  assert_eq(format_limit_cost(0.0), "0")
  assert_eq(format_limit_cost(1.0), "1")
  assert_eq(format_limit_cost(0.25), "0.25")
  assert_eq(format_limit_cost(0.5), "0.5")
  assert_eq(format_limit_cost(1.5), "1.5")
  assert_eq(format_limit_cost(0.0001), "0.0001")
  // Four decimals is the status line's precision, so a figure copied out of the bar pastes back.
  assert_eq(format_limit_cost(0.123456), "0.1235")
  assert_eq(format_limit_cost(12.0), "12")
  // Whatever it prints parses back to the same number, which is what keeps the panel from
  // rewriting a limit every time it is rendered.
  for value in [0.0, 0.5, 1.0, 0.25, 12.75, 0.0001] {
    assert_eq(@core.parse_limit_cost(format_limit_cost(value)), Some(value))
  }
}

///|
/// Where the key came from is the first thing the panel has to answer, and the environment
/// overruling a saved key is the one case a reader reads as a bug.
test "the key panel names the provider, and the control asks for attention when action is needed" {
  let saved = render_settings(view()).render()
  assert_true(saved.contains("saved by this panel"), msg=saved)
  // Nothing is wrong and nothing needs doing: the control stays quiet.
  assert_false(
    render_settings_trigger(view()).render().contains("data-attention"),
    msg="the control should not ask for attention when nothing needs doing",
  )
  // A key the reader saved, overruled by a variable, is the case that needs explaining, so the
  // control is marked. It is a mark rather than the panel opening by itself: taking the corner was
  // affordable, taking the screen before being asked is not.
  let overruled : SettingsView = {
    ..view(),
    key_source: "environment",
    env_key_set: true,
    saved_key_set: true,
  }
  let overruled_trigger = render_settings_trigger(overruled).render()
  assert_true(
    overruled_trigger.contains("data-attention"),
    msg=overruled_trigger,
  )
  let overruled_html = render_settings(overruled).render()
  assert_true(
    overruled_html.contains("DEEPSEEK_API_KEY is set"),
    msg=overruled_html,
  )
  // The variable alone, with nothing saved for it to overrule, is the ordinary case — marking the
  // control for it would mean marking it on almost every machine.
  let from_env : SettingsView = {
    ..view(),
    key_source: "environment",
    env_key_set: true,
    saved_key_set: false,
  }
  assert_false(
    render_settings_trigger(from_env).render().contains("data-attention"),
  )
  // No key at all is the one case where the reader needs a visible way to fix it, so the control
  // says so — without opening itself.
  let missing : SettingsView = {
    ..view(),
    key_source: "none",
    key_hint: "",
    saved_key_set: false,
  }
  let missing_html = render_settings(missing).render()
  assert_true(missing_html.contains("no key"), msg=missing_html)
  assert_true(
    render_settings_trigger(missing).render().contains("data-attention"),
    msg="a missing key should mark the control",
  )
}

///|
/// The panel is a view of where the process actually put things, so the paths are shown exactly
/// as the process resolved them — a store with a `~` still in it would be a lie.
test "the panel reports the real paths and the real launch flags" {
  let html = render_settings(view()).render()
  assert_true(html.contains("/home/u/.pi-mb/sessions"), msg=html)
  assert_true(html.contains("127.0.0.1:8790"), msg=html)
  assert_true(html.contains("/work/proj"), msg=html)
  assert_true(html.contains("--model"), msg="the model says how to change it")
  assert_true(html.contains("--port"), msg=html)
  assert_true(html.contains("--store"), msg=html)
}
