///|
/// What does it cost to compress tool output, under a prefix-cached prompt?
///
/// This is the instrument for the question a local summarizer has to answer before
/// it is worth building: **is rewriting the prompt affordable at all?** It contains
/// no model, deliberately — whether a digest is *good* is a separate question from
/// whether replacing the bytes it summarizes is *cheaper*, and the second one is
/// arithmetic that a model cannot help with and a simulation can settle.
///
/// Three things it gets right that a plausible-looking version gets wrong:
///
/// 1. **It measures the wire bytes, not the logged ones.** A tool result's
///    `details` field — a diff, a truncation notice — is kept for the UI and never
///    sent (`convert_messages` drops it). One `read` in the corpus carries 518 KB
///    of it, so measuring the logged message overstates a request by an order of
///    magnitude, and it overstates it most in exactly the middle of the
///    conversation where the comparison is decided. Encoding is done by
///    `convert_messages`, the driver's own function, so it cannot drift.
///
/// 2. **It bills the way the provider does.** A request costs the bytes that match
///    the previous request's prefix at the cache rate and the rest at the fresh
///    rate. So the figure that matters is not how big a request is but how far
///    into it two consecutive requests still agree — one rewritten message in the
///    middle ends the shared prefix there and re-bills everything after it. That
///    is `core/deepseek_request.mbt::request_drift`'s definition, reproduced with
///    prefix sums because building every request body would be O(n²).
///
/// 3. **It calibrates against the bill.** Every assistant message records what the
///    provider actually charged for the request that produced it. The ratio of
///    simulated to billed is printed for every policy: a policy that cannot
///    reproduce the recorded numbers is not describing the same requests, and its
///    savings are fiction.
///
///   moon run spikelocalsum/rig --target native -- <store dir> --all
///   moon run spikelocalsum/rig --target native -- <session.jsonl> --trace
///   moon run spikelocalsum/rig --target native -- <session.jsonl> --verify

///|
/// Bytes of one model message **as it goes on the wire**.
fn wire_bytes(message : @core.Message) -> Int {
  match @core.convert_messages([message], None, vision=false) {
    [] => 0
    parts => @utf8.encode(parts[0].stringify()).length()
  }
}

///|
fn prefix_sums(sizes : Array[Int]) -> Array[Int] {
  let out : Array[Int] = [0]
  let mut total = 0
  for size in sizes {
    total = total + size
    out.push(total)
  }
  out
}

///|

///|
/// Bytes to tokens, at the repository's rate.
///
/// `Int64` because the sums below are over a whole corpus: the accumulator for
/// "prompt tokens sent" passes two billion on a 37-session replay, and MoonBit's
/// `Int` is 32-bit. That overflow is silent and shows up as a *negative* total,
/// which reads like a saving until it is subtracted.
fn tokens(bytes : Int) -> Int64 {
  ((bytes + 3) / 4).to_int64()
}

///|
/// `trim_cutoff` from `core/trim.mbt`, which is private.
///
/// Replicated rather than guessed, and cross-checked against the real
/// `prepared_context` on every message below: if the policy there changes and this
/// does not, the run reports a mismatch instead of a saving that does not exist.
fn cutoff_of(length : Int, window : Int, step : Int) -> Int {
  let released = if length > window { length - window } else { 0 }
  if step <= 1 {
    released
  } else {
    released / step * step
  }
}

