///|
/// Finding skills on disk.
///
/// The decisions — what a header means, which of two same-named skills wins — are in
/// `core/skill.mbt`; this file only knows where to look and how to read a file. The roots are
/// this project's own, global before project, so a project skill can shadow a global one of the
/// same name.
///
/// Discovery is bounded twice, because a scanned root is user-controlled: at most
/// `skill_scan_limit()` instruction files are read, and each read takes only a prefix. A
/// `SKILL.md` is a header followed by prose, so a prefix is all the header needs, and a root
/// containing thousands of markdown files cannot turn opening a session into a long walk.

///|
/// How many instruction files one scan will read.
///
/// Generous for a person's skill collection (twelve here) and small enough that a mistaken
/// root — a home directory, a checked-out monorepo — cannot stall startup.
pub fn skill_scan_limit() -> Int {
  500
}

///|
/// How much of a file to read to find its header.
///
/// A description is one line, so the header is small; the cap is for the pathological file
/// whose first line never ends.
fn skill_header_bytes() -> Int {
  16384
}

///|
/// The directories searched for skills, outermost first.
///
/// `home` is passed rather than read here so the order is testable without an environment.
/// The `cwd` entries come last so they win: the skill nearest the work being done is the one
/// that should apply, which is the opposite of how a path lookup usually reads but is what
/// makes a project able to override a global skill.
pub fn skill_roots(cwd : String, home : String) -> Array[String] {
  let roots : Array[String] = ["\{home}/.wei/skills", "\{home}/.agents/skills"]
  if cwd != "" {
    let mut dir = cwd
    // Every ancestor, not just the workspace root: a skill committed at the repository root
    // applies in every subdirectory of that repository.
    while dir != "" && dir != "/" {
      roots.push("\{dir}/.wei/skills")
      roots.push("\{dir}/.agents/skills")
      let parent = @core.parent_of(dir)
      if parent == dir {
        break
      }
      dir = parent
    }
  }
  roots
}

///|
/// Every skill reachable from `cwd`, in discovery order.
///
/// A root that does not exist, or a file that cannot be read, is skipped rather than reported:
/// a skill directory is optional by nature, and a scan that failed on a missing `~/.agents`
/// would make the feature unusable on most machines. The caller deduplicates.
pub async fn discover_skills(cwd : String, home : String) -> Array[@core.Skill] {
  let found : Array[@core.Skill] = []
  let mut read = 0
  for root in skill_roots(cwd, home) {
    if read >= skill_scan_limit() {
      break
    }
    let names = match read_dir(root) {
      Some(names) => names
      None => continue
    }
    for name in names {
      if read >= skill_scan_limit() {
        break
      }
      if name.has_prefix(".") {
        continue
      }
      let path = "\{root}/\{name}"
      // A directory bundle is `<name>/SKILL.md`; a flat skill is `<name>.md`. Only one level
      // deep, deliberately — a nested `**/SKILL.md` is a reference document, not a skill
      // someone meant to offer. Whether `<name>` is a directory is the only thing that decides
      // which path is tried; a failed read is a skip either way, so no separate existence
      // check stands between the two.
      let header = if is_directory(path) {
        "\{path}/SKILL.md"
      } else if name.has_suffix(".md") {
        path
      } else {
        ""
      }
      if header == "" {
        continue
      }
      match read_skill_at(header) {
        Some(skill) => {
          found.push(skill)
          read = read + 1
        }
        None => ()
      }
    }
  }
  found
}

///|
/// Entry names in a directory, or `None` when it cannot be read.
///
/// A missing root is the normal case, not an error: most machines have no `~/.agents/skills`,
/// and a scan that reported it would make the feature look broken on a fresh checkout.
async fn read_dir(path : String) -> Array[String]? {
  Some(@fs.readdir(path)) catch {
    _ => None
  }
}

///|
/// Read one instruction file and parse its header, or `None`.
async fn read_skill_at(path : String) -> @core.Skill? {
  let text = match read_header_text(path) {
    Some(text) => text
    None => return None
  }
  @core.parse_skill_header(text, path)
}

///|
/// The first `skill_header_bytes()` of a file, or `None` when it cannot be read.
async fn read_header_text(path : String) -> String? {
  Some(read_prefix(path, skill_header_bytes())) catch {
    _ => None
  }
}

///|
/// How much of a skill's body will be read.
///
/// Bounded for the same reason the scan is: the path came from a skill file, which came from a
/// directory a reader controls. A skill is instructions, and instructions of a quarter of a
/// megabyte are not instructions. The cap is generous next to a real one (a few kilobytes) and
/// small enough that a mistaken file cannot spend a turn's whole context on itself.
fn skill_body_bytes() -> Int {
  262144
}

///|
/// A skill's instruction file, with its frontmatter removed, or `None` when it cannot be read.
///
/// The whole file this time, not the header prefix the scan reads: naming a skill explicitly is
/// asking for its instructions, and the header is the one part that is not them.
///
/// A read failure is `None` rather than an error. The file can vanish between the scan and the
/// invocation — the reader is in a terminal deleting things while the page is open — and the
/// useful answer there is "that skill has no file now", on the status line, rather than a failed
/// request.
async fn read_skill_body(skill : @core.Skill) -> String? {
  let text = match read_text_or_none_prefix(skill.path) {
    Some(text) => text
    None => return None
  }
  Some(@core.strip_skill_frontmatter(text))
}

///|
/// The first `skill_body_bytes()` of a file, or `None` when it cannot be read.
///
/// `read_prefix` never raises — a missing file reads as empty — so the `None` here is about the
/// file being *there*: an empty read means the skill's file is gone, and expanding it to an empty
/// block would tell the model a skill exists and says nothing.
async fn read_text_or_none_prefix(path : String) -> String? {
  if !path_exists(path) {
    return None
  }
  Some(read_prefix(path, skill_body_bytes()))
}

///|
/// Expand a `/skill:<name>` command into the block the model reads, or `None` when the name
/// matches no discovered skill.
///
/// The caller decides what an unknown name means; this only does the reading and the framing, so
/// the two are testable apart.
pub async fn expand_skill_command(
  skills : Array[@core.Skill],
  name : String,
  args : String,
) -> String? {
  let mut found : @core.Skill? = None
  for skill in @core.dedup_skills(skills) {
    if skill.name == name {
      found = Some(skill)
    }
  }
  let skill = match found {
    Some(skill) => skill
    None => return None
  }
  let body = match read_skill_body(skill) {
    Some(body) => body
    None => return None
  }
  Some(@core.skill_expansion(skill, body, args))
}
