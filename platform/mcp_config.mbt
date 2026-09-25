///|
/// Reading `.mcp.json`.
///
/// The decisions — what an entry means, which of two same-named servers wins — are in
/// `core/mcp_config.mbt`; this file only knows where to look and how to read a file. The roots are
/// this project's own, global before project, so a project server can replace a global one of the
/// same name. That is `platform/skills.mbt`'s arrangement, on purpose: a reader who has learned
/// where one of these lives should not have to learn it twice.
///
/// The read is bounded, for the reason skill discovery is: the file is user-controlled, and a
/// reader who pointed a path at something enormous should not be able to turn opening a session
/// into a long read. A config is a handful of short entries; the ceiling is one nothing real
/// reaches.

///|
/// The config files searched for servers, outermost first.
///
/// Read in order and merged, so a project file adds to the reader's global one and overrides it by
/// name. `cwd` last for the same reason the skill roots put it last: the server nearest the work
/// being done is the one that should apply.
pub fn mcp_config_paths(cwd : String, home : String) -> Array[String] {
  [mcp_global_config_path(home), mcp_project_config_path(cwd)]
}

///|
/// The reader's own servers, whichever repository they are in.
pub fn mcp_global_config_path(home : String) -> String {
  "\{home}/.wei/mcp.json"
}

///|
/// The servers of the repository being worked in.
pub fn mcp_project_config_path(cwd : String) -> String {
  if cwd == "" || cwd == "/" {
    return ""
  }
  let trimmed = if cwd.has_suffix("/") {
    cwd[:cwd.length() - 1].to_owned()
  } else {
    cwd
  }
  "\{trimmed}/.mcp.json"
}

///|
/// How much of a config file will be read.
fn mcp_config_bytes() -> Int {
  262144
}

///|
/// Every configured server, merged global-then-project.
///
/// A missing or unreadable file is no servers rather than a failure, and an unparsable one is the
/// same: the file is a convenience, and a window that refused to open over it would be trading the
/// whole app for a feature. What does come back is ordered by name, and carries the unstartable
/// entries with their reasons, so the panel can show a reader what is idle and why.
pub async fn read_mcp_config(
  cwd : String,
  home : String,
) -> Array[@core.McpConfigEntry] {
  let layers : Array[Array[@core.McpConfigEntry]] = []
  for path in mcp_config_paths(cwd, home) {
    if path == "" {
      continue
    }
    let text = match read_config_text(path) {
      Some(text) => text
      // A file that is not there is the ordinary case: most repositories have no `.mcp.json`.
      None => continue
    }
    layers.push(@core.parse_mcp_config(text))
  }
  @core.merge_mcp_config(layers)
}

///|
/// A config file's text, or `None` when it cannot be read.
async fn read_config_text(path : String) -> String? {
  Some(read_prefix(path, mcp_config_bytes())) catch {
    _ => None
  }
}
