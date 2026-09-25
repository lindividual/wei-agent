///|
/// Where MCP servers come from, and what one means.
///
/// The format is `.mcp.json`'s — the one MCP clients converged on — so a file written for another
/// client works here unchanged. That is the same property `core/skill.mbt` gets by speaking
/// upstream's skill format, and it is why this is a parser and not a schema of our own.
///
/// Decoding is forgiving in one direction and explicit in the other. A file that does not parse, or
/// an entry that is not legible, leaves the rest of the file standing rather than failing the whole
/// thing: the file is a convenience, and refusing to start over it would trade a feature for the
/// program. But an entry that *is* legible and cannot be run — no `command`, or an HTTP transport
/// this client has no code for — is kept as `Unsupported` with the reason, because a configuration
/// the reader wrote that silently does nothing is the one outcome worse than an error message. The
/// window has somewhere to show it; nothing else here does.

///|
/// A server this client can start.
pub(all) struct McpStdioConfig {
  /// The key in the file. What a call names, and what the catalog lists.
  name : String
  command : String
  args : Array[String]
  /// The child's environment, on top of the one it inherits. Where a server's credentials go.
  env : Array[(String, String)]
  /// One line telling the model when this server is worth asking. Optional in the file, and
  /// optional here: the catalog renders a server without one.
  description : String
} derive(Eq, Debug)

///|
/// A server this client reaches over HTTP.
pub(all) struct McpHttpConfig {
  name : String
  url : String
  /// Headers sent with every request. Where a remote server's credentials go — an `Authorization`
  /// token, usually. Kept in the config file for the same reason a stdio server's variables are:
  /// the file the reader already has to edit is the one place a credential belongs.
  headers : Array[(String, String)]
  description : String
} derive(Eq, Debug)

///|
/// A server to bring up, whichever transport it speaks.
///
/// The two shapes are kept apart rather than flattened into one record with unused halves, because
/// they share nothing: a stdio server is a command and an environment, an HTTP one is a URL and
/// headers. A single record would make every caller check which fields are meaningful.
pub(all) enum McpConfig {
  Stdio(McpStdioConfig)
  Http(McpHttpConfig)
} derive(Eq, Debug)

///|
/// One entry of a config file, as this client can act on it.
pub(all) enum McpConfigEntry {
  /// A server to start and speak stdio to.
  Stdio(McpStdioConfig)
  /// A server to reach over HTTP.
  Http(McpHttpConfig)
  /// An entry that names neither a command nor a URL, with why. Named rather than dropped so the
  /// panel can show it and a reader is not left looking at a file they wrote that does nothing.
  Unsupported(name~ : String, reason~ : String)
} derive(Eq, Debug)

///|
/// The key a config file keeps its servers under. The name is the format's, not a choice here.
fn mcp_servers_key() -> String {
  "mcpServers"
}

///|
/// Read a config file.
///
/// Servers come back ordered by name, so two files that differ only in key order produce the same
/// catalog — and, since the catalog is in every request, the same request bytes.
pub fn parse_mcp_config(text : String) -> Array[McpConfigEntry] {
  let parsed = try @json.parse(text) catch {
    _ => return []
  } noraise {
    json => json
  }
  let servers = match parsed {
    Object(fields) =>
      match fields.get(mcp_servers_key()) {
        Some(Object(servers)) => servers
        // A file with no `mcpServers` is a file with no servers, not a malformed one: it may be
        // shared with a client whose format puts its servers somewhere else.
        _ => Map([])
      }
    _ => Map([])
  }
  let entries : Array[McpConfigEntry] = []
  for name, entry in servers {
    if name == "" {
      continue
    }
    entries.push(decode_entry(name, entry))
  }
  entries.sort_by((a, b) => compare_names(entry_name(a), entry_name(b)))
  entries
}

///|
/// A startable config's name, whichever transport it is.
pub fn config_name(config : McpConfig) -> String {
  match config {
    Stdio(config) => config.name
    Http(config) => config.name
  }
}

