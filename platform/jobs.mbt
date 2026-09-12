///|
/// Running a command as something that can outlive its tool call.
///
/// The mechanism is the process table, and that is a consequence of the runtime rather than a
/// preference. Children here inherit our own process group — measured, not assumed: a group kill
/// would take the server down with them — and MoonBit's async runtime offers no `setsid` and no
/// way to signal an arbitrary pid. dsh reaches for user-systemd scopes on Linux and a Windows Job
/// object for the same reason, falls back to a detached process group on macOS, and says plainly
/// that descendants which escape that group may not be reclaimable.
///
/// So this does two portable things instead. The command runs with its own process table dumped
/// by the shell *before it exits* — the last moment a backgrounded child is still attached to it —
/// and every pid seen is recorded, because reparenting does not change a pid. `kill` then works
/// per pid through `/bin/kill`, which is a process like any other.

///|
/// What a command left behind.
pub(all) struct ExecOutcome {
  result : @core.ExecResult
  /// The shell's process id. Gone by the time this is returned, unless it timed out.
  shell_pid : Int
  /// Every pid that was in the shell's tree while it ran, the shell excluded.
  children : Array[Int]
  /// The ones still alive once the shell exited. Non-empty means the command left work
  /// running, which is the case this whole file exists for.
  lingering : Array[Int]
} derive(Debug)

///|
/// A directory for the process-table dumps, under the system's temporary directory.
fn tree_dir() -> String {
  match @env.get_env_var("TMPDIR") {
    Some(dir) if dir != "" => "\{dir}/pi-web-shell"
    _ => "/tmp/pi-web-shell"
  }
}

///|
/// The pids in a process table that descend from `root`, excluding `root` itself.
///
/// Walks the parent links rather than assuming a depth: `npm run dev &` is one level down,
/// `npm run dev &` whose script spawns a compiler is two.
pub fn subtree(table : Array[(Int, Int)], root : Int) -> Array[Int] {
  let out : Array[Int] = []
  // Repeated passes rather than a queue: a process table is small, and the loop is bounded by
  // the depth of the tree.
  let mut growing = true
  while growing {
    growing = false
    for entry in table {
      let (pid, parent) = entry
      if pid == root {
        continue
      }
      let mut known = false
      for existing in out {
        if existing == pid {
          known = true
        }
      }
      if known {
        continue
      }
      let mut related = parent == root
      if !related {
        for existing in out {
          if parent == existing {
            related = true
          }
        }
      }
      if related {
        out.push(pid)
        growing = true
      }
    }
  }
  out
}

///|
/// Parse `ps -eo pid=,ppid=` output: two columns per line, whitespace separated.
pub fn parse_table(text : String) -> Array[(Int, Int)] {
  let out : Array[(Int, Int)] = []
  for raw in text.split("\n") {
    let line = raw.trim()
    if line.is_empty() {
      continue
    }
    let numbers = digits_of(line)
    // A line with anything other than two numbers is not a process entry; skipping it keeps a
    // surprising `ps` from turning into a wrong answer.
    match numbers {
      [pid, parent, ..] => out.push((pid, parent))
      _ => ()
    }
  }
  out
}

///|
/// The leading integers of a line, left to right.
fn digits_of(line : StringView) -> Array[Int] {
  let out : Array[Int] = []
  let mut current = -1
  let mut started = false
  for c in line {
    if c >= '0' && c <= '9' {
      let digit = c.to_int() - '0'.to_int()
      current = if started { current * 10 + digit } else { digit }
      started = true
    } else if started {
      out.push(current)
      current = -1
      started = false
    }
  }
  if started {
    out.push(current)
  }
  out
}

///|
/// Whether a pid is still alive.
///
/// `kill -0` rather than `ps -p`: it answers the question directly, needs no parsing, and a
/// process owned by another user answers with `EPERM`, which still means alive.
pub async fn pid_alive(pid : Int) -> Bool {
  if pid <= 0 {
    return false
  }
  let (code, _, _) = @process.collect_output("/bin/kill", ["-0", "\{pid}"])
  code == 0
}

///|
/// Ask a pid to stop, then insist.
///
/// `SIGTERM` first, because a process holding a port or a lock should get the chance to release
/// it, then `SIGKILL` after the grace. The grace is the same order of magnitude as the runtime's
/// own process cancellation, so a stop through this path and a stop through cancellation behave
/// alike.
pub async fn kill_pid(pid : Int, grace_ms? : Int = 3000) -> Unit {
  if pid <= 0 || !pid_alive(pid) {
    return
  }
  ignore(@process.collect_output("/bin/kill", ["-TERM", "\{pid}"]))
  let mut waited = 0
  while waited < grace_ms && pid_alive(pid) {
    @async.sleep(100)
    waited += 100
  }
  if pid_alive(pid) {
    ignore(@process.collect_output("/bin/kill", ["-KILL", "\{pid}"]))
  }
}

