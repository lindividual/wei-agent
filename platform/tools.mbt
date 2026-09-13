///|
/// The tool bodies.
///
/// Everything that touches the world lives here. The decisions — what to keep,
/// how to format, whether an edit is unambiguous — are in `core/`, because those
/// are the parts worth testing without a filesystem.

///|
/// Resolve a tool's path argument against the working directory.
///
/// Absolute paths pass through. Relative ones are joined, which is what the tool
/// descriptions promise ("relative or absolute").
pub fn resolve_path(cwd : String, path : String) -> String {
  if path.has_prefix("/") {
    return path
  }
  if cwd.has_suffix("/") {
    "\{cwd}\{path}"
  } else {
    "\{cwd}/\{path}"
  }
}

///|
fn split_lines(text : String) -> Array[String] {
  let raw : Array[String] = []
  for line in text.split("\n") {
    raw.push(line.to_owned())
  }
  if raw.length() > 0 && raw[raw.length() - 1] == "" {
    raw[:raw.length() - 1].to_owned()
  } else {
    raw
  }
}

///|
/// Run one tool call.
pub async fn execute_tool(
  name : String,
  arguments : Json,
  cwd : String,
  /// Only `bash` reports one: what it started, and what is still running when it returned.
  watcher? : ExecWatcher,
) -> @core.ToolOutput {
  match name {
    "bash" => run_bash(arguments, cwd, watcher?)
    "read" => run_read(arguments, cwd)
    "write" => run_write(arguments, cwd)
    "edit" => run_edit(arguments, cwd)
    "glob" => run_glob(arguments, cwd)
    "grep" => run_grep(arguments, cwd)
    // Recording a note is the driver's job: it writes what the tool returns.
    "note" =>
      @core.ToolOutput::text("Note recorded.").with_details(
        Json::object(
          Map([
            ("note", Json::string(@core.arg_required_string(arguments, "text"))),
          ]),
        ),
      )
    other => @core.ToolOutput::error("Unknown tool: \{other}")
  }
}

// ── bash ───────────────────────────────────────────────────────────────────

///|
/// What the tool layer tells its caller about a command it ran.
///
/// Two moments rather than one because they answer different needs: the pids as they are
/// discovered are what a stop has to signal, and the final outcome is what a record has to say.
pub(all) struct ExecWatcher {
  /// Pids seen in the command's process tree, as they are found.
  started : (Array[Int]) -> Unit
  /// The command returned (or timed out): what it left behind.
  finished : (ExecOutcome) -> Unit
}

///|
async fn run_bash(
  arguments : Json,
  cwd : String,
  watcher? : ExecWatcher,
) -> @core.ToolOutput {
  let command = @core.arg_required_string(arguments, "command")
  if command.trim() == "" {
    return @core.ToolOutput::error("The command is empty.")
  }
  // The schema says seconds; the platform wants milliseconds.
  let timeout = match @core.arg_int(arguments, "timeout") {
    Some(seconds) if seconds > 0 => Some(seconds * 1000)
    _ => None
  }
  let mut lingering : Array[Int] = []
  let outcome = exec_managed(
    command,
    cwd~,
    timeout_ms?=timeout,
    on_shell_pid=pid => {
      match watcher {
        Some(watch) => (watch.started)([pid])
        None => ()
      }
    },
    on_sample=pids => {
      match watcher {
        Some(watch) => (watch.started)(pids)
        None => ()
      }
    },
  )
  match watcher {
    Some(watch) => (watch.finished)(outcome)
    None => ()
  }
  lingering = outcome.lingering
  let formatted = @core.format_exec_result(outcome.result, cwd)
  if lingering.is_empty() {
    return formatted
  }
  // Said in the tool result as well as in the panel: a command that returned while its work
  // continues is invisible to the model otherwise, and the model is who decided to background it.
  // `Text` alone is ambiguous with `StreamEvent::Text`, hence the qualified form.
  let note : @core.Content = @core.Content::Text(
    "\n\n[this command left \{lingering.length()} process(es) running (pid \{pids_text(lingering)}). They keep running until stopped, and are listed in the sidebar under Background.]",
  )
  let content : Array[@core.Content] = []
  for block in formatted.content {
    content.push(block)
  }
  content.push(note)
  { content, is_error: formatted.is_error, details: formatted.details, }
}