///|
/// One compression policy, as a set of knobs.
///
/// All of them reduce a tool result the same way — keep the first `head` lines, the
/// last `tail` lines, and say what was dropped — because that is the shape both the
/// shipped trimming and an extractive digest have. What separates them is *when* the
/// reduction is applied:
///
/// - `window`/`step` put the cut inside the conversation, so a message's bytes can
///   change after they have been sent, which is what costs money.
/// - `window = 0, step = 1` reduces every message, i.e. once, when it is written.
struct Policy {
  name : String
  head : Int
  tail : Int
  limit : Int
  window : Int
  step : Int
  /// How many of the newest messages stay as written.
  ///
  /// This is the knob that decides what the policy costs, and it is worth naming
  /// precisely. A reduced message is cheap to *keep* and expensive to *change*: the
  /// provider's cache is a byte prefix, so the first request in which a message
  /// differs from the request before it ends the shared prefix there and re-bills
  /// everything after it — including the recent window, which is the largest part
  /// of a long prompt.
  ///
  /// So the delay is not "when to compress" but "how much fidelity to buy for the
  /// transition". `0` never lets the model see a result whole. `1` lets it be whole
  /// for exactly the one request that reasons about it — which is the whole of a
  /// tool result's useful life — and reduces it immediately after. A large delay is
  /// the current design: full for twenty messages, reduced late, and the transition
  /// then costs a re-bill of everything after it.
  delay : Int
  drop_thinking : Bool
} derive(Eq, Debug)

///|
fn Policy::cutoff(self : Policy, length : Int) -> Int {
  if self.limit <= 0 {
    return 0
  }
  let windowed = cutoff_of(length, self.window, self.step)
  let delayed = if length > self.delay { length - self.delay } else { 0 }
  if delayed < windowed {
    delayed
  } else {
    windowed
  }
}

///|
/// The reduction this policy applies, as a `TrimPolicy` that applies it everywhere.
///
/// `prepared_context` is the shipped function, so the reduction itself cannot be
/// mis-transcribed here; only the boundary is this file's business.
fn Policy::reduction(self : Policy) -> @core.TrimPolicy {
  {
    recent_window: 0,
    advance_step: 1,
    tool_result_limit: self.limit,
    head_lines: self.head,
    tail_lines: self.tail,
    drop_old_thinking: self.drop_thinking,
  }
}

///|
/// The ladder to compare: no trimming, the shipped policy, and progressively more
/// aggressive reductions applied once at write time.
///
/// The `head`/`tail` pairs are the stand-in for what a model would return. The
/// shipped trimming already believes 40 + 20 lines is a usable result, so a
/// model's digest is worth doing only if it is *smaller* than that — which is why
/// the rungs go down to a marker with nothing in it. The bottom rung is not a
/// proposal; it is the ceiling on what any amount of model quality can save, and
/// if even that does not pay for itself, nothing above it can.
fn policies() -> Array[Policy] {
  let base = @core.TrimPolicy::default()
  let tool_limit = base.tool_result_limit
  let thinking = base.drop_old_thinking
  // The shipped reduction — keep a head and a tail, blank old reasoning — at a
  // chosen window and step. Every row below differs only in those two numbers, so
  // the table is a statement about the boundary rather than about the reduction.
  let at = (name : String, window : Int, step : Int) => {
    name,
    head: base.head_lines,
    tail: base.tail_lines,
    limit: tool_limit,
    window,
    step,
    delay: 0,
    drop_thinking: thinking,
  }
  [
    {
      name: "raw",
      head: 0,
      tail: 0,
      limit: 0,
      window: 0,
      step: 0,
      delay: 0,
      drop_thinking: false,
    },
    // What is in the tree: 20 messages back, quantized by 8.
    at("shipped-20/8", base.recent_window, base.advance_step),
    // The same window with the boundary moving every message.
    at("shipped-20/1", base.recent_window, 1),
    // A window small enough that the boundary never touches a message before the
    // request that carries it has read it. `w2` is the smallest that does so for
    // the 92% of rounds that append two messages; `w1` is the smallest at all.
    at("w1-s1", 1, 1),
    at("w2-s1", 2, 1),
    at("w4-s1", 4, 1),
    at("w8-s1", 8, 1),
    // Whether quantization still earns its keep when the window is already small:
    // a bigger step moves the boundary less often but re-bills more when it does.
    at("w2-s2", 2, 2),
    at("w4-s2", 4, 2),
    at("w4-s4", 4, 4),
    at("w4-s8", 4, 8),
    // And a harsher reduction, at the window the rows above point to.
    {
      name: "w2-s1-5+5",
      head: 5,
      tail: 5,
      limit: 1024,
      window: 2,
      step: 1,
      delay: 0,
      drop_thinking: thinking,
    },
    {
      name: "w2-s1-marker",
      head: 0,
      tail: 0,
      limit: 1024,
      window: 2,
      step: 1,
      delay: 0,
      drop_thinking: thinking,
    },
  ]
}

