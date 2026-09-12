///|
/// Logging that survives a crash.
///
/// MoonBit's stdout is block-buffered when redirected to a file, so the lines
/// explaining a failure sit in the buffer while the process dies. stderr is not
/// buffered, and a log nobody can read afterwards is worth nothing.
pub async fn log(line : String) -> Unit {
  @stdio.stderr.write(line + "\n")
}