///|
fn pids_text(pids : Array[Int]) -> String {
  let out = StringBuilder()
  for pid in pids {
    if out.to_string() != "" {
      out.write_string(", ")
    }
    out.write_string("\{pid}")
  }
  out.to_string()
}

// ── read ───────────────────────────────────────────────────────────────────

///|
/// The largest image the read tool will carry, in bytes.
///
/// The base64 that goes on the wire is a third larger than the file, and this build has no way to
/// shrink a picture — resizing needs an image library, and the alternative to refusing is a request
/// body that grows until the provider rejects it. Four mebibytes is comfortably above a screenshot
/// (a full-screen PNG of a dense page is a few hundred kilobytes) and comfortably below the body
/// limit of every provider this build talks to.
fn max_image_bytes() -> Int {
  4 * 1024 * 1024
}

///|
/// Read an image file as an image the model can be shown.
///
/// The text block is not decoration: it is what a text-only model ends up seeing in place of the
/// picture once the request builder degrades the image, so it has to say which file and what kind.
/// The path is included because the model may want to refer to the file afterwards.
async fn read_image(
  name : String,
  full : String,
  kind : @core.ImageKind,
) -> @core.ToolOutput {
  let size = match size_of(full) {
    Some(size) => size
    None => return @core.ToolOutput::error("Could not read: \{name}")
  }
  if size > max_image_bytes().to_int64() {
    return @core.ToolOutput::error(
      "\{name} is \{size / 1024L}KB, past the \{max_image_bytes() / 1024 / 1024}MB image limit. " +
      "Resize it first, or read a region of it with another tool.",
    )
  }
  let bytes = match read_bytes_prefix(full, max_image_bytes()) {
    Some(bytes) => bytes
    None => return @core.ToolOutput::error("Could not read: \{name}")
  }
  let mime = kind.mime_type()
  let content : Array[@core.Content] = [
    // Same shape pi writes, so a reader of either log sees the same thing.
    @core.Content::Text(
      "Read image file [\{mime}] \{name} (\{bytes.length()} bytes)",
    ),
    @core.Content::Image(data=@base64.encode(bytes), mime_type=mime),
  ]
  { content, is_error: false, details: None, }
}

///|
async fn run_read(arguments : Json, cwd : String) -> @core.ToolOutput {
  let path = @core.arg_required_string(arguments, "path")
  let full = resolve_path(cwd, path)
  if !path_exists(full) {
    return @core.ToolOutput::error("File not found: \{path}")
  }
  // An image is the one "binary" a model can be shown, so it is settled first. Deciding by file
  // name would refuse a screenshot saved without an extension and would hand a `.txt` that is
  // really a PNG to the text reader, which would then answer "not UTF-8 text" about a picture it
  // could have been shown. The bytes are the evidence.
  let head = match read_bytes_prefix(full, @core.image_signature_bytes()) {
    Some(head) => head
    None => b""
  }
  match @core.sniff_image(head) {
    Some(kind) => return read_image(path, full, kind)
    None => ()
  }
  // A binary file is a normal thing to reach for by mistake, and the answer the model needs is
  // that it is one — not an exception that ends the whole turn.
  let content = match read_text_or_none(full) {
    Some(content) => content
    None =>
      return @core.ToolOutput::error(
        "\{path} is not UTF-8 text, so it cannot be read as source. It is probably a binary file.",
      )
  }
  let all = split_lines(content)
  let total = all.length()
  let start = match @core.arg_int(arguments, "offset") {
    Some(n) if n > 1 => n - 1
    _ => 0
  }
  if start >= total && total > 0 {
    return @core.ToolOutput::error(
      "Offset is past the end of \{path}, which has \{total} lines.",
    )
  }
  let end = match @core.arg_int(arguments, "limit") {
    Some(n) if n > 0 => if start + n < total { start + n } else { total }
    _ => total
  }
  let slice : Array[String] = []
  for i in start..<end {
    slice.push(all[i])
  }
  let text = if slice.length() == 0 {
    ""
  } else {
    let out = StringBuilder()
    for i in 0..<slice.length() {
      if i > 0 {
        out.write_string("\n")
      }
      out.write_string(slice[i])
    }
    out.to_string()
  }
  let offset = if start > 0 { Some(start + 1) } else { None }
  @core.format_read_result(path, text, offset)
}