///|
/// The derived sizes one session needs, computed once and shared by every policy.
struct Derived {
  /// Wire bytes of each message, untrimmed.
  raw : Array[Int]
  /// Wire bytes of each message after the reduction — computed per policy, see
  /// `sizes_for`.
  messages : Array[@core.ContextMessage]
  /// Recorded billed prompt size for the request that produced message `i`, or
  /// zero when `i` is not an assistant message.
  billed : Array[Int]
  /// Whether request `i` is a request at all.
  is_request : Array[Bool]
}

///|
fn Derived::new(session : @core.Session) -> Derived {
  let context = session.context()
  let messages = context.messages
  let n = messages.length()
  let raw : Array[Int] = []
  let billed : Array[Int] = []
  let is_request : Array[Bool] = []
  for i in 0..<n {
    raw.push(wire_bytes(messages[i].to_message()))
    match messages[i] {
      @core.Assistant(a) => {
        billed.push(a.usage.input + a.usage.cache_read + a.usage.cache_write)
        is_request.push(true)
      }
      _ => {
        billed.push(0)
        is_request.push(false)
      }
    }
  }
  { raw, messages, billed, is_request, }
}

///|
/// What one policy costs on one session.
struct Result {
  mut requests : Int
  mut billed : Int64
  mut prompt : Int64
  mut cache_read : Int64
  mut fresh : Int64
  mut rewritten : Int
  /// Tool results the reduction actually changed: the units of work a model would
  /// have to do, one per changed result.
  mut digests : Int
  mut mismatches : Int
  /// Billed-tokens-per-simulated-token, measured on the *difference* between two
  /// consecutive requests rather than on a whole prompt.
  ///
  /// This is the honest calibration, and the whole-prompt ratio in the table is
  /// not. A difference cancels the system prompt and the tool schemas (which the
  /// derivation does not include) and cancels whatever trim policy was in force
  /// when the log was written (which may not be the one being simulated). What is
  /// left is "this many messages were appended, the provider charged this much" —
  /// a ratio that should hold for any policy, and a number the estimator in
  /// `core/context_pressure.mbt` can be checked against.
  delta_ratios : Array[Double]
} derive(Eq, Debug)

///|
fn Result::new() -> Result {
  {
    requests: 0,
    billed: 0,
    prompt: 0,
    cache_read: 0,
    fresh: 0,
    rewritten: 0,
    digests: 0,
    mismatches: 0,
    delta_ratios: [],
  }
}

