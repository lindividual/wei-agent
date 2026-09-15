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
  /// The session's background jobs. Only `wait` reads one, and a caller with no store has no jobs —
  /// which is what that tool then reports.
  jobs? : @core.JobStore,
  /// Only a command reports one: what it started, and what is still running when it returned.
  watcher? : ExecWatcher,
) -> @core.ToolOutput {
  match name {
    "bash" => run_bash(arguments, cwd, watcher?)
    // Code mode's one verb, and the tools mode's `bash` is the same body with a different argument
    // name. One implementation rather than two, because the two differ only in how a command is
    // spelled to the model: what a command is, and what it leaves behind, is decided here.
    "exec" => run_exec(arguments, cwd, watcher?)
    "wait" =>
      run_wait(
        arguments,
        cwd,
        match jobs {
          Some(store) => store
          None => @core.JobStore::new()
        },
      )
    "read" => run_read(arguments, cwd)
    "write" => run_write(arguments, cwd)
    "edit" => run_edit(arguments, cwd)
    "glob" => run_glob(arguments, cwd)
    "grep" => run_grep(arguments, cwd)
    "script" => run_script(arguments, cwd)
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
  /// The job record this command's processes belong to, when the caller made one.
  ///
  /// Reported in the tool result when something is left running, because the alternative is
  /// measured: a model told only "the job id" went looking for it — it guessed the pid, then
  /// `bash-1` — and spent two calls on an answer the result could have carried.
  id : String?
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
  run_command(
    @core.arg_required_string(arguments, "command"),
    arguments,
    cwd,
    watcher?,
  )
}

///|
/// Code mode's `exec`: a shell command or a MoonBit program.
///
/// Exactly one dialect, enforced here rather than in the schema. A schema that said "one of these"
/// would need a shape this validator does not have, and a call that gets past it and is refused
/// with the reason is a call the model can correct — which is the whole point of validating at all.
async fn run_exec(
  arguments : Json,
  cwd : String,
  watcher? : ExecWatcher,
) -> @core.ToolOutput {
  match @core.exec_dialect(arguments) {
    @core.ExecDialect::Both =>
      // The schema cannot say "exactly one of these both ways" in the subset this project
      // validates. So the rule is enforced when the call runs, where the refusal can say which
      // mistake was made — which is the reason to validate at all rather than trust the shape.
      @core.ToolOutput::error(
        "Pass either `bash` or `moonbit`, not both: one call runs one thing.",
      )
    @core.ExecDialect::Neither =>
      // The fields that arrived are echoed when there were any, because a refusal a model can act on
      // has to name what it actually sent. A key that is only misspelled (`cmd`, `shell`) reads as an
      // instruction rather than as silence; an empty call is told plainly that it is empty, which is
      // a different mistake from a wrong name.
      @core.ToolOutput::error(
        match @core.argument_keys(arguments) {
          [] =>
            "Nothing to run: the call had no arguments. Pass `bash` with a shell command, or `moonbit` with `@builtin/NAME` or a MoonBit program."
          keys =>
            "Nothing to run: expected `bash` (a shell command) or `moonbit` (a program), but the call had \{keys.join(", ")}. One of those two names, with the command or program as its value."
        },
      )
    @core.ExecDialect::Command(text~) =>
      run_command(text, arguments, cwd, watcher?)
    @core.ExecDialect::Program(text~) =>
      // Handed over in the shape `run_script` already reads: a program is a program whichever tool
      // asked for it, and a second reader for the same two fields is a second place for them to
      // disagree. `@builtin/NAME` becomes `name`, anything else becomes `source`.
      run_script(
        Json::object(
          Map([
            (
              // A bundled script may be named with or without the prefix; anything else is a
              // program. The rule is in `core` because it is the kind of decision worth a test
              // that does not compile anything.
              if @core.program_is_bundled(text) {
                "name"
              } else {
                "source"
              },
              Json::string(text),
            ),
            (
              "args",
              Json::array(
                @core.arg_strings(arguments, "args").map(arg => {
                  Json::string(arg)
                }),
              ),
            ),
          ]),
        ),
        cwd,
      )
  }
}

///|
/// Run a shell command, and report what it left behind.
async fn run_command(
  command : String,
  arguments : Json,
  cwd : String,
  watcher? : ExecWatcher,
) -> @core.ToolOutput {
  if command.trim() == "" {
    return @core.ToolOutput::error("The command is empty.")
  }
  // The schema says seconds; the platform wants milliseconds.
  let timeout = match @core.arg_int(arguments, "timeout") {
    Some(seconds) if seconds > 0 => Some(seconds * 1000)
    _ => None
  }
  let outcome = exec_managed(
    command,
    cwd~,
    timeout_ms?=timeout,
    keep_output=true,
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
  let lingering = outcome.lingering
  // Nothing was left running, so nobody will ever read the files again. Removing them here rather
  // than in the driver keeps the lifetime of a temp file next to the call that made it.
  if lingering.is_empty() {
    let files : Array[String] = []
    match outcome.output {
      Some(output) => {
        files.push(output.out_path)
        files.push(output.err_path)
      }
      None => ()
    }
    for path in files {
      try @fs.remove(path) catch {
        _ => ()
      } noraise {
        _ => ()
      }
    }
    return @core.format_exec_result(outcome.result, cwd)
  }
  let formatted = @core.format_exec_result(outcome.result, cwd)
  // Said in the tool result as well as in the panel: a command that returned while its work
  // continues is invisible to the model otherwise, and the model is who decided to background it.
  // `Text` alone is ambiguous with `StreamEvent::Text`, hence the qualified form.
  // Named when the caller knows it, because a model told only "the job id" has to guess one and
  // find out. Everything else about the note is the same either way.
  let mut how_to_collect = "Its output is kept: a `wait` on its job id collects what it prints from here on."
  match watcher {
    Some(watch) =>
      match watch.id {
        Some(id) =>
          how_to_collect = "Its output is kept: `wait \"\{id}\"` collects what it prints from here on."
        None => ()
      }
    None => ()
  }
  let note : @core.Content = @core.Content::Text(
    "\n\n[this command left \{lingering.length()} process(es) running (pid \{pids_text(lingering)}). They keep running until stopped, and are listed in the sidebar under Background. \{how_to_collect}]",
  )
  let content : Array[@core.Content] = []
  for block in formatted.content {
    content.push(block)
  }
  content.push(note)
  { content, is_error: formatted.is_error, details: formatted.details, }
}

///|
/// Take note of what a command just did to its job record.
///
/// Three outcomes and three answers, and the place they are decided is here rather than in the
/// driver, so that a test can produce exactly the states a wait has to read: a command that
/// finished and stopped nothing (the record is dropped — a panel that listed every call would be a
/// log, not an answer), and a command that left something running (the record stays, and where its
/// output goes is attached to it, because the child that is writing has outlived the shell that
/// would have reported it).
pub fn note_execution(
  jobs : @core.JobStore,
  id : String,
  outcome : ExecOutcome,
) -> Unit {
  // Before anything is decided from the pids: the list is only complete now.
  jobs.finish_call(id)
  jobs.observe(id, outcome.children, tail="")
  if outcome.lingering.is_empty() {
    jobs.forget(id)
    return
  }
  jobs.observe(id, outcome.lingering, tail="")
  match outcome.output {
    Some(output) => jobs.attach_output(id, output)
    None => ()
  }
}

// ── wait ───────────────────────────────────────────────────────────────────

///|
/// Collect what a job that outlived its call has printed.
///
/// The wait is a poll rather than a notification, because there is nothing to be notified by: the
/// process that would have said "I am done" is a child of a shell that exited before the tool call
/// returned. `ps` is the only thing that knows whether it is still there, and it is cheap enough to
/// ask twice a second.
pub async fn run_wait(
  arguments : Json,
  cwd : String,
  jobs : @core.JobStore,
) -> @core.ToolOutput {
  ignore(cwd)
  let id = @core.arg_required_string(arguments, "id")
  let job = match jobs.get(id) {
    Some(job) => job
    None =>
      return @core.ToolOutput::error(@core.format_wait_unknown(id, jobs.list()))
  }
  let limit_ms : Int? = match @core.arg_int(arguments, "timeout") {
    // Zero means "do not wait at all": answer with whatever the job has so far. A caller that
    // wants to poll at its own pace should not have to spend a call learning there is nothing yet.
    Some(seconds) if seconds <= 0 => Some(0)
    // Bounded, so that waiting on a server that never exits cannot be asked to hold the turn for a
    // day. The ceiling is a property of the tool rather than of the call.
    Some(seconds) if seconds > 900 => Some(900 * 1000)
    Some(seconds) => Some(seconds * 1000)
    None => Some(@core.default_wait_seconds() * 1000)
  }
  // A job that has already ended is answered immediately: its output has been sitting in a file
  // since it stopped, and making the caller wait for a process that is already gone would be a
  // sleep for its own sake.
  let mut waited : Int64 = 0L
  if job.is_live() {
    let limit = limit_ms.unwrap_or(0)
    while waited < limit.to_int64() && job.is_live() {
      @async.sleep(poll_interval_ms)
      waited += poll_interval_ms.to_int64()
      settle_if_gone(jobs, job)
    }
  }
  let now = @env.now().reinterpret_as_int64()
  if job.is_live() {
    if job.status is @core.Stopping {
      // Waiting again is not the useful thing to say about something that was asked to stop and has
      // not. What is true is that it is still there.
      return @core.ToolOutput::error(
        "\{job.id} was asked to stop and its processes are still there. It is listed under Background; stopping it again kills it outright.",
      )
    }
    return @core.ToolOutput::error(@core.format_wait_pending(job, waited))
  }
  match job.output {
    None =>
      @core.ToolOutput::error(
        "\{job.id} has finished, but its output was not kept. Only a command run by `exec` goes on\nwriting to a file this can read: a command that returned inside its own call was already shown\nin full, and a job recorded by an earlier run of the server lost its files with that run.",
      )
    Some(output) => {
      let (stdout, out_used, out_size) = read_slice(
        output.out_path,
        output.out_read,
        @core.wait_max_output_bytes(),
      )
      let (stderr, err_used, err_size) = read_slice(
        output.err_path,
        output.err_read,
        @core.wait_max_output_bytes(),
      )
      // The position advances by what the read consumed, not by what it asked for: the ceiling may
      // have stopped it short, and the next call has to begin where this one ended.
      jobs.mark_read(
        id,
        out_bytes=output.out_read + out_used,
        err_bytes=output.err_read + err_used,
      )
      let more = out_size > (output.out_read + out_used).to_int64() ||
        err_size > (output.err_read + err_used).to_int64()
      @core.format_wait_result(job, stdout, stderr, more, now)
    }
  }
}

///|
/// How often a wait looks at the process table, in milliseconds.
///
/// Fast enough that a command which finishes between polls costs the reader a fraction of a second,
/// slow enough that a job running for a minute costs a couple of hundred `ps` calls rather than
/// thousands.
let poll_interval_ms : Int = 250

///|
/// Notice a job whose processes have gone, and write the settlement down.
///
/// The server's own supervisor does the same thing on a two-second timer. Doing it per poll as well
/// is what lets a `wait` return when the process actually goes rather than up to two seconds later,
/// and it is the only settlement a `pi` run — which has no supervisor — would ever get.
async fn settle_if_gone(jobs : @core.JobStore, job : @core.Job) -> Unit {
  if !job.is_live() {
    return
  }
  let mut alive = false
  for pid in job.pids {
    if pid_alive(pid) {
      alive = true
    }
  }
  if !alive {
    let stopping = job.status is @core.Stopping
    jobs.finish(
      job.id,
      if stopping {
        @core.Killed
      } else {
        @core.Completed
      },
      detail=if stopping { "stopped" } else { "exited on its own" },
      finished_at=@env.now().reinterpret_as_int64(),
    )
  }
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
/// An image file, read and encoded for the wire.
pub(all) struct LoadedImage {
  /// Base64 of the file's bytes, which is how an image travels.
  data : String
  mime_type : String
} derive(Eq, Debug)

///|
/// Read a file as an image the model can be shown, or say why it is not one.
///
/// The same question the read tool answers — by the bytes rather than by the file name, and against
/// the same size cap — asked by the one other caller there is. A host that lets a reader attach a
/// screenshot has to answer "is this an image" before it sends anything, and answering it a second
/// way here would be a second limit and a second list of formats to keep in step.
///
/// The difference is who is being told. A tool result is addressed to the model, so it comes back as
/// a tool result; this is addressed to the reader at the moment they pick a file, so it comes back as
/// a reason they can act on — too big, not a picture, or not there.
pub async fn load_image(path : String) -> Result[LoadedImage, String] {
  if !path_exists(path) {
    return Err("no file at \{path}")
  }
  let head = match read_bytes_prefix(path, @core.image_signature_bytes()) {
    Some(head) => head
    None => b""
  }
  let kind = match @core.sniff_image(head) {
    Some(kind) => kind
    None => return Err("not an image (png, jpeg, gif or webp): \{path}")
  }
  let size = match size_of(path) {
    Some(size) => size
    None => return Err("could not read \{path}")
  }
  if size > max_image_bytes().to_int64() {
    return Err(
      "\{size / 1024L}KB is past the \{max_image_bytes() / 1024 / 1024}MB image limit",
    )
  }
  let bytes = match read_bytes_prefix(path, max_image_bytes()) {
    Some(bytes) => bytes
    None => return Err("could not read \{path}")
  }
  Ok({ data: @base64.encode(bytes), mime_type: kind.mime_type(), })
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
