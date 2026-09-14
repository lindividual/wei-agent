///|
/// Rendering the conversation.
///
/// Two decisions shape everything here.
///
/// First, reasoning and tool calls are collapsed by default using the native
/// `<details>` element. The alternative — tracking which blocks are open in a
/// model — was worth several hundred lines in the client-side version of this UI,
/// and it bought nothing: the browser already knows how to remember that.
///
/// Second, nothing here holds state. A render call takes data and returns a
/// string; the question "what is on screen" is answered by asking the server.

///|
/// A short alias so `text(...)` stays available as a value name.
pub fn txt(value : String) -> Node {
  text(value)
}

///|
/// Render markdown, falling back to escaped text if the parser refuses.
///
/// A malformed document should degrade to showing the source, not to showing
/// nothing and not to taking the turn down.
///
/// `strict=false` is what turns on the extensions the answers actually use — most of all
/// tables, which a coding agent reaches for constantly (comparisons, parameters, file
/// lists) and which CommonMark alone renders as a paragraph of pipes. It also enables
/// strikethrough and task lists. `safe=true` still drops raw HTML, so the wider grammar
/// does not widen what a model can get the browser to execute.
pub fn markdown_or_text(source : String) -> Node {
  try @cmark_html.render(source, safe=true, strict=false) catch {
    _ => text(source)
  } noraise {
    html => raw(html)
  }
}

///|
/// One content block.
///
/// `id` lets a later patch target this block, which is how the streaming text
/// gets replaced with rendered markdown when it finishes.
pub fn render_block(id : String, block : @core.Content) -> Node {
  match block {
    @core.Text(source) =>
      el(Div, attrs=[cls("text"), attr("id", id)], children=[
        markdown_or_text(source),
      ])
    @core.Thinking(thinking~, ..) =>
      el(Details, attrs=[cls("thinking"), attr("id", id)], children=[
        el(Summary, children=[txt("thinking")]),
        el(Div, attrs=[cls("body")], children=[markdown_or_text(thinking)]),
      ])
    @core.ToolCall(name~, arguments~, ..) =>
      el(Details, attrs=[cls("tool"), attr("id", id)], children=[
        el(Summary, children=[txt(name)]),
        el(Pre, attrs=[cls("args")], children=[txt(arguments.stringify())]),
      ])
    @core.Image(..) =>
      el(Div, attrs=[cls("image")], children=[txt("(image attachment)")])
  }
}

///|

///|
/// The inside of a tool block: what it was asked to run, and what came back.
///
/// Factored out because a tool block is drawn the same way in three states — running, just
/// finished, and read back from the log — and the point of them looking alike is that a block does
/// not change shape when the tool ends. Two renderings of one thing drift; one rendering used
/// three times cannot.
fn tool_body(
  arguments : Json,
  result : @core.ToolResultMessage?,
  /// When the tool started, while there is no result yet.
  ///
  /// The clock lives here rather than in the summary because this is the line that says what is
  /// happening: `running… 6s` answers both halves of "is anything going on" in one place, and the
  /// summary is left as the bare name — which is also what a finished block's summary is, so a block
  /// does not even change its heading when the tool ends.
  ///
  /// `None` for a call the log has no result for at all — the process died before it finished. No
  /// start time was ever recorded for it, and inventing one would be a duration the reader could
  /// believe.
  since? : Int64? = None,
) -> Array[Node] {
  let children : Array[Node] = [
    el(Pre, attrs=[cls("args")], children=[txt(arguments.stringify())]),
  ]
  match result {
    Some(r) => {
      let classes = if r.is_error { "result error" } else { "result" }
      let body : Array[Node] = []
      for block in r.content {
        match block {
          @core.Text(source) =>
            body.push(el(Pre, attrs=[cls(classes)], children=[txt(source)]))
          _ => ()
        }
      }
      if body.is_empty() {
        body.push(el(Pre, attrs=[cls(classes)], children=[txt("(no output)")]))
      }
      children.push(el(Div, attrs=[cls("result-body")], children=body))
    }
    // No result yet: the tool is running, or the process died before it finished.
    // Either way the call is worth showing.
    None => {
      let pending : Array[Node] = [txt("running…")]
      match since {
        Some(start) => {
          pending.push(txt(" · "))
          // Rendered so the first paint is right — including for a browser that connects mid-tool —
          // and carried as `data-since` so the browser keeps it moving without a frame a second.
          pending.push(
            el(Time, attrs=[attr("data-since", "\{start}")], children=[
              txt(age_from(start)),
            ]),
          )
        }
        None => ()
      }
      children.push(el(Div, attrs=[cls("pending")], children=pending))
    }
  }
  children
}

///|
/// How long a block stays open once its result lands, before folding itself.
///
/// Not zero, because the result is the thing the reader was waiting for and arriving already
/// folded puts it behind a click. Not long, because a finished block that stays open is a wall of
/// output between the reader and the answer they asked for. A second is enough to read a line and
/// see that it worked.
///
/// It is a transient, not a state: the attribute is only on the frame that hands the result over, so
/// a page reloaded a moment later shows the block folded like every other finished one.
pub fn settle_ms() -> Int {
  1000
}

///|
/// A tool call together with the result that answered it.
///
/// Both live inside one `<details>` because that is how a reader thinks about
/// them: the call and what came back are one event, not two.
///
/// `settling` is the moment the result arrives: the block is rendered open, showing what came back,
/// and the client folds it after `settle_ms()`. Nothing else renders it open — the transcript a
/// reload builds, and the snapshot of a turn still running, both fold it like any finished tool.
pub fn render_tool(
  id : String,
  call : @core.Content,
  result : @core.ToolResultMessage?,
  settling? : Bool = false,
) -> Node {
  let (name, arguments) = match call {
    @core.ToolCall(name~, arguments~, ..) => (name, arguments)
    _ => ("tool", Json::null())
  }
  let attrs = [cls("tool"), attr("id", id)]
  if settling {
    attrs.push(attr("open", ""))
    attrs.push(attr("data-settle", settle_ms().to_string()))
  }
  el(Details, attrs~, children=[
    el(Summary, children=[txt(name)]),
    frag(tool_body(arguments, result)),
  ])
}

