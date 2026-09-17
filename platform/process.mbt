///|
/// Running shell commands for the `bash` tool.
///
/// A tool that can run anything is the one place where the timeout actually
/// matters: a command that waits on a prompt would hang the agent forever.

///|
fn text_of(data : &@io.Data) -> String {
  @utf8.decode_lossy(data.binary())
}

///|
/// The shell commands are run through. upstream uses the user's configured shell;
/// bash is the safe default here, and it is what the tool description promises.
fn shell() -> String {
  "/bin/bash"
}

///|
/// Run a command and collect its output.
///
/// A timed-out command reports `timed_out` rather than raising: the tool layer
/// turns that into a result the model can read and act on, which is more useful
/// than an exception that ends the turn.
pub async fn exec(
  command : String,
  cwd : String,
  timeout_ms : Int?,
) -> @core.ExecResult {
  let attempt = () => @process.collect_output(shell(), ["-c", command], cwd~)
  match timeout_ms {
    None => {
      let (code, out, err) = attempt()
      {
        stdout: text_of(out),
        stderr: text_of(err),
        exit_code: code,
        timed_out: false,
      }
    }
    Some(limit) =>
      match @async.with_timeout_opt(limit, attempt) {
        Some((code, out, err)) =>
          {
            stdout: text_of(out),
            stderr: text_of(err),
            exit_code: code,
            timed_out: false,
          }
        None => { stdout: "", stderr: "", exit_code: -1, timed_out: true, }
      }
  }
}