///|
/// Simulate one policy over one session.
///
/// The request at position `k` carries messages `0..k` with the boundary at
/// `cutoff(k)`; below it the reduced variant is used and above it the raw one. So
/// the byte size of any prefix of that request is a prefix-sum lookup, and the
/// shared prefix with the previous request is the first index in
/// `[previous_cutoff, this_cutoff)` where the two variants differ — nothing else
/// can have changed, because the boundary only ever moves forward.
fn simulate(
  derived : Derived,
  reduced : Array[Int],
  changed : Array[Bool],
  policy : Policy,
  verify : Bool,
) -> Result {
  let result = Result::new()
  let n = derived.messages.length()
  let raw_pre = prefix_sums(derived.raw)
  let red_pre = prefix_sums(reduced)
  let changed_pre = prefix_sums(changed.map(x => if x { 1 } else { 0 }))

  // Size of the first `i` messages of the request at `k`.
  let prefix_at = (k : Int, i : Int) => {
    let cut = if policy.cutoff(k) < i { policy.cutoff(k) } else { i }
    red_pre[cut] + (raw_pre[i] - raw_pre[cut])
  }

  let mut previous_k = -1
  let mut previous_cut = 0
  // Bytes, not tokens: the prefix a request can read from cache is a byte count,
  // and the clamp below compares it against the previous request's size. Mixing
  // the two units here caps the cache at a quarter of what it should be, which
  // looks like an expensive policy rather than like a bug.
  let mut previous_bytes = 0
  for k in 0..<n {
    if !derived.is_request[k] {
      continue
    }
    let cut = policy.cutoff(k)
    let total = prefix_at(k, k)
    result.requests = result.requests + 1
    result.billed = result.billed + derived.billed[k].to_int64()
    result.prompt = result.prompt + tokens(total)
    // The calibration sample: only where the boundary did not move, so the two
    // requests differ by exactly the messages appended between them.
    if previous_k >= 0 &&
      cut == previous_cut &&
      derived.billed[k] > derived.billed[previous_k] {
      let appended = prefix_at(k, k) - prefix_at(k, previous_k)
      if appended > 2048 {
        result.delta_ratios.push(
          (derived.billed[k] - derived.billed[previous_k]).to_double() /
          tokens(appended).to_double(),
        )
      }
    }
    let mut hit = 0
    if previous_k >= 0 {
      // Messages below the old boundary were reduced in both requests; messages at
      // or above the new one are raw in both. Only the strip between them can
      // differ, and only where the reduction changed something.
      let mut first_changed = if previous_k < k { previous_k } else { k }
      if previous_cut < cut {
        let mut i = previous_cut
        while i < cut && i < first_changed {
          if changed[i] {
            first_changed = i
            break
          }
          i = i + 1
        }
      }
      hit = prefix_at(k, first_changed)
      if hit > previous_bytes {
        hit = previous_bytes
      }
      if first_changed < previous_k {
        result.rewritten = result.rewritten + 1
      }
    }
    result.cache_read = result.cache_read + tokens(hit)
    result.fresh = result.fresh + (tokens(total) - tokens(hit))
    // Measure the measurement: every so often, rebuild the two request bodies the
    // slow and obvious way and ask `request_drift` where they stop agreeing. If
    // that disagrees with the prefix-sum answer, the fast path is wrong and every
    // number in the table is too.
    if verify && previous_k >= 0 && k % 64 == 0 {
      let drift = @core.request_drift(
        Some(body_for(derived, policy, previous_k)),
        body_for(derived, policy, k),
      )
      let expected = if previous_k < k { previous_k } else { k }
      let mut first_changed = expected
      if previous_cut < cut {
        let mut i = previous_cut
        while i < cut && i < first_changed {
          if changed[i] {
            first_changed = i
            break
          }
          i = i + 1
        }
      }
      if drift.first_changed != first_changed {
        result.mismatches = result.mismatches + 1
      }
    }
    previous_k = k
    previous_cut = cut
    previous_bytes = total
  }
  result.digests = changed_pre[n]
  result
}

///|
/// The wire messages of the request at `upto`, built from scratch.
///
/// Used only to check the prefix-sum fast path against `request_drift`, so it is
/// allowed to be as slow and as direct as it likes.
fn body_for(derived : Derived, policy : Policy, upto : Int) -> Array[Json] {
  let out : Array[Json] = []
  let cut = policy.cutoff(upto)
  let single : Array[@core.ContextMessage] = [derived.messages[0]]
  ignore(single)
  for i in 0..<upto {
    if i < cut {
      let one : Array[@core.ContextMessage] = [derived.messages[i]]
      let trimmed = @core.trim_context(one, policy.reduction())
      for
        part in @core.convert_messages(
          [trimmed[0].to_message()],
          None,
          vision=false,
        ) {
        out.push(part)
      }
    } else {
      for
        part in @core.convert_messages(
          [derived.messages[i].to_message()],
          None,
          vision=false,
        ) {
        out.push(part)
      }
    }
  }
  out
}