///|
/// A tool block while the tool is still running.
///
/// The same block as a finished one — same arguments, same body, same styling — and open, with a
/// clock in the summary. A `bash` call can take minutes, and minutes of a page that looks frozen is
/// the thing the whole live path exists to prevent, so the block is shown from the moment the tool
/// starts rather than from the moment it is over.
///
/// Shown open and *whole*: it used to render a one-line summary instead of the arguments, which made
/// a running block look like a thinner, different thing than the block it turns into. What a reader
/// is watching should not change shape under them when the tool ends.
///
/// The timer is both rendered here and carried as `data-since`. Rendering it means the number is
/// right on the first paint, including for a browser that connects mid-tool; the attribute is what
/// lets the browser keep it moving without the server sending a frame a second.
pub fn render_running_tool(
  id : String,
  name : String,
  arguments : Json,
  since : Int64,
  /// The finished block to put away as this one starts.
  ///
  /// An instruction for the browser rather than something the browser works out: the server knows
  /// which block is the newest finished one and where the fold is, and a client that had to derive
  /// that would be re-implementing the rule `render_running_exchange` already holds.
  file? : String? = None,
  file_into? : String = "",
) -> Node {
  let attrs = [cls("tool running"), attr("id", id), attr("open", "")]
  match file {
    Some(previous) => {
      attrs.push(attr("data-file", previous))
      attrs.push(attr("data-file-into", file_into))
    }
    None => ()
  }
  el(Details, attrs~, children=[
    // Just the name: the clock is on the `running…` line below, with the rest of what is happening.
    el(Summary, children=[txt(name)]),
    frag(tool_body(arguments, None, since=Some(since))),
  ])
}

///|
/// One unit of assistant output.
pub fn render_piece(id : String, piece : Piece) -> Node {
  match piece {
    Plain(block~) => render_block(id, block)
    Tool(call~, result~) => render_tool(id, call, result)
    Note(text~) =>
      el(Details, attrs=[cls("compaction"), attr("id", id)], children=[
        el(Summary, children=[txt("context compacted")]),
        el(Div, attrs=[cls("body")], children=[markdown_or_text(text)]),
      ])
  }
}

///|
/// What one turn took: the counts a reader uses to tell "did some work" from "did a lot",
/// and the figures the bar shows for a whole session, per turn instead of accumulated.
pub(all) struct TurnStats {
  model_calls : Int
  tool_calls : Int
  compactions : Int
  usage : @core.Usage
  /// The model's output was cut off at the token limit rather than finishing its answer.
  ///
  /// Carried here because the answer is already written by the time this is known, and a reply
  /// that stops mid-sentence with no explanation reads as the agent giving up.
  truncated : Bool
} derive(Eq, Debug)

///|
/// Why an answer ended, when it did not end because the model was done.
///
/// The wording is actionable rather than descriptive: the reader's next move is to ask for the
/// rest, and nothing in the transcript says how.
fn truncation_note() -> String {
  "output was cut off at the token limit — send \"continue\" to get the rest"
}

///|
/// The counting half of a turn's figures: how many calls it took.
///
/// Split out because the work fold's label wants exactly this much and none of the money, and a
/// second copy of the plural rules would be a second thing to keep true.
fn call_counts_text(stats : TurnStats) -> String {
  let out = StringBuilder()
  let plural = if stats.model_calls == 1 { "" } else { "s" }
  out.write_string(
    "\{stats.model_calls} model call\{plural}, \{tool_calls_phrase(stats.tool_calls)}",
  )
  if stats.compactions > 0 {
    out.write_string(", \{stats.compactions} compacted")
  }
  out.to_string()
}

///|
/// One turn's figures, as a reader reads them.
///
/// The cache share is the reason this exists: a session total hides it, because a cold start or
/// a compaction is averaged away over a long conversation. Per turn it is legible, which is what
/// makes it something the reader can act on.
pub fn turn_stats_text(stats : TurnStats) -> String {
  let out = StringBuilder()
  out.write_string(call_counts_text(stats))
  let usage = stats.usage
  if usage.total_tokens > 0 {
    out.write_string(
      " · \{compact_number(usage.input)} in / \{compact_number(usage.output)} out",
    )
    out.write_string(" · $\{@core.format_cost(usage.cost.total)}")
    match
      @core.format_cache_hit_percent(usage.cache_read, usage.billed_input()) {
      Some(percent) => out.write_string(" · \{percent}% cached")
      None => ()
    }
  }
  if stats.truncated {
    out.write_string(" · \{truncation_note()}")
  }
  out.to_string()
}

///|
/// A term and its value, the two halves of one row of the breakdown.
///
/// They are pushed straight into the `<dl>` rather than wrapped in a `<div>`: with
/// `grid-template-columns` on the list, `dt` and `dd` alternate into two columns on their own, and
/// a wrapper would make each row a single grid item and lose that.
fn stat_row(rows : Array[Node], term : String, value : String) -> Unit {
  rows.push(el(Dt, children=[txt(term)]))
  rows.push(el(Dd, children=[txt(value)]))
}

