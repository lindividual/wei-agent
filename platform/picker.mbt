///|
/// The operating system's folder chooser.
///
/// The dialog is opened by the *host* process, because only the host has a desktop session and only
/// the host can hand back an absolute path. A browser cannot do this job: `showDirectoryPicker` gives
/// a sandboxed handle and `webkitdirectory` a relative name, and neither is the path the agent needs
/// to work in. So the browser asks the server, the server opens the dialog, and the answer arrives
/// as a patch like every other change.
///
/// The other half of that is what this cannot promise: a process with no desktop session — an SSH
/// login, a container, an OS whose chooser nobody has written yet — can open nothing. That is a
/// fact about the host rather than an error, so it is asked before the page is drawn and the picker
/// is simply left out.
///
/// Only macOS is implemented. `osascript` is one process, no bindings and no build step, which is
/// why it is the one: Windows would mean COM (`IFileOpenDialog`) and Linux a `zenity`/`kdialog`
/// command, and the useful half — the seam, the route, the fallback — is the same for all three.

///|
/// What came back from the dialog.
pub(all) enum FolderChoice {
  /// The reader picked this directory, absolute, without the trailing separator a chooser prints.
  Chosen(String)
  /// The reader closed the dialog. Not a failure, and worth saying nothing about.
  Cancelled
  /// No dialog could be opened, and why — ready to put on the status line.
  Unavailable(String)
} derive(Eq, Debug)

///|
/// Classify one run of the chooser.
///
/// Apart from `can_pick_directory`, this is the whole of the platform logic, and it is a pure
/// function so that a test can reach it: an assertion cannot click a dialog, but it can say what a
/// cancel looks like as opposed to a failure.
pub fn classify_folder_choice(
  code : Int,
  stdout : String,
  stderr : String,
) -> FolderChoice {
  if code != 0 {
    // `osascript` reports a closed dialog as an error, and "User canceled. (-128)" is the only part
    // of it that tells the reader changing their mind apart from the chooser being broken.
    if stderr.contains("-128") || stderr.contains("User canceled") {
      Cancelled
    } else {
      Unavailable(failure_text(stderr))
    }
  } else {
    // A chooser prints the path with its separator (`/Users/me/src/`), which would make the same
    // directory two workspaces. It comes off here rather than at the call site because
    // `canonical_dir` only resolves a directory that exists — the one path that does not resolve is
    // kept exactly as it arrived, separator and all.
    let path = stdout.trim().to_owned()
    if path.length() > 1 && path.has_suffix("/") {
      Chosen(path[:path.length() - 1].to_owned())
    } else if path == "" {
      Unavailable(failure_text(stderr))
    } else {
      Chosen(path)
    }
  }
}

///|
/// A failure to open the dialog, in one line.
fn failure_text(stderr : String) -> String {
  let detail = stderr.trim()
  if detail == "" {
    "the folder chooser failed"
  } else {
    "the folder chooser failed: \{detail}"
  }
}

///|
/// The chooser this build knows how to open.
///
/// A path rather than an OS test: `osascript` is where macOS keeps it, and asking whether the
/// binary is there is the same question as "is this a Mac" without inventing a way to ask the
/// system which one it is.
fn chooser_binary() -> String {
  "/usr/bin/osascript"
}

///|
/// Whether this process can put a folder chooser in front of the reader.
///
/// Two ways to be unable to. The dialog may not exist (only macOS is wired up, so anything else
/// answers here), or it may exist where the reader is not: under SSH the browser is on another
/// computer, and a chooser opened on the server's screen is a dialog nobody in the room can close.
/// Both are answered before the page offers a button, because a button that cannot work is worse
/// than a path field.
pub async fn can_pick_directory() -> Bool {
  if @env.get_env_var("SSH_CONNECTION") is Some(_) ||
    @env.get_env_var("SSH_TTY") is Some(_) {
    return false
  }
  is_file(chooser_binary())
}

///|
/// Open the system folder chooser.
///
/// Only meaningful when `can_pick_directory` said so, and it answers `Unavailable` rather than
/// raising when it did not: a chooser that could not be opened is something to say on the status
/// line, not a failure that ends a request.
///
/// `osascript` is a process, not a shell: the script is passed whole, so a folder name containing
/// spaces or quotes is never parsed by anything on the way.
pub async fn pick_directory() -> FolderChoice {
  if !can_pick_directory() {
    return Unavailable("no folder chooser on this host — type a path instead")
  }
  let attempt = () => {
    @process.collect_output(chooser_binary(), [
      "-e", "POSIX path of (choose folder with prompt \"Select a workspace directory\")",
    ])
  }
  // A chooser that will not start at all is the same answer as one that will not open: what the
  // reader needs is the reason, not an exception with no status line under it.
  try attempt() catch {
    err => Unavailable("the folder chooser failed: \{err}")
  } noraise {
    (code, out, err) => classify_folder_choice(code, text_of(out), text_of(err))
  }
}