// ── write ──────────────────────────────────────────────────────────────────

///|
async fn run_write(arguments : Json, cwd : String) -> @core.ToolOutput {
  let path = @core.arg_required_string(arguments, "path")
  let content = @core.arg_required_string(arguments, "content")
  let full = resolve_path(cwd, path)
  let parent = match last_slash(full) {
    // The root's own parent is itself; writing to `/x` needs `/`, not an empty
    // string, or the directory creation would resolve against the cwd.
    Some(0) => "/"
    Some(index) => full[:index].to_owned()
    None => "."
  }
  make_dirs(parent)
  write_text(full, content)
  let lines = split_lines(content).length()
  @core.ToolOutput::text("Wrote \{lines} lines to \{path}.")
}

// ── edit ───────────────────────────────────────────────────────────────────

///|
fn replacements_from(arguments : Json) -> Array[@core.Replacement] {
  let out : Array[@core.Replacement] = []
  for item in @core.arg_array(arguments, "edits") {
    out.push({
      old_text: @core.arg_required_string(item, "oldText"),
      new_text: @core.arg_required_string(item, "newText"),
    })
  }
  out
}

///|
async fn run_edit(arguments : Json, cwd : String) -> @core.ToolOutput {
  let path = @core.arg_required_string(arguments, "path")
  let full = resolve_path(cwd, path)
  if !path_exists(full) {
    return @core.ToolOutput::error("File not found: \{path}")
  }
  let replacements = replacements_from(arguments)
  if replacements.is_empty() {
    return @core.ToolOutput::error("No edits were provided.")
  }
  let original = match read_text_or_none(full) {
    Some(content) => content
    None =>
      return @core.ToolOutput::error(
        "\{path} is not UTF-8 text, so there is nothing to edit in it.",
      )
  }
  match @core.apply_edits(original, replacements) {
    // Every edit failed to apply, so nothing was written — the message says which
    // edit and why, which is what the model needs to correct it.
    Err(error) => @core.ToolOutput::error(error.to_string())
    Ok(updated) => {
      write_text(full, updated)
      @core.ToolOutput::text(
        "Applied \{replacements.length()} edit(s) to \{path}.",
      )
    }
  }
}

// ── glob ───────────────────────────────────────────────────────────────────

///|
/// Paths under `root` matching a glob, with the ignored directories pruned.
async fn collect_matches(
  root : String,
  pattern : String,
  limit : Int,
) -> Array[String] {
  let out : Array[String] = []
  let dirs : Array[String] = [root]
  while !dirs.is_empty() && out.length() < limit {
    let dir = dirs.remove(0)
    let names = list_entries(dir)
    for name in names {
      if out.length() >= limit {
        break
      }
      let full = if dir.has_suffix("/") {
        "\{dir}\{name}"
      } else {
        "\{dir}/\{name}"
      }
      if is_directory(full) {
        if !@core.is_ignored_dir(name) {
          dirs.push(full)
        }
      } else {
        // Match against the path relative to the search root, which is what the
        // pattern is written against.
        let relative = if full.length() > root.length() + 1 {
          full[root.length() + 1:].to_owned()
        } else {
          name
        }
        if @core.glob_match(pattern, relative) ||
          @core.glob_match(pattern, name) {
          out.push(relative)
        }
      }
    }
  }
  out
}