///|
/// What a turn's one-line summary is a summary *of*.
///
/// Every number here is already in the log; none of it is derived for the occasion. The split that
/// earns its place is the cost: `input` and `cache_read` are the same tokens billed at wildly
/// different rates, so a total says what a turn cost without saying what it was spent on, and the
/// reader who is deciding whether their next prompt should carry more context is asking the second
/// question.
pub fn turn_stats_detail(stats : TurnStats) -> Node {
  let rows : Array[Node] = []
  stat_row(rows, "model calls", stats.model_calls.to_string())
  stat_row(rows, "tool calls", stats.tool_calls.to_string())
  if stats.compactions > 0 {
    stat_row(rows, "compactions", stats.compactions.to_string())
  }
  let usage = stats.usage
  if usage.total_tokens > 0 {
    stat_row(rows, "input", "\{usage.input} tokens")
    if usage.cache_read > 0 {
      let share = match
        @core.format_cache_hit_percent(usage.cache_read, usage.billed_input()) {
        Some(percent) => " (\{percent}% of the prompt)"
        None => ""
      }
      stat_row(rows, "cached input", "\{usage.cache_read} tokens\{share}")
    }
    if usage.cache_write > 0 {
      stat_row(rows, "cache writes", "\{usage.cache_write} tokens")
    }
    stat_row(rows, "output", "\{usage.output} tokens")
    // Reported only by the models that expose it, and a row of zeroes would read as a measurement
    // rather than as an absence.
    match usage.reasoning {
      Some(reasoning) => stat_row(rows, "reasoning", "\{reasoning} tokens")
      None => ()
    }
    stat_row(rows, "total", "\{usage.total_tokens} tokens")
    let cost = usage.cost
    stat_row(rows, "cost · input", "$\{@core.format_cost(cost.input)}")
    if usage.cache_read > 0 {
      stat_row(rows, "cost · cache", "$\{@core.format_cost(cost.cache_read)}")
    }
    if usage.cache_write > 0 {
      stat_row(
        rows,
        "cost · cache writes",
        "$\{@core.format_cost(cost.cache_write)}",
      )
    }
    stat_row(rows, "cost · output", "$\{@core.format_cost(cost.output)}")
    // The four parts add up to this one, which is what makes the split worth having: the reader
    // can see *which* part of the turn the money went to, not only how much there was of it.
    stat_row(rows, "cost · total", "$\{@core.format_cost(cost.total)}")
  }
  el(Dl, attrs=[cls("stats-rows")], children=rows)
}

///|
/// The line under a finished reply, and the way into what it is made of.
///
/// The line is the same sentence a reader has always seen. What changed is that it is now a button
/// rather than a caption: the numbers behind it — how the prompt split between fresh and cached
/// input, what each part of the call cost — were already known and had nowhere to be read. A
/// `<details>` would have been the cheaper move, but the summary of a `<details>` cannot be
/// restyled into a line of figures sitting under an answer, and it puts its content in a box of its
/// own rather than under the line. So this is the other disclosure on the page: a button with
/// `data-expands`, the same one the live reasoning uses.
///
/// `id` names the panel, not the footer. Two turns on screen each need their own, and the id is how
/// the button and the panel find each other.
pub fn render_turn_footer(id : String, stats : TurnStats) -> Node {
  el(Div, attrs=[cls("turn-stats")], children=[
    el(
      Button,
      attrs=[
        cls("stats-open"),
        attr("type", "button"),
        attr("data-expands", id),
        attr("aria-expanded", "false"),
        attr("aria-controls", id),
      ],
      children=[txt(turn_stats_text(stats))],
    ),
    el(Div, attrs=[cls("stats-detail"), attr("id", id)], children=[
      turn_stats_detail(stats),
    ]),
  ])
}

///|
/// The figures for one turn's messages, read back from the log.
///
/// A reloaded transcript has to reach the same line the turn streamed, and the assistant
/// messages carry everything needed: one per model call, each with its own usage. The one thing
/// this cannot recover is a compaction call's own cost — the log keeps it on the compaction entry,
/// not on a message — so a turn that compacted reads as costing slightly less after a reload. It
/// is counted, just not priced.
pub fn turn_stats_of(messages : Array[@core.ContextMessage]) -> TurnStats {
  let mut model_calls = 0
  let mut tool_calls = 0
  let mut compactions = 0
  let mut usage = @core.Usage::zero()
  let mut truncated = false
  for message in messages {
    match message {
      @core.Assistant(assistant) => {
        model_calls += 1
        usage = usage.add(assistant.usage)
        // Overwritten per call, so it ends up describing the last one: an earlier answer that hit
        // the limit was superseded by whatever came after it.
        truncated = assistant.stop_reason is @core.Length
      }
      @core.ToolResult(_) => tool_calls += 1
      @core.CompactionSummary(..) => compactions += 1
      _ => ()
    }
  }
  { model_calls, tool_calls, compactions, usage, truncated, }
}

///|
/// The middle of a turn, folded away.
///
/// What is on the way to an answer is not the answer: tool calls, their results, and the model
/// narrating what it is about to do. All of it is kept — a reader checking what a turn actually did
/// is asking a real question, and throwing that away to make the page shorter would be answering
/// the wrong one. It is folded, not dropped, and the label says how much of it there is, so a
/// reader can tell a one-step turn from a twenty-step one without opening anything.
///
/// The label carries the call counts rather than just naming the fold, which is what makes the fold
/// worth looking at: the same answer arrived at in three calls and in thirty is the same text read
/// from two very different turns.

///|
/// A fold's label, as a node of its own so it can be replaced without the fold.
///
/// The live fold's label changes as tools are put away, and replacing the fold to change it would
/// throw away the blocks inside — which are there because the browser moved them there, not because
/// the server sent them.
pub fn render_work_label(id : String, label : String) -> Node {
  el(Summary, attrs=[attr("id", id)], children=[txt(label)])
}

///|
/// A turn's working, folded away.
pub fn render_work(
  id : String,
  label_id : String,
  label : String,
  blocks : Array[Node],
) -> Node {
  el(Details, attrs=[cls("work"), attr("id", id)], children=[
    render_work_label(label_id, label),
    frag(blocks),
  ])
}

///|
/// The fold a running turn puts its finished tools into.
///
/// One per turn, like the stream root. `render_running_exchange` builds the same fold from the same
/// pieces, which is what lets a browser that joins mid-turn keep receiving into it.
pub fn live_work_id(index : Int) -> String {
  "live-work-\{index}"
}

///|
/// That fold's label, which is replaced each time a tool goes in.
pub fn live_work_label_id(index : Int) -> String {
  "live-work-\{index}-label"
}

///|
/// "3 tool calls", with the plural in one place.
fn tool_calls_phrase(count : Int) -> String {
  "\{count} tool call\{if count == 1 { "" } else { "s" }}"
}