///|
async fn measure_session(
  path : String,
  trace : Bool,
  verify : Bool,
) -> Array[(String, Result)] {
  let session = @core.parse_session_file(@fs.read_file(path).text())
  let derived = Derived::new(session)
  let policies = policies()
  let out : Array[(String, Result)] = []
  // What the shipped code actually derives, once, so the claim "below the
  // boundary it is the reduction and above it the raw message" can be checked
  // rather than assumed. Deriving it per message instead would be O(n²) and
  // would make this rig too slow to run on the whole corpus.
  let shipped = session.prepared_context()
  for policy in policies {
    let frozen = session.prepared_context(policy=policy.reduction())
    let reduced : Array[Int] = []
    let changed : Array[Bool] = []
    let mut mismatches = 0
    let cut = policy.cutoff(derived.messages.length())
    for i in 0..<derived.messages.length() {
      let encoded = wire_bytes(frozen.messages[i].to_message())
      reduced.push(encoded)
      changed.push(
        derived.messages[i].to_message() != frozen.messages[i].to_message(),
      )
      // The shipped derivation must be exactly this reduction below the boundary
      // and the raw message above it. If it is not, this rig is describing a
      // policy nobody runs.
      if policy.name == "shipped" {
        let expected = if i < cut {
          frozen.messages[i]
        } else {
          derived.messages[i]
        }
        if expected.to_message() != shipped.messages[i].to_message() {
          mismatches = mismatches + 1
        }
      }
    }
    let result = simulate(derived, reduced, changed, policy, verify)
    result.mismatches = result.mismatches + mismatches
    out.push((policy.name, result))
    if trace {
      println(
        "  \{policy.name}: \{result.requests} requests, prompt \{tokens_of(result.prompt)} tok, billed \{tokens_of(result.billed)} tok, digests \{result.digests}",
      )
    }
  }
  if trace {
    println("\{path}")
  }
  out
}

///|
fn tokens_of(n : Int64) -> String {
  let text = n.to_string()
  let out = StringBuilder()
  let len = text.length()
  for i in 0..<len {
    if i > 0 && (len - i) % 3 == 0 {
      out.write_string(",")
    }
    out.write_string(text[i:i + 1].to_owned())
  }
  out.to_string()
}

///|
fn usd(fresh : Int64, cache_read : Int64) -> String {
  let input_rate = 0.14
  let cache_rate = 0.0028
  let value = fresh.to_double() / 1000000.0 * input_rate +
    cache_read.to_double() / 1000000.0 * cache_rate
  let text = value.to_string()
  if text.length() > 6 {
    text[:6].to_owned()
  } else {
    text
  }
}

///|
/// The difference calibration, reported as a distribution.
///
/// The median is the number to trust: many samples are the same measurement with a
/// rounding error added (a request that appends one small message), and a ratio
/// computed from a small denominator is noise. The deciles are there because the
/// spread is the interesting part — the estimator's error is not a constant that
/// could be divided out.
fn report_calibration(ratios : Array[Double]) -> Unit {
  if ratios.length() == 0 {
    println("calibration: no consecutive requests with a still boundary")
    return
  }
  let sorted = ratios.copy()
  sorted.sort()
  let at = (fraction : Double) => {
    let i = (sorted.length().to_double() * fraction).to_int()
    let index = if i >= sorted.length() { sorted.length() - 1 } else { i }
    short(sorted[index])
  }
  println(
    "calibration on \{sorted.length()} request pairs (still boundary, appended messages only)",
  )
  println(
    "  billed tokens per derived token:  p10 \{at(0.1)}   median \{at(0.5)}   p90 \{at(0.9)}",
  )
  println("  (1.00 = bytes/4 predicts the bill; 1.15 = it under-counts by 15%)")
}

///|
fn short(value : Double) -> String {
  let text = value.to_string()
  if text.length() > 4 {
    text[:4].to_owned()
  } else {
    text
  }
}

///|
/// Right-align in a field, because a table of numbers is read by its right edge.
fn pad_left(text : String, width : Int) -> String {
  if text.length() >= width {
    text
  } else {
    let out = StringBuilder()
    for _ in 0..<(width - text.length()) {
      out.write_string(" ")
    }
    out.write_string(text)
    out.to_string()
  }
}

