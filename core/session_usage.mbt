///|
/// What a session has used, and what it has cost.
///
/// The figures come from the log rather than from a running total kept in memory, which is
/// what makes them survive a restart: every assistant message records its own usage, and a
/// compaction records what its summarization call cost. Totals are therefore the same whether
/// a session was just resumed or has been running for hours.
///
/// upstream's footer counts the same three sources — assistant responses, usage reported by tools
/// (nothing here reports any), and summary generation.

///|
pub(all) struct SessionUsage {
  input : Int
  output : Int
  cache_read : Int
  cache_write : Int
  /// Reasoning tokens, when the provider reports them. Optional in the log because older
  /// sessions predate the field, so it is summed only where it exists.
  reasoning : Int
  total_tokens : Int
  /// In US dollars, summed from the per-message costs the parser already computed.
  cost : Cost
  /// How many assistant messages the totals cover, so a reader can tell "expensive" from
  /// "long".
  replies : Int
} derive(Eq, Debug)

///|
/// Prompt tokens the provider billed: fresh input plus both cache buckets.
///
/// DeepSeek reports a cache hit as part of `prompt_tokens`, so this is the denominator a
/// cache-hit share is read against — not `input`, which already excludes what was cached.
/// Kept beside the struct because the three fields only mean this together.
pub fn SessionUsage::billed_input(self : SessionUsage) -> Int {
  self.input + self.cache_read + self.cache_write
}

///|
/// The same sum for one call's usage: fresh input plus both cache buckets.
pub fn Usage::billed_input(self : Usage) -> Int {
  self.input + self.cache_read + self.cache_write
}

///|
/// Everything this conversation has spent: every call on the active branch, including the ones
/// compaction has since summarized away.
///
/// `path()` rather than `context_entries()` on purpose. What a compaction replaces stops being
/// sent to the model, but it was still paid for, and a total that shrank when the context was
/// compacted would be a total nobody could trust. Branches the conversation left behind are not
/// counted: they belong to a different story, and upstream's `/tree` is where they are accounted for.
pub fn Session::usage(self : Session) -> SessionUsage {
  let mut total : SessionUsage = {
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    reasoning: 0,
    total_tokens: 0,
    cost: {
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    },
    replies: 0,
  }
  for entry in self.path() {
    let usage = match entry.kind {
      Message(message~) =>
        match message {
          Assistant(assistant) => assistant.usage
          _ => continue
        }
      // A compaction bought a summary; that call is part of what the session cost even though
      // the messages it replaced are no longer in the context.
      Compaction(usage~, ..) =>
        match usage {
          Some(usage) => usage
          None => continue
        }
      _ => continue
    }
    total = add(total, usage)
  }
  total
}

///|
/// The size of the most recent request, as the provider measured it.
///
/// The billed input of the last assistant message that reported one. The provider is the only thing
/// that knows how big a prompt really was, and this is what it said about the request it answered —
/// which is why the figure is a measurement rather than an estimate, and why it is the *newest* one:
/// what a reader wants from a context figure is how close the conversation is to the model's window.
///
/// Zero for a conversation nothing has answered yet, which a reader can read as "nothing sent",
/// and which is exactly what it means.
pub fn Session::last_prompt_tokens(self : Session) -> Int {
  let mut measured = 0
  for entry in self.path() {
    match entry.kind {
      Message(message~) =>
        match message {
          Assistant(assistant) =>
            // Compactions are skipped on purpose: a summarization call's prompt is the history it
            // is replacing, not the conversation the next request will carry.
            if assistant.usage.billed_input() > 0 {
              measured = assistant.usage.billed_input()
            }
          _ => ()
        }
      _ => ()
    }
  }
  measured
}

///|
fn add(total : SessionUsage, usage : Usage) -> SessionUsage {
  // A `match` inside an arithmetic expression needs its own parentheses; binding it first reads
  // better anyway, since the field is optional in the log.
  let reasoning = match usage.reasoning {
    Some(value) => value
    None => 0
  }
  // Bound with an explicit type: a bare struct literal as a whole body parses as a block.
  let sum : SessionUsage = {
    input: total.input + usage.input,
    output: total.output + usage.output,
    cache_read: total.cache_read + usage.cache_read,
    cache_write: total.cache_write + usage.cache_write,
    reasoning: total.reasoning + reasoning,
    total_tokens: total.total_tokens + usage.total_tokens,
    cost: {
      input: total.cost.input + usage.cost.input,
      output: total.cost.output + usage.cost.output,
      cache_read: total.cost.cache_read + usage.cost.cache_read,
      cache_write: total.cost.cache_write + usage.cost.cache_write,
      total: total.cost.total + usage.cost.total,
    },
    replies: total.replies + 1,
  }
  sum
}