///|
/// What the live fold says on its summary line.
///
/// It names what is inside it rather than what the turn has cost: the figures are the status line's
/// job while a turn runs, and this line is a door — "there are three tools behind here" is what
/// makes it worth opening. The finished turn's fold says the same kind of thing with the whole
/// turn's counts (`call_counts_text`), which is a superset of this.
pub fn live_work_label(count : Int) -> String {
  "worked through \{tool_calls_phrase(count)}"
}

///|
/// A user message plus everything the assistant produced in response.
///
/// `user` is optional because a resumed transcript can start mid-conversation:
/// a compaction replaces the beginning, so the first thing on screen may be the
/// summary and the tail that was kept after it.
///
/// `stats`, when given, appends the line that says what the turn took. It is a
/// parameter rather than something derived here because a turn that is still running has
/// no finished figures — the caller that watched it stream is the one that knows them.
pub fn render_exchange(
  index : Int,
  user : String?,
  pieces : Array[Piece],
  stats? : TurnStats? = None,
) -> Node {
  // Which piece is the answer, and which are the work that produced it.
  //
  // The rule is "the last plain text", and it is a rule rather than a fact because a turn is not
  // shaped like one answer: the model writes something, calls a tool, writes again, several times.
  // The last text it wrote is the one it wants read. The distortion worth admitting is the turn
  // that ended in a tool call instead of in prose — a round limit, or a stop — which has no answer
  // to point at, so the last thing said before the tool shows instead. That is better than showing
  // nothing, and it is not a claim that the turn finished.
  let mut answer_at = -1
  for i in 0..<pieces.length() {
    match pieces[i] {
      Plain(block~) =>
        match block {
          @core.Text(_) => answer_at = i
          _ => ()
        }
      _ => ()
    }
  }
  let work : Array[Node] = []
  let answer : Array[Node] = []
  for i in 0..<pieces.length() {
    let node = render_piece("b\{index}-\{i}", pieces[i])
    if i == answer_at {
      answer.push(node)
    } else {
      work.push(node)
    }
  }
  let blocks : Array[Node] = []
  // Only when there is something to fold: a turn that was one answer would otherwise open with a
  // fold standing between the reader and the thing they came for.
  if !work.is_empty() {
    let label = match stats {
      Some(s) => "worked through \{call_counts_text(s)}"
      None => "what it did"
    }
    blocks.push(
      render_work(
        "exchange-\{index}-work",
        "exchange-\{index}-work-label",
        label,
        work,
      ),
    )
  }
  for node in answer {
    blocks.push(node)
  }
  let children : Array[Node] = []
  match user {
    Some(text) =>
      children.push(
        el(Div, attrs=[cls("user")], children=[markdown_or_text(text)]),
      )
    None => ()
  }
  children.push(el(Div, attrs=[cls("blocks")], children=blocks))
  match stats {
    Some(s) => children.push(render_turn_footer("stats-\{index}", s))
    None => ()
  }
  el(
    Section,
    attrs=[cls("exchange"), attr("id", "exchange-\{index}")],
    children~,
  )
}

///|
/// The notice that the session's last turn never finished, and the reader's two ways forward.
///
/// This is where an interrupted turn surfaces, and it is deliberately a **choice** rather than an
/// automatic resume. The reason is the one thing the log cannot tell us: the tool that was running
/// when the process died may already have changed a file, or may not have started. Results that were
/// recorded can be trusted and are not repeated, but the one in flight was never witnessed — so
/// resuming is a decision for the reader, who knows what the turn was doing, not something the
/// server should do on their behalf.
///
/// "Start fresh" is not a cancel: it closes the interrupted turn as abandoned, which is what stops
/// the notice from outliving the decision and keeps the log's "at most one turn open" invariant.
pub fn render_interrupted(prompt : String) -> Node {
  let children : Array[Node] = [
    el(P, children=[
      txt("the last turn was interrupted while working on: "),
      el(B, children=[txt(prompt)]),
    ]),
  ]
  children.push(
    el(Div, attrs=[cls("btn-row")], children=[
      el(
        Button,
        attrs=[
          cls("continue"),
          attr("type", "button"),
          attr("data-continue", "1"),
        ],
        children=[txt("Continue")],
      ),
      el(
        Button,
        attrs=[
          cls("dismiss"),
          attr("type", "button"),
          attr("data-dismiss", "1"),
        ],
        children=[txt("Start fresh")],
      ),
    ]),
  )
  el(Section, attrs=[cls("interrupted")], children~)
}

