///|
/// The model a session runs on.
///
/// Per session rather than per process, so two sessions side by side can use different models. The
/// choice is an entry in the session's own log (`model_change`, upstream's format), which is what makes it
/// survive a restart and read back the way upstream would read it.
///
/// The catalog itself is `@core.model_catalog` — one table holding the id, the price and the window
/// together, because they are three facts about one model and separating them is how the window of
/// one gets paired with the pricing of another. This file is the glue: what to report, and what
/// switching writes.

///|
/// What a bare `/model` answers with: the one in use, and what else there is.
fn report_model(shown : Runner) -> String {
  let (spec, known) = @core.model_spec_for(shown.model_id)
  let current = if known {
    "model: \{spec.label()}"
  } else {
    // The log names a model this build does not have. Said plainly, because the alternative is a
    // reader wondering why the cost figures look wrong for the model they thought they chose.
    "model: \{shown.model_id} (unknown to this build; running on \{spec.id})"
  }
  "\{current} · available: \{@core.model_ids().join(", ")}"
}

///|
/// Switch a session's model, and record it in the session's log.
///
/// Appends a `model_change` entry rather than only changing the field, so the choice survives a
/// restart: the log is what a session is rebuilt from, and a session whose log says one model
/// while it runs another would come back wrong. The in-memory session is updated too, so the next
/// turn's `run_turn` sees the entry already there and does not append a second, contradictory one.
///
/// Does not re-render anything by itself: the caller passes the region list, because the same
/// change can arrive from the composer and from the picker.
async fn set_session_model(shown : Runner, id : String) -> Unit {
  let entry = @core.model_change_entry(
    "deepseek",
    id,
    shown.session.leaf_id,
    @env.now().reinterpret_as_int64(),
  )
  // The header goes in with the first entry, the same rule `commit` in the driver follows: a
  // session that is opened and never used is not worth a file. It matters more here than there,
  // because switching the model is something a reader can do *before* the first prompt — and
  // appending an entry to a file with no header produces a log that cannot be loaded at all.
  @platform.ensure_session(shown.path, shown.session.header)
  @platform.append_entry(shown.path, entry)
  shown.session = shown.session.add_entries([entry])
  shown.model_id = id
  let spec = @core.model_spec_for(id).0
  shown.status = "model: \{spec.label()}"
  // No refresh here: the picker that shows the model and the cost and context figures beside it
  // both change, and the caller is the one that knows what to re-render. It used to take the region
  // list as a parameter, which made this function's interface wider than the work it does.
}
