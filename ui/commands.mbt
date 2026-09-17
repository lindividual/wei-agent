///|
/// What the text in the composer means.
///
/// Two entry points, and the split between them is the point. `parse_command` is pure: it recognises
/// the commands whose syntax cannot collide with prose, and answers `None` for everything else so
/// that a path, a division or a regex is not swallowed. `expand_skill_command` reads a file, because
/// `/skill:<name>` asks for a skill's body rather than merely naming it.
///
/// Both answer `None` for "not mine", and both callers send the text to the model unchanged in that
/// case. That is deliberate for the second one too: an unknown skill name passes through rather than
/// being refused, so a mistyped skill cannot eat a message.

///|
/// What the composer understands as a command rather than a message.
pub(all) enum Command {
  /// `/name <text>` sets the session's name; `/name` alone reports the current one.
  Name(String)
  /// `/model <id>` switches this session's model; `/model` alone reports the current one.
  Model(String)
} derive(Eq, Debug)

///|
/// Read a command out of what the reader typed, or `None` for a message.
///
/// Only commands with a namespace that cannot collide with prose are intercepted: `/name`, and
/// `/model`. Treating every `/x` as a command would silently swallow messages that happen to start
/// with a slash — a path, a division, a regex — so anything else is left alone and goes to the
/// model. `/skill:` is handled separately, in `core`, because expanding one reads a file.
pub fn parse_command(text : String) -> Command? {
  let trimmed = text.trim()
  if trimmed == "/name" {
    // Without an argument it reports rather than clears: a bare command should not be able to
    // throw away something the reader typed earlier.
    return Some(Name(""))
  }
  if trimmed.has_prefix("/name ") {
    return Some(Name(trimmed[6:].trim().to_owned()))
  }
  if trimmed == "/model" {
    return Some(Model(""))
  }
  if trimmed.has_prefix("/model ") {
    return Some(Model(trimmed[7:].trim().to_owned()))
  }
  None
}

///|
/// What the composer offers when the reader opens a command.
///
/// The commands are answered in `parse_command`, which is pure and knows nothing about a session;
/// this is the other half — the same three things, spelled for someone who has not read the source
/// and cannot see that `/skill:` exists at all until a skill is named somewhere.
///
/// Each insert ends in a space where an argument is expected, so the reader lands where the
/// argument goes rather than having to add the space themselves.
/// `skills_for` rather than `discovered_skills`: a skill that is switched off is not something the
/// reader can invoke, so offering it would be offering a command that does nothing. It is the same
/// filter the catalog and the panel use, which is what keeps the three from disagreeing about what
/// is on.
fn command_hints(app : App, shown : Runner) -> Array[@html.CommandHint] {
  let hints : Array[@html.CommandHint] = [
    { insert: "/name ", what: "name this session", },
    { insert: "/model ", what: "switch the model", },
  ]
  for skill in app.skills_for(shown.cwd) {
    hints.push({ insert: "/skill:\{skill.name} ", what: skill.description, })
  }
  hints
}

///|
/// Expand a `/skill:<name>` command, or `None` when the text is not one or names nothing.
///
/// The scan is by `cwd` because skills are per working directory, and a session that moved to
/// another repository must see that repository's skills — the same reason the catalog is keyed
/// that way. `None` covers three cases the caller treats identically (send the text as-is): not a
/// skill command, no such name, and a file that has since been deleted. The first is upstream's
/// behaviour; the other two are that behaviour applied to the two ways a name can stop resolving,
/// and passing the text through is better than either silence or an error, because a reader who
/// typed a message beginning with `/skill:` may well have meant it literally.
async fn expand_skill_command(
  app : App,
  shown : Runner,
  text : String,
) -> String? {
  if @core.is_skill_list_command(text) {
    return None
  }
  let (name, args) = match @core.skill_command_parts(text) {
    Some(parts) => parts
    None => return None
  }
  app.load_skills(shown.cwd)
  @platform.expand_skill_command(app.discovered_skills(shown.cwd), name, args)
}