///|
/// The whole conversation, as sections.
///
/// Anchors are per user message, which is the unit a reader remembers. Compaction
/// summaries are shown where they happened: hiding them would make the transcript
/// look like it skipped a stretch of work for no reason, and the reader is the one
/// who has to know that older detail is now a summary.
///
/// Blocks are paired with their tool results at each boundary rather than once at
/// the end, because a summary can land in the middle — and pairing is what
/// guarantees a result is never shown without the call it answered.
pub fn render_transcript(
  messages : Array[@core.ContextMessage],
  /// Which session this transcript is of. The browser needs it to decide whether a patch it just
  /// received is for what it is showing.
  ///
  /// Deliberately not `data-session`: that attribute means "clicking this opens that session" to
  /// the sidebar's delegated click handler, and putting it on the transcript made *any* click in the
  /// conversation — opening a block, selecting text — ask the server to switch to it. The id it
  /// carries is short, so the server did not find a file by that name and started a new session
  /// instead: the transcript was replaced by an empty one on the next click.
  session? : String = "",
  /// Sections to append after the conversation — a turn that is still running, which the
  /// committed messages do not describe yet.
  extra? : Array[Node] = [],
  /// How many of the *newest* exchanges to render, or 0 for all of them.
  ///
  /// The cost of a transcript is dominated by its size — the HTML, the JSON frame it arrives in, and
  /// every node the browser builds from it — and a reader almost always wants the end of a
  /// conversation, not its beginning. Measured on a real 14-turn session, the newest six exchanges
  /// are a third of the bytes and a third of the nodes, which is most of what a switch costs.
  ///
  /// What is dropped is not lost: the count of what is missing is rendered as a control at the top,
  /// and raising the limit is a request, not a scroll. Deliberately not scroll-driven — scroll-based
  /// loading needs a notion of "already loaded" that has to survive refreshes, reconnects and
  /// session switches, and that state is where the bugs are.
  limit? : Int = 0,
) -> Node {
  let sections : Array[Node] = []
  let mut user : String? = None
  let mut pieces : Array[Piece] = []
  let blocks : Array[@core.Content] = []
  let results : Array[@core.ToolResultMessage] = []
  // The turn's figures, accumulated as its messages are walked and flushed with it. Read
  // back from the log rather than remembered, so a transcript reloaded from disk shows the
  // same line as the one the turn streamed.
  let mut model_calls = 0
  let mut tool_calls = 0
  let mut compactions = 0
  let mut usage = @core.Usage::zero()
  let mut truncated = false
  // Every exchange is *collected* as it is walked, and only the last few are rendered. Collecting is
  // cheap — it holds the pieces the session already has, not new strings — and it removes the need to
  // predict how many exchanges there are, which is the kind of arithmetic that was wrong twice while
  // this was being written: the last exchange is flushed after the loop rather than inside it, so
  // counting user messages and counting rendered exchanges do not agree.
  let exchanges : Array[(Int, String?, Array[Piece], TurnStats)] = []
  let mut index = 0
  for message in messages {
    match message {
      @core.User(m) => {
        drain(pieces, blocks, results)
        // The index is carried, not renumbered, so a rendered exchange keeps the id it had while it
        // was streaming: a patch that targets `exchange-13-blocks` has to find it under that name
        // whether or not the turns before it were rendered.
        collect(exchanges, index, user, pieces, {
          model_calls,
          tool_calls,
          compactions,
          usage,
          truncated,
        })
        index += 1
        user = Some(user_text(m))
        pieces = []
        model_calls = 0
        tool_calls = 0
        compactions = 0
        usage = @core.Usage::zero()
        truncated = false
      }
      @core.Assistant(assistant) => {
        model_calls += 1
        usage = usage.add(assistant.usage)
        truncated = assistant.stop_reason is @core.Length
        for block in assistant.content {
          blocks.push(block)
        }
      }
      @core.ToolResult(result) => {
        tool_calls += 1
        results.push(result)
      }
      @core.CompactionSummary(summary~, ..) => {
        compactions += 1
        drain(pieces, blocks, results)
        pieces.push(Note(text=summary))
      }
      _ => ()
    }
  }
  drain(pieces, blocks, results)
  collect(exchanges, index, user, pieces, {
    model_calls,
    tool_calls,
    compactions,
    usage,
    truncated,
  })
  // The last `limit` of them, or all of them. No arithmetic beyond a subtraction, and the count the
  // control reports is the count that was withheld.
  let from = if limit > 0 && exchanges.length() > limit {
    exchanges.length() - limit
  } else {
    0
  }
  for node in render_exchanges(exchanges, from) {
    sections.push(node)
  }
  // The way back to what was left out, at the top, where the missing turns would have been. Its
  // presence is also the honest signal that this is not the whole conversation.
  if from > 0 {
    sections.insert(0, render_earlier(from))
  }
  for node in extra {
    sections.push(node)
  }
  // Nothing said and nothing running: the page would otherwise be empty, which is the one state
  // where a reader has no way to find out what the page is for. `extra` is checked by having been
  // pushed above — a running turn or an interrupted-turn notice is something to look at, and the
  // welcome would be talking over it.
  if sections.is_empty() {
    sections.push(render_welcome())
  }
  el(
    Div,
    // `data-shown-session`, not `data-session`: the sidebar's delegated click handler treats
    // `[data-session]` as "open that session", and this attribute only says which session the
    // fragment is of.
    attrs=[attr("id", "transcript"), attr("data-shown-session", session)],
    children=sections,
  )
}

///|
/// What a conversation with nothing in it says.
///
/// A blank page teaches nothing. A reader who arrives before the first message has no way to know
/// what this can do, and the three things it understands that are not prose — `/name`, `/model`,
/// `/skill:` — appear nowhere on it. This is the one moment the page has their attention and
/// nothing to show, so it is where the explanation goes, and it goes away on its own as soon as
/// there is something to read instead.
///
/// The examples are buttons rather than sentences. The reader's next move is to type something, and
/// retyping a suggestion a character at a time is a tax on the one action this page wants from
/// them. They fill the composer rather than sending: sending a message on someone's behalf is not
/// this page's decision to make.
pub fn render_welcome() -> Node {
  let examples = [
    "What does this project do?", "Run the tests and tell me what fails", "What changed in the last few commits?",
  ]
  let buttons : Array[Node] = []
  for example in examples {
    buttons.push(
      el(
        Button,
        attrs=[
          cls("example"),
          attr("type", "button"),
          attr("data-fill", example),
        ],
        children=[txt(example)],
      ),
    )
  }
  el(Div, attrs=[cls("welcome")], children=[
    el(P, attrs=[cls("lead")], children=[
      txt(
        "Ask anything about this workspace. It can read files, run commands and make changes.",
      ),
    ]),
    el(Div, attrs=[cls("examples")], children=buttons),
    el(P, attrs=[cls("hint")], children=[
      txt("Type "),
      el(Span, attrs=[cls("key")], children=[txt("/")]),
      txt(" for commands · "),
      el(Span, attrs=[cls("key")], children=[txt("⌘↵")]),
      txt(" to send"),
    ]),
  ])
}

///|
/// The control that brings back the turns that were not rendered.
///
/// It says how many are missing rather than just "more", because a reader deciding whether to spend
/// the load wants to know how much conversation is above them.
pub fn render_earlier(count : Int) -> Node {
  el(Div, attrs=[cls("earlier")], children=[
    el(
      Button,
      attrs=[
        cls("earlier-button"),
        attr("type", "button"),
        attr("data-earlier", ""),
      ],
      children=[
        txt(
          if count == 1 {
            "1 earlier turn"
          } else {
            "\{count} earlier turns"
          },
        ),
      ],
    ),
  ])
}

