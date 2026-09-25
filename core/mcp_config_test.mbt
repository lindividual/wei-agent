///|
/// Reading `.mcp.json`.
///
/// The fixtures are shaped like real files: a command with arguments and an environment, a remote
/// server with a URL and a header, and an entry with neither. The point of most of these is that the
/// last one is still a *named value* rather than a dropped line — a configured name that does nothing
/// is exactly what a reader needs to be told about.

///|
test "a stdio entry keeps its command, arguments, environment, and description" {
  let entries = parse_mcp_config(
    "{\"mcpServers\":{\"github\":{\"command\":\"npx\",\"args\":[\"-y\",\"@mcp/github\"],\"env\":{\"TOKEN\":\"t\",\"GITHUB_API_URL\":\"https://api.github.com\"},\"description\":\"Issues and pull requests.\"}}}",
  )
  assert_eq(entries.length(), 1)
  match entries[0] {
    Stdio(config) => {
      assert_eq(config.name, "github")
      assert_eq(config.command, "npx")
      assert_eq(config.args, ["-y", "@mcp/github"])
      // Sorted, so two files that mean the same thing compare equal.
      assert_eq(config.env, [
        ("GITHUB_API_URL", "https://api.github.com"),
        ("TOKEN", "t"),
      ])
      assert_eq(config.description, "Issues and pull requests.")
    }
    _ => fail("expected a stdio server")
  }
  assert_eq(config_transport(entries[0]), "stdio")
}

///|
test "an http entry keeps its url and its headers" {
  // The other transport, read the same way. The headers are where a remote server's credential goes,
  // which is why they are kept and not dropped: a URL with no token reaches a server that answers 401.
  let entries = parse_mcp_config(
    "{\"mcpServers\":{\"linear\":{\"type\":\"http\",\"url\":\"https://mcp.linear.app/mcp\",\"headers\":{\"Authorization\":\"Bearer lin_x\"},\"description\":\"Issues and projects.\"}}}",
  )
  match entries[0] {
    Http(config) => {
      assert_eq(config.name, "linear")
      assert_eq(config.url, "https://mcp.linear.app/mcp")
      assert_eq(config.headers, [("Authorization", "Bearer lin_x")])
      assert_eq(config.description, "Issues and projects.")
    }
    _ => fail("expected an http server")
  }
  assert_eq(config_transport(entries[0]), "http")
}

///|
test "a command wins when an entry somehow has both" {
  // A command is the more specific claim and the more common shape, so an entry with a `url` as well
  // is read as the stdio server it names rather than rejected.
  let entries = parse_mcp_config(
    "{\"mcpServers\":{\"both\":{\"command\":\"x\",\"url\":\"https://e/mcp\"}}}",
  )
  match entries[0] {
    Stdio(config) => assert_eq(config.command, "x")
    _ => fail("expected the command to win")
  }
}

///|
test "an entry with neither a command nor a url says what it is missing" {
  let entries = parse_mcp_config("{\"mcpServers\":{\"broken\":{\"args\":[]}}}")
  match entries[0] {
    Unsupported(name~, reason~) => {
      assert_eq(name, "broken")
      assert_true(reason.contains("`command`"), msg=reason)
      assert_true(reason.contains("`url`"), msg=reason)
    }
    _ => fail("expected an unsupported entry")
  }
  assert_eq(config_transport(entries[0]), "")
}

///|
test "a non-string environment or header value is spelled the way the other end would read it" {
  // `"PORT": 8080` is a person typing a number. Both an environment and a set of headers are strings,
  // so the value is turned into the string the other end would have to parse anyway.
  let stdio = parse_mcp_config(
    "{\"mcpServers\":{\"s\":{\"command\":\"x\",\"env\":{\"PORT\":8080,\"DEBUG\":true,\"EMPTY\":null}}}}",
  )
  match stdio[0] {
    Stdio(config) =>
      assert_eq(config.env, [("DEBUG", "true"), ("PORT", "8080")])
    _ => fail("expected a stdio server")
  }
  let http = parse_mcp_config(
    "{\"mcpServers\":{\"h\":{\"url\":\"https://e/mcp\",\"headers\":{\"X-Retries\":3}}}}",
  )
  match http[0] {
    Http(config) => assert_eq(config.headers, [("X-Retries", "3")])
    _ => fail("expected an http server")
  }
}

///|
test "a file that is not legible is no servers, not a failure" {
  // The file is a convenience: a window that refused to open over it would trade the whole app for
  // a feature.
  assert_eq(parse_mcp_config("not json"), [])
  assert_eq(parse_mcp_config("[1,2,3]"), [])
  // And a file with no `mcpServers` key may simply be shared with a client whose format puts its
  // servers somewhere else.
  assert_eq(parse_mcp_config("{\"servers\":{}}"), [])
}

///|
test "a nameless entry is dropped" {
  let entries = parse_mcp_config("{\"mcpServers\":{\"\":{\"command\":\"x\"}}}")
  assert_eq(entries.length(), 0)
}

///|
test "entries come back ordered by name" {
  let entries = parse_mcp_config(
    "{\"mcpServers\":{\"zeta\":{\"command\":\"z\"},\"alpha\":{\"command\":\"a\"}}}",
  )
  assert_eq(entries.map(entry_name), ["alpha", "zeta"])
}

///|
test "a later layer wins a name and adds the rest" {
  // By name, because that is the grain a reader thinks in: a project's `github` should replace the
  // one in their home directory without them having to know which file won — and adding a project
  // server should not mean restating the global ones.
  let global = parse_mcp_config(
    "{\"mcpServers\":{\"github\":{\"command\":\"global-gh\"},\"linear\":{\"command\":\"linear\"}}}",
  )
  let project = parse_mcp_config(
    "{\"mcpServers\":{\"github\":{\"command\":\"project-gh\"}}}",
  )
  let merged = merge_mcp_config([global, project])
  assert_eq(merged.map(entry_name), ["github", "linear"])
  match merged[0] {
    Stdio(config) => assert_eq(config.command, "project-gh")
    _ => fail("expected a stdio server")
  }
}

///|
test "startable servers keep both transports and drop the unstartable ones" {
  // Dropping the rest at this boundary is what keeps a caller that starts things from having to ask:
  // the unstartable entries are the panel's business, not a connection's.
  let entries = parse_mcp_config(
    "{\"mcpServers\":{\"ok\":{\"command\":\"x\"},\"remote\":{\"url\":\"https://e/mcp\"},\"broken\":{}}}",
  )
  let startable = startable_servers(entries)
  assert_eq(startable.map(config_name), ["ok", "remote"])
  // Entries are sorted by name, so the unstartable one is first.
  assert_eq(entries.map(entry_name), ["broken", "ok", "remote"])
  assert_eq(config_transport(entries[0]), "")
}

///|
test "a missing config file reads as no servers" {
  // `read_mcp_config` is the platform half; what is checkable without a filesystem is that a path
  // with nothing behind it contributes nothing.
  assert_eq(parse_mcp_config(""), [])
  assert_eq(merge_mcp_config([]), [])
}
