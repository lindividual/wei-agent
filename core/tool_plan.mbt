///|
/// Tool-call scheduling.
///
/// A batch of tool calls is split into segments: exclusive calls each form their
/// own barrier, and runs of concurrency-safe calls between barriers can be in
/// flight together.
///
/// This takes the useful half of dsh's scheduler without the other half. dsh
/// reclassifies on every iteration and runs a bounded rolling pool, which matters
/// when batches are large and mixed. Measured against real sessions, 88.7% of
/// batches hold a single call and only 1.9% mix the two kinds, so a rolling pool
/// would add machinery for a case that barely occurs. What does occur is
/// `[read, bash, read]`, where treating the batch as uniformly exclusive — upstream's
/// rule — serializes two reads that have no reason to wait.

///|
/// One call as the scheduler sees it.
pub(all) struct ToolCallPlan {
  name : String
  /// True when this specific call may run alongside others. Decided from the
  /// arguments, not the tool name: reading two different files is safe, reading
  /// and writing the same file is not.
  is_concurrency_safe : Bool
} derive(Eq, Debug)

///|
/// A unit of scheduling.
pub(all) enum Segment {
  /// Exactly one call, running alone.
  Exclusive(index~ : Int)
  /// Consecutive safe calls that may overlap.
  Parallel(indices~ : Array[Int])
} derive(Eq, Debug)

///|
/// Split calls into segments, preserving order.
///
/// The result covers every input index exactly once and in ascending order, so a
/// caller can collect outcomes by index and get the model's order back.
pub fn plan_segments(calls : Array[ToolCallPlan]) -> Array[Segment] {
  let segments : Array[Segment] = []
  let mut pending : Array[Int] = []
  for i in 0..<calls.length() {
    if calls[i].is_concurrency_safe {
      pending.push(i)
    } else {
      // A barrier ends the run of safe calls before it starts.
      if !pending.is_empty() {
        segments.push(Parallel(indices=pending))
        pending = []
      }
      segments.push(Exclusive(index=i))
    }
  }
  if !pending.is_empty() {
    segments.push(Parallel(indices=pending))
  }
  segments
}

///|
/// Describe the plan for logging and tests: `E` for an exclusive call, `P` for a
/// position inside a parallel segment.
pub fn plan_shape(calls : Array[ToolCallPlan]) -> String {
  let out = StringBuilder()
  for segment in plan_segments(calls) {
    match segment {
      Exclusive(..) => out.write_string("E")
      Parallel(indices~) =>
        for _ in indices {
          out.write_string("P")
        }
    }
  }
  out.to_string()
}