///|
/// The transport an entry is for, as the panel spells it. Empty for an entry that named neither.
pub fn config_transport(entry : McpConfigEntry) -> String {
  match entry {
    Stdio(_) => "stdio"
    Http(_) => "http"
    Unsupported(_) => ""
  }
}

///|
pub fn entry_name(entry : McpConfigEntry) -> String {
  match entry {
    Stdio(config) => config.name
    Http(config) => config.name
    Unsupported(name~, ..) => name
  }
}

///|
fn decode_entry(name : String, entry : Json) -> McpConfigEntry {
  // `command` first, so an entry that somehow has both is read as the stdio server it names: a
  // command is the more specific claim, and the more common shape by a wide margin.
  let command = arg_required_string(entry, "command").trim().to_owned()
  if command != "" {
    return Stdio({
      name,
      command,
      args: arg_strings(entry, "args"),
      env: decode_string_map(entry, "env"),
      description: arg_required_string(entry, "description"),
    })
  }
  let url = arg_required_string(entry, "url").trim().to_owned()
  if url != "" {
    return Http({
      name,
      url,
      headers: decode_string_map(entry, "headers"),
      description: arg_required_string(entry, "description"),
    })
  }
  // The one entry this client can do nothing with: no command to start, no URL to reach. Still a
  // value rather than a dropped one, so the panel can say a configured name is idle and why.
  Unsupported(
    name~,
    reason="names neither a `command` to start nor a `url` to reach — nothing here can be run",
  )
}

///|
/// A string-to-string map from a config field, sorted so that two configs that mean the same thing
/// compare equal — which is what lets a settings round-trip be asserted rather than eyeballed.
///
/// Used for both a stdio server's `env` and an HTTP server's `headers`: the two are the same shape
/// and the same problem, and one reader is what keeps them from drifting apart.
fn decode_string_map(entry : Json, key : String) -> Array[(String, String)] {
  let fields = match opt(entry, key) {
    Some(Object(fields)) => fields
    // Not an object at all: read as none rather than as an error, since a server given no variables
    // is the same server a server given an empty map is.
    _ => return []
  }
  let pairs : Array[(String, String)] = []
  for name, value in fields {
    match value {
      String(text) => pairs.push((name, text))
      // A number or a flag here is somebody typing `"PORT": 8080`. Both an environment and a set of
      // headers are strings and only strings, so the value is spelled the way the other end would
      // have to read it.
      _ => if value != Json::null() { pairs.push((name, value.stringify())) }
    }
  }
  pairs.sort_by((a, b) => compare_names(a.0, b.0))
  pairs
}

///|
/// Layered configs merged into one, later layers winning a name.
///
/// By name rather than by path, because that is the grain a reader thinks in: the project's
/// `github` entry should replace the one in their home directory, and they should not have to know
/// which file won. A name in the later layer that the earlier one does not have is simply added,
/// which is what makes a project file able to *add* a server without restating the global ones.
pub fn merge_mcp_config(
  layers : Array[Array[McpConfigEntry]],
) -> Array[McpConfigEntry] {
  let by_name : Map[String, McpConfigEntry] = Map([])
  for layer in layers {
    for entry in layer {
      by_name.set(entry_name(entry), entry)
    }
  }
  let out : Array[McpConfigEntry] = []
  for _, entry in by_name {
    out.push(entry)
  }
  out.sort_by((a, b) => compare_names(entry_name(a), entry_name(b)))
  out
}

///|
/// The startable servers of a set of entries, which is what a connection is built from. The
/// `Unsupported` ones are not errors to be raised here — they are the window's business, and
/// dropping them at this boundary is what keeps every caller that starts things from having to ask.
pub fn startable_servers(entries : Array[McpConfigEntry]) -> Array[McpConfig] {
  let out : Array[McpConfig] = []
  for entry in entries {
    match entry {
      Stdio(config) => out.push(Stdio(config))
      Http(config) => out.push(Http(config))
      Unsupported(_) => ()
    }
  }
  out
}