///|
/// A piece of a turn that is still arriving.
///
/// The ids are the ones the live patches use as their targets, which is what lets a
/// snapshot of a running turn be continued by the stream rather than replaced by it.
pub(all) enum LivePiece {
  Text(id~ : String, text~ : String)
  Thinking(id~ : String, text~ : String)
  Tool(id~ : String, call~ : @core.Content, result~ : @core.ToolResultMessage)
  /// A tool that is running right now.
  ///
  /// This is its own variant because `Tool` cannot say "running": its result is not optional, so a
  /// half-finished tool has no value of that shape at all. Leaving it out of the snapshot is not a
  /// display glitch — the finished block is patched in *at the running block's id*, the client
  /// drops a patch whose target is missing (`if (!node) return`), and the tool's output would never
  /// appear while every byte-level assertion still passed. That is the failure class ADR-0004 was
  /// written about, so the running state is represented rather than inferred.
  ///
  /// `since` is the tool's own start, not the turn's: a turn that has run three tools would
  /// otherwise show the third one as having run for as long as the turn.
  RunningTool(
    id~ : String,
    name~ : String,
    /// The call as the model wrote it — the same thing the finished block puts in its `<pre>`.
    arguments~ : Json,
    since~ : Int64
  )
} derive(Eq, Debug)

///|
/// A running turn, as far as it has got: the reader's message, and a container holding
/// everything the model has produced so far.
///
/// Rendered from the server's record of the turn rather than from the DOM, so a browser
/// that arrives in the middle — or comes back to it — sees the same thing as one that has
/// been there all along.
pub fn render_running_exchange(
  index : Int,
  user : String,
  pieces : Array[LivePiece],
) -> Node {
  // Which finished tools are put away, and which is left out.
  //
  // The newest finished tool stays outside, and every older one is in the fold. That is the rule
  // whether or not a tool is running, and it has to be, because it has to match what the streaming
  // path did a moment ago: the newest finished tool is the one whose result the reader is looking at,
  // and it is put away only when the *next* tool starts — at which point it stops being the newest.
  //
  // Making the rule depend on whether a tool is running would put a block in the fold for the second
  // between one tool finishing and the next starting, so a reader who reloaded inside that second
  // would see folded what everyone else is still looking at.
  let finished : Array[String] = []
  for piece in pieces {
    match piece {
      Tool(id~, ..) => finished.push(id)
      _ => ()
    }
  }
  let filed = if finished.length() > 0 { finished.length() - 1 } else { 0 }
  // The folded blocks, collected in the same pass that counts them, so "which are inside" and "what
  // is inside" cannot come apart.
  let filed_nodes : Array[Node] = []
  for piece in pieces {
    match piece {
      Tool(id~, call~, result~) =>
        if filed_nodes.length() < filed {
          filed_nodes.push(render_tool(id, call, Some(result)))
        }
      _ => ()
    }
  }
  let fold = if filed_nodes.is_empty() {
    Node::Empty
  } else {
    render_work(
      live_work_id(index),
      live_work_label_id(index),
      live_work_label(filed_nodes.length()),
      filed_nodes,
    )
  }
  let children : Array[Node] = []
  let mut placed = false
  let mut seen_tools = 0
  for piece in pieces {
    match piece {
      Text(id~, text~) =>
        children.push(
          el(Div, attrs=[cls("text"), attr("id", id)], children=[
            Node::Text(text),
          ]),
        )
      Thinking(id~, text~) =>
        children.push(render_thinking_stream(id, "\{id}-body", text~))
      // The fold takes the place of the first tool that went into it, so everything that came before
      // the tools stays before them and everything after stays after.
      Tool(id~, call~, result~) => {
        if seen_tools < filed {
          if !placed {
            children.push(fold)
            placed = true
          }
        } else {
          children.push(render_tool(id, call, Some(result)))
        }
        seen_tools += 1
      }
      RunningTool(id~, name~, arguments~, since~) =>
        children.push(render_running_tool(id, name, arguments, since))
    }
  }
  el(Section, attrs=[cls("exchange"), attr("id", exchange_id(index))], children=[
    el(Div, attrs=[cls("user")], children=[markdown_or_text(user)]),
    el(Div, attrs=[cls("blocks"), attr("id", blocks_id(index))], children=[
      el(Div, attrs=[attr("id", "streams-\{index}")], children~),
    ]),
  ])
}

///|
/// The pieces of the reply that follows the last user message.
///
/// The tail is all that is needed to redraw one exchange when a turn ends: the
/// earlier turns are already on screen, and re-sending them would duplicate them.
pub fn reply_pieces(messages : Array[@core.ContextMessage]) -> Array[Piece] {
  let mut start = 0
  for i in 0..<messages.length() {
    if messages[i] is @core.User(_) {
      start = i
    }
  }
  let blocks : Array[@core.Content] = []
  let results : Array[@core.ToolResultMessage] = []
  for i in start..<messages.length() {
    match messages[i] {
      @core.Assistant(assistant) =>
        for block in assistant.content {
          blocks.push(block)
        }
      @core.ToolResult(result) => results.push(result)
      _ => ()
    }
  }
  pair_tools(blocks, results)
}

///|
/// Move the collected blocks and results into `pieces`, paired.
///
/// Arrays are references, so this empties the accumulators it was given: the next
/// stretch of the conversation starts clean without the caller having to remember
/// to reset them.
fn drain(
  pieces : Array[Piece],
  blocks : Array[@core.Content],
  results : Array[@core.ToolResultMessage],
) -> Unit {
  for piece in pair_tools(blocks, results) {
    pieces.push(piece)
  }
  blocks.clear()
  results.clear()
}

///|
fn collect(
  exchanges : Array[(Int, String?, Array[Piece], TurnStats)],
  index : Int,
  user : String?,
  pieces : Array[Piece],
  stats : TurnStats,
) -> Unit {
  if user is None && pieces.is_empty() {
    return
  }
  exchanges.push((index, user, pieces, stats))
}