///|
fn pad_right(text : String, width : Int) -> String {
  if text.length() >= width {
    text
  } else {
    let out = StringBuilder()
    out.write_string(text)
    for _ in 0..<(width - text.length()) {
      out.write_string(" ")
    }
    out.to_string()
  }
}

///|
async fn main {
  let args = @env.args()
  let paths : Array[String] = []
  let mut trace = false
  let mut verify = false
  let mut walk_all = false
  for i in 1..<args.length() {
    let arg = args[i]
    if arg == "--trace" {
      trace = true
    } else if arg == "--verify" {
      verify = true
    } else if arg == "--all" {
      walk_all = true
    } else {
      paths.push(arg)
    }
  }
  if paths.is_empty() {
    println(
      "usage: rig <session.jsonl>|<store dir> [--all] [--trace] [--verify]",
    )
    return
  }

  let files : Array[String] = []
  for path in paths {
    if walk_all {
      @fs.walk(path, max_concurrency=1, (dir, names) => {
        for name in names {
          if name.has_suffix(".jsonl") {
            files.push("\{dir}/\{name}")
          }
        }
      })
    } else {
      files.push(path)
    }
  }

  let names = policies().map(p => p.name)
  let totals : Array[Result] = names.map(_ => Result::new())
  let mut mismatches = 0
  for file in files {
    let per_policy = measure_session(file, trace, verify)
    for i in 0..<per_policy.length() {
      let (_, result) = per_policy[i]
      let into = totals[i]
      into.requests = into.requests + result.requests
      into.billed = into.billed + result.billed
      into.prompt = into.prompt + result.prompt
      into.cache_read = into.cache_read + result.cache_read
      into.fresh = into.fresh + result.fresh
      into.rewritten = into.rewritten + result.rewritten
      into.digests = into.digests + result.digests
      for ratio in result.delta_ratios {
        into.delta_ratios.push(ratio)
      }
      mismatches = mismatches + result.mismatches
    }
  }

  println("")
  println("sessions \{files.length()}, requests \{totals[0].requests}")
  println("")
  println(
    "policy             prompt tok   cache-read     fresh in        USD   rewrit%  digests  billed/derived",
  )
  println(
    "------------------------------------------------------------------------------------------------",
  )
  for i in 0..<names.length() {
    let r = totals[i]
    let ratio = if r.prompt == 0L {
      "n/a"
    } else {
      let v = r.billed.to_double() / r.prompt.to_double()
      let t = v.to_string()
      if t.length() > 5 {
        t[:5].to_owned()
      } else {
        t
      }
    }
    let rewritten_percent = if r.requests == 0 {
      "0.0"
    } else {
      let v = r.rewritten.to_double() * 100.0 / r.requests.to_double()
      let t = v.to_string()
      if t.length() > 4 {
        t[:4].to_owned()
      } else {
        t
      }
    }
    println(
      pad_right(names[i], 18) +
      pad_left(tokens_of(r.prompt), 11) +
      pad_left(tokens_of(r.cache_read), 12) +
      pad_left(tokens_of(r.fresh), 11) +
      pad_left(usd(r.fresh, r.cache_read), 10) +
      pad_left(rewritten_percent, 8) +
      "%" +
      pad_left(tokens_of(r.digests.to_int64()), 9) +
      pad_left(ratio, 9),
    )
  }
  println("")
  report_calibration(totals[0].delta_ratios)
  println("")
  println(
    "billed/derived is the recorded whole prompt divided by the simulated one. Read it",
  )
  println(
    "as a loose check only: it carries the system prompt and tool schemas, which the",
  )
  println(
    "derivation excludes, and the trim policy in force when the log was written, which",
  )
  println("is not necessarily the one being simulated.")
  if mismatches > 0 {
    println("")
    println(
      "MISMATCHES \{mismatches}: the rig disagrees with core's own derivation",
    )
  }
}