///|
/// Stop every pid in a job, in the order recorded, and report how many were still alive.
pub async fn kill_pids(pids : Array[Int]) -> Int {
  let mut killed = 0
  for pid in pids {
    if pid_alive(pid) {
      kill_pid(pid)
      killed += 1
    }
  }
  killed
}

///|
/// Run a command, and find out what it left running.
///
/// `on_shell_pid` is called as soon as the shell exists, so a caller that is asked to stop
/// meanwhile has something to signal. `sampled` is called with the current tree whenever the
/// sampler looks, and its last value is what is used if the shell never reports its own table —
/// which is what happens when the command is killed rather than finishing.
pub async fn exec_managed(
  command : String,
  cwd~ : String,
  timeout_ms? : Int,
  on_shell_pid? : (Int) -> Unit,
  on_sample? : (Array[Int]) -> Unit,
) -> ExecOutcome {
  try @fs.mkdir(tree_dir(), recursive=true) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  let stamp = @core.new_entry_id()
  let tree_file = "\{tree_dir()}/tree-\{stamp}.txt"
  let out_file = "\{tree_dir()}/out-\{stamp}.txt"
  let err_file = "\{tree_dir()}/err-\{stamp}.txt"
  // The command's own exit status has to survive the extra step, and the dump has to happen even
  // when the command fails — so neither `set -e` nor the last command's status is relied on.
  let wrapped = "\{command}\n__pws_status=$?\n/bin/ps -eo pid=,ppid= > '\{tree_file}' 2>/dev/null\nexit $__pws_status\n"
  let mut shell_pid = 0
  let mut exit_code = -1
  let mut sampled : Array[Int] = []
  let attempt = () => {
    @async.with_task_group(group => {
      // Output goes to files rather than pipes, and that is not an optimisation. A pipe is held
      // open by *every* process that inherited it, so a backgrounded child keeps the read end
      // from reaching EOF: reading a pipe would make `sleep 60 &` block the tool call for a
      // minute, which is exactly what backgrounding was for. Files have no such coupling, and
      // the child may keep writing to them without anything waiting on it.
      let proc = @process.spawn(
        group,
        "/bin/bash",
        ["-c", wrapped],
        cwd~,
        stdout=@process.redirect_to_file(out_file),
        stderr=@process.redirect_to_file(err_file),
        cancel_handler=@process.graceful_cancel(timeout=3000),
      )
      shell_pid = proc.pid
      match on_shell_pid {
        Some(report) => report(proc.pid)
        None => ()
      }
      // The sampler covers what the shell's own dump cannot: a command that is killed, or that
      // calls `exit` before the dump runs. It backs off, so an hour-long command costs a handful
      // of `ps` calls rather than thousands.
      let sampler = group.spawn(
        () => {
          let mut wait = 300
          let mut rounds = 0
          while rounds < 5 && proc.try_wait() is None {
            @async.sleep(wait)
            let tree = subtree(process_table(), proc.pid)
            if !tree.is_empty() {
              sampled = tree
              match on_sample {
                Some(report) => report(tree)
                None => ()
              }
            }
            wait = wait * 3
            rounds += 1
          }
        },
        no_wait=true,
      )
      ignore(sampler)
      exit_code = proc.wait()
    })
  }
  let timed_out = match timeout_ms {
    None => {
      ignore(attempt())
      false
    }
    Some(limit) =>
      match @async.with_timeout_opt(limit, attempt) {
        Some(_) => false
        // Timed out: the shell has been cancelled and killed by the runtime. Whatever the last
        // sample saw is what still has to be cleaned up.
        None => true
      }
  }
  let stdout = if path_exists(out_file) { read_text(out_file) } else { "" }
  let stderr = if path_exists(err_file) { read_text(err_file) } else { "" }
  // The shell's own dump is the authoritative list: it was taken while everything the command
  // started was still attached to it.
  let dumped = if path_exists(tree_file) {
    parse_table(read_text(tree_file))
  } else {
    []
  }
  for path in [tree_file, out_file, err_file] {
    try @fs.remove(path) catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
  let children = if dumped.is_empty() {
    sampled
  } else {
    subtree(dumped, shell_pid)
  }
  {
    result: {
      stdout,
      stderr,
      exit_code: if timed_out {
        -1
      } else {
        exit_code
      },
      timed_out,
    },
    shell_pid,
    children,
    lingering: live_of(children),
  }
}

///|
/// The whole process table as (pid, parent) pairs.
pub async fn process_table() -> Array[(Int, Int)] {
  let (_, out, _) = @process.collect_output("/bin/ps", ["-eo", "pid=,ppid="])
  parse_table(@utf8.decode_lossy(out.binary()))
}

///|
/// The pids out of a list that are still alive.
pub async fn live_of(pids : Array[Int]) -> Array[Int] {
  let out : Array[Int] = []
  for pid in pids {
    if pid_alive(pid) {
      out.push(pid)
    }
  }
  out
}
