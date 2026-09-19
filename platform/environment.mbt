///|
/// Giving the agent's children the `PATH` the reader's terminal has.
///
/// An app started from Finder inherits launchd's environment, and launchd sets no `PATH` at all —
/// so the app's own `PATH` is the compiler default, `/usr/bin:/bin:/usr/sbin:/sbin`. Measured on
/// this machine: `launchctl getenv PATH` printed nothing, the running app's `PATH` was exactly
/// that default, and `moon` lives in `~/.moon/bin`. The result is the failure that is hardest to
/// explain to a reader: the command works in their terminal and fails in the agent, while the
/// tool descriptions promise the former.
///
/// The answer cannot be guessed — where a reader installs things is theirs — so it is asked for
/// instead: the login shell is run once, at startup, and told to print its own `PATH`. That answer
/// is installed into this process's environment, so everything the agent spawns afterwards
/// (`bash`, `script`, a test runner) inherits it.
///
/// Asked once because a shell reads its rc files at login: the reader who has just edited theirs
/// is starting a new session anyway.

///|
/// The marker the probe prints before the PATH.
///
/// rc files are free to print anything they like on startup, and on this machine one of them
/// prints an error whose text happens to contain `PATH=`. Reading "whatever followed `PATH=`,
/// or the last line" would take that fork. The marker makes the answer unambiguous: only the
/// text after the marker counts, and everything before it is noise by construction.
const PROBE_MARKER : String = "__wei_path__"

///|
/// How long the login shell gets to answer.
///
/// Generous, because the rc files that answer slowly are the ones worth waiting for — an `nvm` or
/// `conda` setup is tens of entries this app would otherwise not have. The measured cost on this
/// machine is ~28ms, so the limit is not the common path; it is the guard against an rc file that
/// waits on something, which would otherwise hold up startup.
let probe_timeout_ms : Int = 5000

///|
/// The command the probe runs in the login shell: one line holding the marker and the PATH.
///
/// `printf` rather than `echo`: the two shells disagree about whether `echo` interprets
/// backslashes, and `printf` is a builtin in both.
fn probe_command() -> String {
  "printf '\\n" + PROBE_MARKER + "%s\\n' \"$PATH\""
}

///|
/// The PATH a probe's stdout carries, or `None` when it carries none.
///
/// The last marked line wins. A marked line earlier in the output was not written by this probe
/// — the probe writes exactly one, and last — so taking the last is what keeps a reader's rc file
/// from being able to answer a question that was not addressed to it.
fn parse_probe_output(output : String) -> String? {
  let mut found : String? = None
  for line in output.split("\n") {
    match line.find(PROBE_MARKER) {
      Some(at) => found = Some(line[at + PROBE_MARKER.length():].to_owned())
      None => ()
    }
  }
  found
}

///|
/// The entries of a `PATH`, in order, without the empty ones.
///
/// An empty entry is a real thing in a `PATH` and means "the current directory"; it is dropped
/// because it is also what a trailing or doubled `:` produces, and a directory that is only
/// sometimes searched is worse than one that never is.
fn path_entries(text : String) -> Array[String] {
  let out : Array[String] = []
  for entry in text.split(":") {
    if entry != "" {
      out.push(entry.to_owned())
    }
  }
  out
}

///|
/// The login shell's entries first, then whatever this process already had that they do not cover.
///
/// A merge rather than a replacement, because the two lists answer different questions: the login
/// shell knows where the reader's tools are, and launchd knows what the system put on the PATH.
/// Neither is a superset — dropping the second would lose `/usr/bin`, which is how the agent
/// runs anything at all.
///
/// Repeats are dropped: a directory named twice in a `PATH` is a directory whose second copy can
/// never be reached, which reads as a bug the first time somebody tries to debug it.
fn merge_paths(login : String, current : String) -> String {
  let merged : Array[String] = []
  for entry in path_entries(login) {
    if !merged.contains(entry) {
      merged.push(entry)
    }
  }
  for entry in path_entries(current) {
    if !merged.contains(entry) {
      merged.push(entry)
    }
  }
  merged.join(":")
}

///|
/// Where tools are, when the login shell could not be asked.
///
/// A probe fails for reasons that are not the reader's fault — a shell whose startup files this
/// command is not written for, an rc file that ends the shell, a timeout. The fallback is short
/// and covers the installers this project's readers use, and the case that motivated the whole
/// thing (`moon`) is first.
fn fallback_entries() -> Array[String] {
  let entries : Array[String] = []
  match @env.get_env_var("HOME") {
    Some(home) if home != "" => {
      entries.push(home + "/.moon/bin")
      entries.push(home + "/.local/bin")
    }
    _ => ()
  }
  entries.push("/opt/homebrew/bin")
  entries.push("/usr/local/bin")
  entries
}

///|
/// Ask the login shell what its `PATH` is.
///
/// Only the shells this command is written for are asked. In `fish`, `$PATH` is a list and would
/// join with spaces rather than colons — an answer that is wrong rather than missing, which is the
/// one outcome worse than falling back.
async fn ask_login_shell() -> String? {
  let shell = match @env.get_env_var("SHELL") {
    Some(configured) if configured != "" => configured
    // What macOS ships and what the reader is using here; a guess that is only reached on a
    // machine that did not set `SHELL` at all.
    _ => "/bin/zsh"
  }
  match basename(shell) {
    "zsh" | "bash" => ()
    _ => return None
  }
  let attempt = () => {
    @process.collect_output(shell, ["-l", "-i", "-c", probe_command()])
  }
  // A shell that cannot be run at all — a `SHELL` pointing at something since uninstalled —
  // throws where one that ran and said nothing returns. Both mean "no answer".
  let outcome = try @async.with_timeout_opt(probe_timeout_ms, attempt) catch {
    _ => None
  } noraise {
    result => result
  }
  match outcome {
    // stderr is dropped rather than parsed: rc files write their own news there, and on this
    // machine they do.
    Some((_, out, _)) => parse_probe_output(out.text())
    None => None
  }
}

///|
/// Put the reader's `PATH` into this process, so the agent's children see their tools.
///
/// Called once, at startup, and never after: the environment it changes is process-wide, and a
/// change part-way through a session would mean two turns running the same command with two
/// different answers to "where is it".
pub async fn install_login_path() -> Unit {
  let current = match @env.get_env_var("PATH") {
    Some(path) => path
    None => ""
  }
  let resolved = match ask_login_shell() {
    Some(from_shell) => from_shell
    None => fallback_entries().join(":")
  }
  let merged = merge_paths(resolved, current)
  // Only when there is something to install: setting an empty `PATH` would be worse than
  // leaving whatever the process had.
  if merged != "" {
    @env.set_env_var("PATH", merged)
  }
}