///|
/// Sum two usages. Reasoning is dropped, because it is informational detail already counted in
/// `output` and summing it would double-report; every other field is a billed quantity.
pub fn Usage::add(self : Usage, next : Usage) -> Usage {
  {
    input: self.input + next.input,
    output: self.output + next.output,
    cache_read: self.cache_read + next.cache_read,
    cache_write: self.cache_write + next.cache_write,
    reasoning: None,
    total_tokens: self.total_tokens + next.total_tokens,
    cost: {
      input: self.cost.input + next.cost.input,
      output: self.cost.output + next.cost.output,
      cache_read: self.cost.cache_read + next.cost.cache_read,
      cache_write: self.cost.cache_write + next.cost.cache_write,
      total: self.cost.total + next.cost.total,
    },
  }
}

///|
/// A cost with enough digits to be non-zero without being unreadable.
///
/// Cents are the wrong unit for a turn: a short one costs a few hundredths of a millicent, and
/// rounding to cents would print every turn as `$0.00`. Below a tenth of a dollar the extra
/// digits are the information.
pub fn format_cost(value : Double) -> String {
  let decimals = if value < 0.1 { 6 } else { 4 }
  let scale = if decimals == 6 { 1000000.0 } else { 10000.0 }
  let scaled = (value * scale).round().to_int()
  let text = "\{scaled}"
  // Digits include the ones before the point, so a session that has cost a dollar is not printed
  // as a tenth of one. The point goes in `decimals` from the right whatever the magnitude.
  let padded = if text.length() >= decimals + 1 {
    text
  } else {
    zeroes(decimals + 1 - text.length()) + text
  }
  let cut = padded.length() - decimals
  padded[:cut].to_owned() + "." + padded[cut:].to_owned()
}

///|
fn zeroes(count : Int) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_char('0')
  }
  out.to_string()
}

///|
/// The share of a request's prompt that came from cache, as a percentage.
///
/// A partial hit is never rounded up to `100`: once the integer part would read as a full hit,
/// the reading gains just enough decimals to stay honest, so one missed token of a million says
/// `99.9999` rather than `100`. The formula is dsh's, ported with integer arithmetic so a tie
/// rounds the same way on every backend. `None` when no prompt was sent, because a share of
/// nothing is not a number a reader should see.
pub fn format_cache_hit_percent(
  cache_read : Int,
  prompt_tokens : Int,
) -> String? {
  if prompt_tokens <= 0 {
    return None
  }
  let cache = cache_read.to_int64()
  let total = prompt_tokens.to_int64()
  let missed = total - cache
  if missed <= 0 {
    return Some("100")
  }
  let units = rounded_percent_units(cache, total)
  if units < 100L {
    return Some("\{units}")
  }
  // The ratio rounds to a hundred without being one. Add a decimal at a time until the printed
  // value separates from `100`, so the reader sees the miss instead of a full hit.
  let mut places = 1
  let mut gap = missed * 200L
  let tens = total / 10L
  while gap <= tens {
    gap = gap * 10L
    places = places + 1
  }
  let ones = total % 10L
  let mut loss = 5L
  for candidate in 1..<5 {
    let factor = candidate.to_int64() * 2L + 1L
    let threshold = factor * tens + factor * ones / 10L
    if gap <= threshold {
      loss = candidate.to_int64()
      break
    }
  }
  let out = StringBuilder()
  out.write_string("99.")
  for _ in 0..<(places - 1) {
    out.write_char('9')
  }
  out.write_string("\{10L - loss}")
  Some(out.to_string())
}

///|
/// The percentage a ratio rounds to, as integer units, ties upward.
///
/// Done by comparing integers rather than dividing, because the boundary is the whole point: a
/// floating-point `99.5` can land on either side of the integer depending on the backend.
fn rounded_percent_units(cache : Int64, total : Int64) -> Int64 {
  let doubled = 200L
  let quotient = total / doubled
  let remainder = total % doubled
  let mut lower = 0L
  let mut upper = 100L
  while lower < upper {
    let candidate = (lower + upper + 1L) / 2L
    let factor = candidate * 2L - 1L
    let threshold = factor * quotient +
      (factor * remainder + doubled - 1L) / doubled
    if cache >= threshold {
      lower = candidate
    } else {
      upper = candidate - 1L
    }
  }
  lower
}
