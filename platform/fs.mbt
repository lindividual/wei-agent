///|
/// Filesystem access for the tools.
///
/// Everything here is a thin wrapper: the point is to keep `core/` free of IO so
/// its logic compiles and tests everywhere, not to abstract the filesystem into
/// something richer.

///|
pub async fn read_text(path : String) -> String {
  @fs.read_file(path).text()
}

///|
pub async fn write_text(path : String, content : String) -> Unit {
  @fs.write_file(path, content)
}

///|
pub async fn path_exists(path : String) -> Bool {
  @fs.exists(path)
}

///|
/// Whether the path is a directory.
///
/// Opening it is the only reliable test, and opening a file fails — so a failure
/// is the answer, not an error. Raising here would make every caller handle a
/// question it only asked to get a boolean back.
pub async fn is_directory(path : String) -> Bool {
  try {
    let dir = @fs.opendir(path)
    dir.close()
    true
  } catch {
    _ => false
  } noraise {
    result => result
  }
}

///|
/// Create a directory and any missing parents.
///
/// Failing because the directory already appeared is not a failure: concurrent
/// callers can both find it missing and both try to create it. Only a directory
/// that still does not exist afterwards is an error.
pub async fn make_dirs(path : String) -> Unit {
  if path == "" || path == "/" || @fs.exists(path) {
    return
  }
  try @fs.mkdir(path, recursive=true) catch {
    _ =>
      if !@fs.exists(path) {
        raise Failure::Failure("could not create directory: \{path}")
      }
  } noraise {
    _ => ()
  }
}

///|
/// Entry names in a directory, unsorted.
pub async fn list_entries(path : String) -> Array[String] {
  @fs.readdir(path)
}

///|
/// Directories and files under a root, as paths relative to it.
///
/// Walks in a single task so the order is deterministic: a tool result that
/// reorders itself between runs is impossible to test.
pub async fn walk_paths(root : String, max_entries : Int) -> Array[String] {
  let out : Array[String] = []
  let dirs : Array[String] = [root]
  while !dirs.is_empty() && out.length() < max_entries {
    let dir = dirs.remove(0)
    let names = @fs.readdir(dir)
    for name in names {
      if out.length() >= max_entries {
        break
      }
      let full = if dir == "/" || dir == "" {
        "\{dir}\{name}"
      } else {
        "\{dir}/\{name}"
      }
      if is_directory(full) {
        dirs.push(full)
      } else {
        out.push(full)
      }
    }
  }
  out
}

///|
/// The platform's environment, as a map for the process layer.
pub fn current_dir() -> String {
  match @env.current_dir() {
    Some(dir) => dir
    None => "/"
  }
}