///|
async fn run_glob(arguments : Json, cwd : String) -> @core.ToolOutput {
  let pattern = @core.arg_required_string(arguments, "pattern")
  let path = match @core.arg_string(arguments, "path") {
    Some(p) if p != "" => p
    _ => "."
  }
  let limit = match @core.arg_int(arguments, "limit") {
    Some(n) if n > 0 => n
    _ => 1000
  }
  let root = resolve_path(cwd, path)
  if !path_exists(root) {
    return @core.ToolOutput::error("Directory not found: \{path}")
  }
  let matches = collect_matches(root, pattern, limit)
  if matches.is_empty() {
    return @core.ToolOutput::text("No files matched \{pattern}.")
  }
  let truncated = matches.length() >= limit
  let text = matches.join("\n")
  let output = if truncated {
    @core.ToolOutput::text("\{text}\n… result limit reached (\{limit}) …")
  } else {
    @core.ToolOutput::text(text)
  }
  output
}

// ── grep ───────────────────────────────────────────────────────────────────

///|
/// The offset of the last `/`, or `None` when there is not one.
///
/// Written out because there is no `rfind` on `String`; the loop walks backwards
/// rather than building a reversed copy.
fn last_slash(path : String) -> Int? {
  let length = path.length()
  for back in 0..<length {
    let index = length - 1 - back
    if path[index].unsafe_to_char() == '/' {
      return Some(index)
    }
  }
  None
}

///|
fn basename(path : String) -> String {
  match last_slash(path) {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
}

///|
/// Search one file, appending `path:line: text` for each hit.
async fn search_file(
  path : String,
  display : String,
  needle : String,
  ignore_case : Bool,
  limit : Int,
  out : Array[String],
) -> Unit {
  // A file that is not text simply cannot contain the pattern, so it is skipped rather than
  // reported: grepping a repository must not fail because a directory holds an image.
  let content = match read_text_or_none(path) {
    Some(content) => content
    None => return
  }
  let haystack = if ignore_case { needle.to_lower() } else { needle }
  let mut line_number = 0
  for line in content.split("\n") {
    line_number += 1
    if out.length() >= limit {
      return
    }
    let subject = line.to_owned()
    let candidate = if ignore_case { subject.to_lower() } else { subject }
    if candidate.contains(haystack) {
      out.push("\{display}:\{line_number}: \{@core.truncate_line(subject)}")
    }
  }
}

///|
async fn run_grep(arguments : Json, cwd : String) -> @core.ToolOutput {
  let pattern = @core.arg_required_string(arguments, "pattern")
  let path = match @core.arg_string(arguments, "path") {
    Some(p) if p != "" => p
    _ => "."
  }
  let ignore_case = match @core.arg_bool(arguments, "ignoreCase") {
    Some(value) => value
    None => false
  }
  let limit = match @core.arg_int(arguments, "limit") {
    Some(n) if n > 0 => n
    _ => 100
  }
  let file_glob = @core.arg_string(arguments, "glob")
  let root = resolve_path(cwd, path)
  if !path_exists(root) {
    return @core.ToolOutput::error("Path not found: \{path}")
  }
  let hits : Array[String] = []
  if is_directory(root) {
    let files = collect_matches(root, "**/*", 50000)
    for file in files {
      if hits.length() >= limit {
        break
      }
      let matched_glob = match file_glob {
        // Match the pattern against both the path and its last segment, so
        // `*.ts` finds nested files as well as `src/*.ts` style patterns.
        Some(g) =>
          @core.glob_match(g, file) || @core.glob_match(g, basename(file))
        None => true
      }
      if matched_glob {
        search_file("\{root}/\{file}", file, pattern, ignore_case, limit, hits)
      }
    }
  } else {
    search_file(root, path, pattern, ignore_case, limit, hits)
  }
  if hits.is_empty() {
    return @core.ToolOutput::text("No matches for \{pattern}.")
  }
  let truncated = hits.length() >= limit
  let suffix = if truncated {
    "\n… result limit reached (\{limit}) …"
  } else {
    ""
  }
  let body = hits.join("\n") + suffix
  @core.ToolOutput::text(body)
}
