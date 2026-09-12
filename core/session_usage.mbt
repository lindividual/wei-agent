///|
/// What a session has used, and what it has cost.
///
/// The figures come from the log rather than from a running total kept in memory, which is
/// what makes them survive a restart: every assistant message records its own usage, and a
/// compaction records what its summarization call cost. Totals are therefore the same whether
/// a session was just resumed or has been running for hours.
///
/// pi's footer counts the same three sources — assistant responses, usage reported by tools
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
/// Everything this conversation has spent: every call on the active branch, including the ones
/// compaction has since summarized away.
///
/// `path()` rather than `context_entries()` on purpose. What a compaction replaces stops being
/// sent to the model, but it was still paid for, and a total that shrank when the context was
/// compacted would be a total nobody could trust. Branches the conversation left behind are not
/// counted: they belong to a different story, and pi's `/tree` is where they are accounted for.
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
