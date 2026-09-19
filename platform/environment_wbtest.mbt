///|
/// Reading the login shell's answer, and what happens when there is none.
///
/// The two halves are worth testing for different reasons. Parsing is tested because the real
/// output has noise in it — `~/.zshrc` on this machine prints an error whose text contains
/// `PATH=`, and it goes to stderr, but a future rc file might write to stdout — and a parser that
/// took the wrong line would set a PATH the reader never had. Installation is tested because the
/// thing being relied on is not the value but the *propagation*: `set_env_var` is only useful if
/// a child process inherits it, and that is not something the source says.

///|
test "the marked line is the answer, whatever came before it" {
  // The clean shape the probe actually produces: a leading newline from `printf`, then the line.
  assert_eq(
    parse_probe_output("\n__wei_path__/Users/x/.moon/bin:/usr/bin\n"),
    Some("/Users/x/.moon/bin:/usr/bin"),
  )
  // rc noise on stdout, including a line that looks like an answer. Only the marker counts —
  // this is the case the marker exists for.
  assert_eq(
    parse_probe_output("nvm: loaded\nPATH=/wrong/bin\n__wei_path__/right/bin\n"),
    Some("/right/bin"),
  )
  // A shell that ran and printed nothing usable.
  assert_eq(parse_probe_output(""), None)
  assert_eq(parse_probe_output("\n\n"), None)
  // A shell whose startup file refused the assignment: marked, and empty. `Some("")` rather than
  // `None`, because "the shell says its PATH is empty" and "the shell said nothing" call for
  // different fallbacks.
  assert_eq(parse_probe_output("__wei_path__\n"), Some(""))
}

///|
test "when two lines are marked, the last one is the answer" {
  // The probe writes exactly one line, so anything marked earlier came from somewhere else. Last
  // wins is also what a shell does when a file is sourced twice, which is the rule a reader
  // already has in their head.
  assert_eq(
    parse_probe_output("__wei_path__/early\n__wei_path__/late\n"),
    Some("/late"),
  )
}

///|
test "the login PATH goes first and launchd's entries survive" {
  // The merge exists because neither list is a superset: the shell knows where the reader's tools
  // are, and the process was started with the system's own PATH.
  assert_eq(
    merge_paths("/Users/x/.moon/bin:/opt/homebrew/bin", "/usr/bin:/bin"),
    "/Users/x/.moon/bin:/opt/homebrew/bin:/usr/bin:/bin",
  )
  // Order matters and is the login shell's: the reader arranged their PATH, and a later entry
  // that shadows an earlier one would silently undo that arrangement.
  assert_eq(merge_paths("/a", "/b:/a"), "/a:/b")
  // Repeats dropped, on both sides.
  assert_eq(merge_paths("/a:/a:/b", "/b:/c:/c"), "/a:/b:/c")
  // Degenerate sides: each alone, and both empty.
  assert_eq(merge_paths("/a", ""), "/a")
  assert_eq(merge_paths("", "/a"), "/a")
  assert_eq(merge_paths("", ""), "")
  // Empties inside are dropped rather than carried: a doubled or trailing `:` means "the current
  // directory" to a shell, which is not something to hand the agent by accident.
  assert_eq(merge_paths(":/a:", "/b::"), "/a:/b")
}

///|
async test "installing a PATH is only useful because children inherit it" {
  // What the app does at startup, with the real login shell behind it. The assertion is not about
  // which directories came back — that is the reader's machine — but that the child agrees with
  // the parent, which is the property every tool the agent runs depends on.
  install_login_path()
  let parent = @env.get_env_var("PATH").unwrap_or("")
  let (code, out, _) = @process.collect_output("/bin/bash", [
    "-c", "printf %s \"$PATH\"",
  ])
  assert_eq(code, 0)
  assert_eq(out.text(), parent)
  // And non-empty, because a PATH of nothing would satisfy the line above while breaking every
  // command the agent runs.
  assert_true(parent != "")
}

///|
async test "a shell that cannot answer leaves the PATH no worse" {
  // A `SHELL` pointing at something that is not a shell, which is what an uninstalled shell
  // leaves behind in a saved environment. The call must return rather than throw, and the PATH
  // must still hold what the process already had.
  let before = @env.get_env_var("PATH").unwrap_or("")
  let saved = @env.get_env_var("SHELL")
  @env.set_env_var("SHELL", "/nonexistent/nope")
  install_login_path()
  match saved {
    Some(shell) => @env.set_env_var("SHELL", shell)
    None => @env.unset_env_var("SHELL")
  }
  let after = @env.get_env_var("PATH").unwrap_or("")
  // The fallback may add directories, so the claim is not equality — it is that nothing the
  // process already had was lost.
  for entry in path_entries(before) {
    assert_true(
      path_entries(after).contains(entry),
      msg="lost \{entry} from PATH",
    )
  }
}