///|
/// The exchanges from `from` onward, rendered.
///
/// Split out so the walk above never has to know how many there are: it collects, and this decides
/// what is shown.
fn render_exchanges(
  exchanges : Array[(Int, String?, Array[Piece], TurnStats)],
  from : Int,
) -> Array[Node] {
  let out : Array[Node] = []
  for i in from..<exchanges.length() {
    let (index, user, pieces, stats) = exchanges[i]
    out.push(render_exchange(index, user, pieces, stats=Some(stats)))
  }
  out
}

///|
/// The text of a user message, joined across its parts.
pub fn user_text(message : @core.UserMessage) -> String {
  let out = StringBuilder()
  for block in message.content {
    match block {
      @core.Text(text) => {
        if out.to_string() != "" {
          out.write_string("\n")
        }
        out.write_string(text)
      }
      @core.Image(..) => {
        if out.to_string() != "" {
          out.write_string("\n")
        }
        out.write_string("(image attachment)")
      }
      _ => ()
    }
  }
  out.to_string()
}

///|
/// The page shell.
///
/// `style` and `client` are inlined rather than served as separate files: the
/// whole point of this design is one binary with no build step and no asset
/// directory to get out of sync.
pub fn render_page(
  title : String,
  style : String,
  client : String,
  body : Array[Node],
) -> Node {
  el(Html, attrs=[attr("lang", "en")], children=[
    el(Head, children=[
      el(Meta, attrs=[attr("charset", "utf-8")]),
      el(Meta, attrs=[
        attr("name", "viewport"),
        attr("content", "width=device-width, initial-scale=1"),
      ]),
      el(Title, children=[txt(title)]),
      el(Style, children=[raw(style)]),
    ]),
    el(Body, children=[frag(body), el(Script, children=[raw(client)])]),
  ])
}

// ── Incremental rendering ──────────────────────────────────────────────────
//
// The transcript is built up in two steps per turn: the user's message appears
// as soon as it is sent, and the reply is appended into the same section when the
// turn finishes. Appending rather than replacing the section is what keeps
// scroll position and any `<details>` the reader opened exactly as they were.

///|
pub fn exchange_id(index : Int) -> String {
  "exchange-\{index}"
}

///|
pub fn blocks_id(index : Int) -> String {
  "exchange-\{index}-blocks"
}

///|
/// The user's message plus an empty container for the reply to land in.
///
/// `user` is optional for the same reason `render_exchange` takes one: a resumed
/// transcript can start with a summary rather than with something the user typed.
pub fn render_exchange_start(index : Int, user : String?) -> Node {
  let children : Array[Node] = []
  match user {
    Some(text) =>
      children.push(
        el(Div, attrs=[cls("user")], children=[markdown_or_text(text)]),
      )
    None => ()
  }
  children.push(el(Div, attrs=[cls("blocks"), attr("id", blocks_id(index))]))
  el(
    Section,
    attrs=[cls("exchange"), attr("id", exchange_id(index))],
    children~,
  )
}

///|
/// A container for reasoning that is still arriving.
///
/// Reasoning is collapsed once it is finished, but a model that thinks for a minute must not look
/// like a frozen page. The three states a reader wants while it is arriving — the newest few lines,
/// all of it, out of the way — are one more than a `<details>` has, so the streaming shape is not
/// one. What is shown by default is the *end* of the text, which is why the box is anchored to its
/// end in `theme.mbt` rather than merely clipped.
///
/// Not a `<details>` for a second reason too: the one thing that element remembers is whether it is
/// open, and that is exactly the state that must *not* survive here. When the turn ends the whole
/// region is replaced by the finished rendering, which is collapsed whatever the reader did. The
/// finished rendering stays a `<details>`; this is only ever the shape of a turn in flight.
pub fn render_thinking_stream(
  id : String,
  body_id : String,
  /// What has arrived so far. Empty while it is the first thing being streamed.
  text? : String = "",
) -> Node {
  el(Div, attrs=[cls("thinking live"), attr("id", id)], children=[
    el(
      Button,
      attrs=[
        cls("head"),
        attr("type", "button"),
        // The id of the block this opens, not the block itself: the button instructs, the
        // `data-expanded` attribute on the block is the state. `ui/assets.mbt` reads it — one
        // handler serves every disclosure on the page that is not a `<details>`.
        attr("data-expands", id),
        attr("aria-expanded", "false"),
        // Named, so a reader who cannot see the layout is not left with a bare "thinking…"
        // followed by unattributed text.
        attr("aria-controls", body_id),
      ],
      children=[txt("thinking…")],
    ),
    el(Div, attrs=[cls("body"), attr("id", body_id)], children=[
      Node::Text(text),
    ]),
  ])
}

///|
/// The figures on the right of the bar, as their own element.
///
/// Wrapped and given an id because those are the chips a turn changes — usage, cost, how full the
/// context is — and they are refreshed several times per turn. Replacing the whole bar to move a
/// number would take the rest of it down with them, including the settings panel the reader may
/// be typing in.
pub fn render_usage(chips : Array[Node]) -> Node {
  el(Span, attrs=[cls("usage"), attr("id", "usage")], children=chips)
}

///|
/// The information bar above the conversation: what is open, on what model, at what cost.
///
/// A region of its own rather than part of the transcript, because it changes for reasons
/// the transcript does not (a figure updating, a session being switched) and replacing the
/// whole conversation to refresh a number would be absurd.
///
/// `trailing` is for the settings panel: it belongs at this end of the bar, and it must survive a
/// refresh of `right`, which is why the chips are wrapped in their own element rather than
/// replaced as part of the bar.
pub fn render_bar(
  left : Array[Node],
  right? : Array[Node],
  trailing? : Array[Node],
) -> Node {
  let children : Array[Node] = left
  children.push(el(Span, attrs=[cls("spacer")], children=[]))
  children.push(render_usage(right.unwrap_or([])))
  for node in trailing.unwrap_or([]) {
    children.push(node)
  }
  el(Div, attrs=[cls("bar"), attr("id", "bar")], children~)
}

