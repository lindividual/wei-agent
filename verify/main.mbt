///|
/// Round trip every entry in the local pi session store and report what survives.
///
/// Unit tests pin the shapes worth protecting; this walks all of them. Real
/// sessions contain combinations the samples miss — unusual tool arguments,
/// truncated streams, custom entries written by extensions — and a model that
/// only survives the samples is not trustworthy.
///
/// It also derives each session's context, so a path or compaction bug shows up
/// against real data rather than only against hand-built fixtures.
///
/// Run with `moon run verify`. Exits non-zero if anything fails.

///|
/// Parse without propagating: a malformed line is a finding to report, not an
/// exception that aborts the whole walk.
fn parse_or_none(line : StringView) -> Json? {
  try @json.parse(line) catch {
    _ => None
  } noraise {
    entry => Some(entry)
  }
}

///|
/// `None` when the entry survives a decode/encode round trip, otherwise a
/// description of what went wrong.
fn check(j : Json) -> String? {
  try @core.Entry::from_json(j) catch {
    e => Some("decode failed: \{e}")
  } noraise {
    entry => {
      let reencoded = entry.to_json()
      if reencoded == j {
        None
      } else {
        Some(
          "round trip mismatch\n    in:  \{j.stringify()}\n    out: \{reencoded.stringify()}",
        )
      }
    }
  }
}

///|
fn type_tag(j : Json) -> String {
  match j {
    Object(m) =>
      match m.get("type") {
        Some(String(t)) => t
        _ => ""
      }
    _ => ""
  }
}

///|
fn is_header(j : Json) -> Bool {
  type_tag(j) == "session"
}

///|
fn try_header(j : Json) -> @core.SessionHeader? {
  try @core.SessionHeader::from_json(j) catch {
    _ => None
  } noraise {
    h => Some(h)
  }
}

///|
async fn main {
  let home = match @env.get_env_var("HOME") {
    Some(h) if h != "" => h
    _ => abort("HOME is not set")
  }
  let root = "\{home}/.pi/agent/sessions"
  if !@fs.exists(root) {
    abort("no session store at \{root}")
  }

  let mut files = 0
  let mut entries = 0
  let mut messages = 0
  let mut contexts = 0
  let failures : Array[String] = []
  // Trimming is measured against real conversations rather than synthetic ones:
  // the whole reason for the policy is what actual sessions contain.
  let mut raw_tokens = 0
  let mut trimmed_tokens = 0
  let mut tool_trims = 0
  let mut thinking_blanks = 0

  @fs.walk(root, max_concurrency=1, (dir, names) => {
    for name in names {
      if !name.has_suffix(".jsonl") {
        continue
      }
      let path = "\{dir}/\{name}"
      files += 1
      let text = @fs.read_file(path).text()
      let mut header : @core.SessionHeader? = None
      let parsed : Array[@core.Entry] = []
      for raw in text.split("\n") {
        let line = raw.trim()
        if line.is_empty() {
          continue
        }
        let decoded = parse_or_none(line)
        let j = match decoded {
          None => {
            failures.push("\{path}\n  unparsable JSON")
            continue
          }
          Some(j) => j
        }
        // The header is the only line shaped differently, so dispatch on the
        // type tag rather than attempting a header parse that would throw.
        if is_header(j) {
          match try_header(j) {
            Some(h) => header = Some(h)
            None => failures.push("\{path}\n  malformed session header")
          }
          continue
        }
        entries += 1
        match check(j) {
          None => ()
          Some(problem) => failures.push("\{path}\n  \{problem}")
        }
        match @core.Entry::from_json(j) {
          entry => {
            parsed.push(entry)
            if entry.kind is @core.Message(..) {
              messages += 1
            }
          }
        }
      }
      match header {
        None => failures.push("\{path}\n  no session header")
        Some(h) => {
          let session = @core.Session::new(h, parsed)
          let context = session.context()
          contexts += 1
          // Deriving is what the agent will actually do; a throw here would be a
          // runtime failure rather than a wrong answer, and either way it is a bug.
          let (_, report) = @core.trim_context_reporting(
            context.messages,
            @core.TrimPolicy::default(),
          )
          raw_tokens += report.before_tokens
          trimmed_tokens += report.after_tokens
          tool_trims += report.tool_results_trimmed
          thinking_blanks += report.thinking_blanked
        }
      }
    }
  })

  println("files      \{files}")
  println("entries    \{entries}")
  println("messages   \{messages}")
  println("contexts   \{contexts}")
  println("")
  println("trimming (default policy, per-session derivation)")
  println("  tokens   \{raw_tokens} -> \{trimmed_tokens}")
  if raw_tokens > 0 {
    let saved = (raw_tokens - trimmed_tokens) * 100 / raw_tokens
    println("  saved    \{saved}%")
  }
  println(
    "  results  \{tool_trims} trimmed, \{thinking_blanks} reasoning blocks blanked",
  )
  println("")
  println("failures   \{failures.length()}")
  let shown = if failures.length() < 10 { failures.length() } else { 10 }
  for failure in failures[:shown] {
    println("")
    println(failure)
  }
  if failures.length() > shown {
    println("\n... and \{failures.length() - shown} more")
  }
  if !failures.is_empty() {
    abort("round trip failed for \{failures.length()} entries")
  }
}