///|
/// One line of the composer's command list.
pub(all) struct CommandHint {
  /// What gets put in the composer. Ends with a space where an argument is expected.
  insert : String
  /// What it does, in the reader's words.
  what : String
} derive(Eq, Debug)

///|
/// The list that appears while the composer holds something trying to be a command.
///
/// Not a `<datalist>`, which would have been the zero-script answer: the `list` attribute is
/// honoured on `<input>` and ignored on `<textarea>`, and the composer is a textarea because a
/// prompt is allowed to be more than one line. So these are ordinary buttons and the script decides
/// when they are worth showing.
///
/// Hidden in the markup rather than left for the script to hide: a reader with no script would
/// otherwise meet the whole list at once, permanently, under the box they are typing in.
pub fn render_commands(hints : Array[CommandHint]) -> Node {
  let rows : Array[Node] = []
  for hint in hints {
    rows.push(
      el(
        Button,
        attrs=[
          attr("type", "button"),
          cls("command"),
          attr("data-fill", hint.insert),
          // The description is clipped to one line, so the whole of it goes in the tooltip: a
          // skill's description is a paragraph and a menu row is a row. Without the clip, typing
          // `/` in a workspace with a dozen skills replaces the page with a list taller than the
          // window — a menu that has to be scrolled is not a menu.
          attr("title", hint.what),
        ],
        children=[
          el(Span, attrs=[cls("cmd")], children=[
            txt(hint.insert.trim().to_owned()),
          ]),
          el(Span, attrs=[cls("what")], children=[
            txt(clip_label(hint.what, limit=90)),
          ]),
        ],
      ),
    )
  }
  el(Div, attrs=[attr("id", "commands"), attr("hidden", "")], children=rows)
}

///|
/// The composer, which lives outside the transcript so that replacing the transcript never
/// touches what the reader is typing.
///
/// `running` decides whether Stop is offered. The button used to be live in every state and do
/// nothing when there was nothing to stop: a control that lies about being available is worse than
/// one that is absent, and the state it lies about is the one the reader reaches for in a hurry.
/// The button is replaced on its own (see `stop_node`) rather than with the form around it, for the
/// same reason the textarea is never touched.
pub fn composer(
  model : ModelPicker,
  running : Bool,
  hints : Array[CommandHint],
) -> Node {
  el(Form, attrs=[attr("id", "composer")], children=[
    // First, so the list opens *above* the box rather than below the buttons: the reader's eyes are
    // already at the bottom of the page, and suggestions belong between what they are writing and
    // the answer they are waiting for.
    render_commands(hints),
    el(Textarea, attrs=[
      attr("id", "prompt"),
      attr("rows", "2"),
      attr("placeholder", "Ask something… (Cmd+Enter to send)"),
      attr("autofocus", ""),
    ]),
    el(Button, attrs=[attr("id", "send"), attr("type", "submit")], children=[
      txt("Send"),
    ]),
    stop_button(running),
    render_model_picker(model),
  ])
}

///|
/// The Stop button, on its own so that a turn starting or ending can replace it without
/// disturbing the box the reader is typing in.
pub fn stop_button(running : Bool) -> Node {
  let attrs = [
    attr("id", "stop"),
    attr("type", "button"),
    attr("data-abort", ""),
    attr(
      "title",
      if running {
        "stop this turn"
      } else {
        "nothing is running in this session"
      },
    ),
  ]
  if !running {
    attrs.push(attr("disabled", ""))
  }
  el(Button, attrs~, children=[txt("Stop")])
}

///|
/// What the picker next to the composer needs.
pub(all) struct ModelPicker {
  /// The model this session is on, which is what the picker shows closed.
  current_id : String
  /// Every model it can switch to. One selection is a submit; there is no Apply to press, because
  /// there is exactly one choice to make and a second step would only be a way to forget it.
  models : Array[@core.ModelSpec]
  /// True while a turn is running. The picker is then shown but disabled: a model change is an
  /// entry in the session's log, and the running turn is appending off its own leaf — the change
  /// would land on a branch nobody walks. Disabled rather than hidden, so the control does not
  /// move around while the reader is reaching for it.
  locked : Bool
} derive(Eq, Debug)

///|
/// The model picker: a `<select>` in the composer's bottom-right corner.
///
/// A select rather than a details-with-buttons, because it is the one control on the page that the
/// browser has an opinion about: it opens the way the platform opens menus, it is reachable by
/// keyboard, and it closes itself on the platform's terms. `onchange` submits — one interaction,
/// which is the point of putting it where the reader's hand already is.
///
/// It is a region of its own (`#model-picker`), so switching a session rebuilds it without
/// touching what the reader is typing.
///
/// `name="model"` and a value per option are what makes the form-encoded body a single field; the
/// handler reads the id from it. `disabled` during a turn is not cosmetic: the entry it appends
/// would fork the log.
pub fn render_model_picker(picker : ModelPicker) -> Node {
  let options : Array[Node] = []
  for model in picker.models {
    let attrs : Array[Attr] = [attr("value", model.id)]
    if model.id == picker.current_id {
      attrs.push(attr("selected", ""))
    }
    options.push(el(Option, attrs~, children=[txt(model.label())]))
  }
  let attrs : Array[Attr] = [
    attr("id", "model-picker"),
    attr("name", "model"),
    attr("aria-label", "model"),
    attr(
      "title",
      if picker.locked {
        "cannot change the model while a turn is running"
      } else {
        "the model this session runs on"
      },
    ),
  ]
  if picker.locked {
    attrs.push(attr("disabled", ""))
  }
  el(Select, attrs~, children=options)
}

///|
/// A status line for the reader — shown while a turn runs, so a slow model does
/// not look like a frozen page.
pub fn render_status(text_value : String) -> Node {
  el(Div, attrs=[cls("status"), attr("id", "status")], children=[
    txt(text_value),
  ])
}
