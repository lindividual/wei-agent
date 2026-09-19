///|
/// The events: what the host is told, one function per event.
///
/// One function per event, so each field name exists in exactly one place, and the shape is
/// deliberately flat: a host-side `Codable` struct per `kind` is the whole of the Swift side's
/// decoding, and there is no schema to keep in step beyond these names. The `say_` that knows
/// something happened and the `_event` that shapes its fields are
/// adjacent on purpose — a field named in one and not the other is a host that draws nothing from it.
///
/// Here is everything that leaves the process, plus the few things that exist only to fill a field:
/// how the prompt was built and how full the window is, which the `usage` row reports and `turn.mbt`
/// reads as well. What is *only* a turn's own accounting — the name each of its rows carries, the
/// sentence it ends with — is in `turn.mbt`, beside the turn that makes it.
///
/// Split out of `app.mbt` when that file passed three thousand lines; nothing but text moved.

///|
/// Every event carries its `kind` first, because that is what the host switches on.
fn event(kind : String, fields : Array[(String, Json)]) -> Json {
  let pairs : Array[(String, Json)] = [("kind", Json::string(kind))]
  for field in fields {
    pairs.push(field)
  }
  Json::object(Map(pairs))
}

///|
/// A fact about one session, with the session named.
///
/// Naming it is what makes more than one turn possible at a time: the host draws a transcript per
/// session, and a delta it cannot place is a delta it would have to write into whatever happens to be
/// on screen — which is exactly the failure this field prevents, and one that only appears once two
/// conversations are moving at once.
///
/// An **empty** `session` means "the one on screen", and that is deliberate rather than lazy: most of
/// what the shell says is an answer to something the reader just did to the session they are looking
/// at (a bad path, an unknown model), and those need no name to be understood. Only a running turn has
/// to say where it belongs, because a running turn is the one thing that can be about a conversation
/// nobody is looking at.
fn session_event(
  path : String,
  kind : String,
  fields : Array[(String, Json)],
) -> Json {
  let pairs : Array[(String, Json)] = [
    ("kind", Json::string(kind)),
    ("session", Json::string(path)),
  ]
  for field in fields {
    pairs.push(field)
  }
  Json::object(Map(pairs))
}

///|
/// The session that is open, and what a reader needs to know about it. Sent first, and again
/// whenever one of those four facts changes — saving a key is what made it a snapshot rather than a
/// greeting, because the window a key saves is a window that can send again.
fn Shell::say_ready(self : Shell, open : Open, key_source : String) -> Unit {
  self.emit(ready_event(open, key_source))
}

///|
/// The `ready` event, from the facts rather than from the shell.
///
/// Split out for the reason the others are: the field names are the contract with the host, and a
/// contract that can only be asserted by standing up a whole shell is one nobody asserts.
fn ready_event(open : Open, key_source : String) -> Json {
  session_event(open.path, "ready", [
    ("model", Json::string(model_name(open))),
    ("cwd", Json::string(open.cwd)),
    // Named rather than implied: an empty key is a thing the host has to say out loud, and
    // "where did the key come from" is the question the first failure always raises.
    ("key", Json::string(key_source)),
  ])
}

///|
/// The prompt, echoed so the host can put it in the conversation without having kept its own
/// copy of what it sent.
///
/// `images` are the pictures that went out with it, **carried with the prompt rather than as an event
/// of their own**: they are part of the question, the shell takes them off the composer in the same
/// breath, and a separate event would be a second thing for the host to keep in step with a question
/// that may already be drawn.
fn Shell::say_user(
  self : Shell,
  path : String,
  text : String,
  continued? : Bool = false,
  images? : Array[(String, String)] = [],
) -> Unit {
  self.emit(user_event(path, text, continued, images))
}

///|
/// The prompt, echoed, as the wire carries it.
///
/// The routing `session` comes from here rather than being written into the test: a `user` event is
/// about a conversation, and the prompt for a turn in a background session has to land in that
/// session's transcript rather than in whichever one happens to be on screen.
fn user_event(
  path : String,
  text : String,
  continued : Bool,
  images : Array[(String, String)],
) -> Json {
  session_event(path, "user", user_fields(text, continued, images))
}

///|
/// The fields of a `user` event, as a pure function.
///
/// Split out from `say_user` because the emit path cannot be asserted (nothing here defines
/// `wei_emit`) and this is a **rule**: whether a prompt was a `/skill:<name>` command, and what the
/// three parts of it are, is the decision the whole transcript hangs on — a host that is told the
/// wrong thing about it draws a page of somebody else's instructions as the reader's own sentence.
fn user_fields(
  text : String,
  continued : Bool,
  images : Array[(String, String)],
) -> Array[(String, Json)] {
  let pictures : Array[Json] = []
  for (mime_type, data) in images {
    pictures.push(image_row(mime_type, data))
  }
  let fields : Array[(String, Json)] = [
    ("text", Json::string(text)),
    // A continued turn carries a prompt the host has already seen: it is the last user message in
    // the log, and appending it again would put the question on screen twice. The flag is what
    // lets the host start a new turn — with a new set of row names — without drawing a second
    // question.
    ("continued", Json::boolean(continued)),
    ("images", Json::array(pictures)),
  ]
  // A `/skill:<name>` prompt is the shell's own framing with the skill's whole document inside it —
  // thousands of characters the reader never typed and should not have drawn at them. The three
  // parts go over as written when the prompt is one, so the host can show the command and fold the
  // body; a prompt that is not a framing adds nothing, and **no field at all** is what says so
  // rather than a flag whose false is the same fact as its absence.
  //
  // `text` still goes over whole, and deliberately: it is what the model was asked, which is what a
  // wire log is for and what an older host draws. The host's own history takes the same message apart
  // with the same function (`core.skill_expansion_parts`), so a replayed turn and a live one cannot
  // disagree about where the reader's words are.
  match @core.skill_expansion_parts(text) {
    Some((name, args, body)) =>
      fields.push(
        (
          "skill",
          Json::object(
            Map([
              ("name", Json::string(name)),
              ("args", Json::string(args)),
              ("body", Json::string(body)),
            ]),
          ),
        ),
      )
    None => ()
  }
  fields
}

///|
/// A block of the answer, or of the reasoning, as it streams.
///
/// Deltas under one `id` rather than one string per frame: that is what makes the host's append
/// cheap, and it is the same decision the web UI made when a replacement-per-delta turned out to
/// be quadratic.
fn Shell::say_piece(
  self : Shell,
  path : String,
  kind : String,
  id : String,
  delta : String,
) -> Unit {
  self.emit(piece_event(path, kind, id, delta))
}

///|
/// One delta of a streaming block, as the wire carries it.
fn piece_event(
  path : String,
  kind : String,
  id : String,
  delta : String,
) -> Json {
  session_event(path, kind, [
    ("id", Json::string(id)),
    ("delta", Json::string(delta)),
  ])
}

///|
/// A block that has stopped growing, and how to draw it.
///
/// The shell does the parsing because the host cannot: `AttributedString(markdown:)` takes the source
/// rather than a parse, so a table arrives as its own punctuation and a fenced block loses its
/// language. `md/` is cmark — the same engine the web UI renders with — so both front ends have the
/// same opinion about the same answer, which is the whole reason it is a shared package.
///
/// The parse is done here and *diffed*: the host keeps the blocks it has already been given, so what
/// crosses is the part that changed. The web UI sent the whole block once, at the end, because a host
/// that cannot keep a parse has to be given one; this one can, which is what makes rendering the
/// answer while it arrives affordable.
///
/// This is called where a block stops being the newest thing that happened — a tool call, the other
/// kind of text, or the end of the turn — which are exactly the moments the host stops appending to
/// that row. It is the one parse of the whole block; everything before it was the tail.
fn Shell::say_blocks(
  self : Shell,
  path : String,
  id : String,
  text : String,
  live : LiveMarkdown?,
) -> Unit {
  if id == "" || text == "" {
    return
  }
  let blocks = @md.parse(text)
  let from = match live {
    Some(state) if state.id == id => @md.diff_prefix(state.sent, blocks)
    _ => 0
  }
  self.say_blocks_from(path, id, from, blocks)
}

///|
/// Blocks `from` onwards, for a row the host already has the head of.
///
/// `from` is the number of leading blocks the host is holding, and it is a protocol field rather than
/// an implementation detail: a host that does not know about it would append the tail to a document
/// it never received the head of. The field is therefore required to be understood, and a host that
/// cannot apply it drops the frame rather than guessing (`WeiModel`'s `Conversation.apply`).
///
/// An **empty** tail is a real frame and is sent as one: it is how a block that turned out shorter
/// than its own prefix is corrected. Nothing in the live path sends one — `live_frame` refuses a frame
/// with nothing new — so this is the shape only the end of a block has.
fn Shell::say_blocks_from(
  self : Shell,
  path : String,
  id : String,
  from : Int,
  blocks : Array[@md.Block],
) -> Unit {
  if id == "" {
    return
  }
  self.emit(blocks_event(path, id, from, blocks))
}

///|
/// One `blocks` frame, as the wire carries it.
///
/// Takes the whole parse and the index the host has up to, rather than a pre-cut tail: which blocks
/// are the tail is the same fact as the `from` field, and deriving them in two places is how a frame
/// comes to say `from: 4` and carry five blocks.
fn blocks_event(
  path : String,
  id : String,
  from : Int,
  blocks : Array[@md.Block],
) -> Json {
  let tail : Array[Json] = []
  for index in from..<blocks.length() {
    tail.push(blocks[index].to_json())
  }
  session_event(path, "blocks", [
    ("id", Json::string(id)),
    ("from", Json::number(from.to_double(), repr=from.to_string())),
    ("blocks", Json::array(tail)),
  ])
}

///|
/// One live frame, as the wire carries it.
///
/// The same `blocks` kind as the finished one above, and the same routing field: a frame from a turn
/// in a background session has to land in *that* transcript. It differs only in that a frame carries
/// the tail from `from` while `blocks_event` cuts the tail itself, which is why there are two.
fn blocks_frame_event(path : String, frame : LiveFrame) -> Json {
  session_event(path, "blocks", frame.fields())
}

///|
/// Refresh the rendering of a block that is still arriving.
///
/// Called on every delta and refused most of the time — see `LiveMarkdown` for the two gates — so the
/// cost of a long answer is one parse every `LIVE_MARKDOWN_MS` of a block's *tail* rather than one
/// parse of the whole of it per delta.
///
/// `length` is the block's length so far, counted as the deltas arrive rather than read off the
/// buffer: materialising the whole of a growing block to ask how long it is would be the same
/// quadratic the rest of this exists to avoid.
fn Shell::live_blocks(
  self : Shell,
  path : String,
  open : Open,
  text : StringBuilder,
  length : Int,
  now : UInt64,
) -> Unit {
  match open.live {
    None => ()
    Some(state) =>
      // **The gate is asked before the string is built**, and the order is the difference between O(n)
      // and O(n²): `to_string` on a growing buffer copies everything arrived so far, and a block that
      // arrives in sixty-four character deltas would copy its own length hundreds of times. Refused
      // frames are the common case — most deltas — so they must cost nothing.
      if live_due(state, length, now) {
        match live_frame(state, text.to_string(), length, now) {
          Some(frame) => self.emit(blocks_frame_event(path, frame))
          None => ()
        }
      }
  }
}

///|
/// Whether this delta is worth a frame at all.
///
/// Two gates, and both are needed. The clock alone would let a fast model pile up a second of text and
/// then send it all at once — a stall in the middle of a stream, which is the one thing streaming
/// exists to avoid. The size alone would make a slow model's every delta pay for a parse, and a model
/// trickling out one character at a time is exactly the case this is *not* for.
fn live_due(state : LiveMarkdown, length : Int, now : UInt64) -> Bool {
  now - state.at_ms >= LIVE_MARKDOWN_MS ||
  length - state.at_length >= LIVE_MARKDOWN_CHARS
}

///|
/// One live frame, or nothing when it is too soon to be worth one.
///
/// The decision, the parse and the diff, separated from the emission so that they can be asserted:
/// what a frame says is a fact about a protocol two builds share, and a fact that is worth a test is
/// worth a function that can be called one.
///
/// Only the part up to the last blank line is parsed, and only the part that has changed is sent.
/// Everything after that boundary is one block that is still being written, and what the reader has
/// already read never moves — see `@md.safe_boundary`.
fn live_frame(
  state : LiveMarkdown,
  source : String,
  length : Int,
  now : UInt64,
) -> LiveFrame? {
  // Recorded before the work: a frame that turns out to have nothing new in it still moves the clock,
  // so the next delta is judged against *this* attempt rather than the last frame that happened to
  // send something. Nothing is recorded on the other path — a refused delta is refused again next
  // time, which is what makes the size gate work.
  state.at_length = length
  state.at_ms = now
  let at = @md.safe_boundary(source)
  let blocks = @md.parse(source[:at].to_owned())
  let from = @md.diff_prefix(state.sent, blocks)
  if from >= blocks.length() {
    // Nothing new *finished*: the open block is still growing, and it is already on the host's
    // screen as text. Sending it again would be a frame that redraws the same paragraph.
    return None
  }
  state.sent = blocks
  // The **tail**, not the whole parse: the host is holding the head, and a frame that repeated it
  // would be applied as `head + head + tail`. The web UI's equivalent sent whole blocks because it
  // had nothing to diff against; this path's whole point is that it does.
  Some({ id: state.id, from, blocks: blocks[from:].to_owned(), })
}

///|
/// What one live frame says.
///
/// The content and the framing, as separate things, because they fail separately: what a frame
/// *means* is a rule about two documents agreeing, and it is asserted by replaying a block's deltas
/// and comparing the result with one parse of the whole. How it is spelled on the wire is the `from`
/// field and the tagged objects, and that is asserted against a literal.
priv struct LiveFrame {
  /// The row this is the rendering of. Named on every frame rather than once, because the host files
  /// by it: a block's frames interleave with other blocks' in one stream, and a frame without an id
  /// has nothing to be applied to.
  id : String
  /// How many leading blocks the host is holding.
  from : Int
  /// The blocks from `from` on — and only those. A frame carrying the whole parse would be applied
  /// on the host as `head + head + tail`.
  blocks : Array[@md.Block]
}

///|
/// A frame as the wire carries it.
fn LiveFrame::fields(self : LiveFrame) -> Array[(String, Json)] {
  let tail : Array[Json] = []
  for block in self.blocks {
    tail.push(block.to_json())
  }
  [
    ("id", Json::string(self.id)),
    ("from", Json::number(self.from.to_double(), repr=self.from.to_string())),
    ("blocks", Json::array(tail)),
  ]
}

///|
/// A tool, running or finished, always under the same id so the finished row replaces the running
/// one instead of leaving it behind.
///
/// The shape is `tool_event`'s; what is here is the one line that makes it go out. The split is the
/// same one `models_event` and `usage_event` already have, and it is what lets the field names be
/// asserted at all: a test can call a function that returns Json, and it cannot call a function whose
/// only effect is to write to a wire it cannot see.
fn Shell::say_tool(
  self : Shell,
  path : String,
  id : String,
  name : String,
  detail : String,
  done : Bool,
  output : String,
  is_error : Bool,
) -> Unit {
  self.emit(tool_event(path, id, name, detail, done, output, is_error))
}

///|
/// One tool row, as the wire carries it.
///
/// Pure, and next to the emitter rather than in the test file, because the two lists of field names
/// were previously written twice — once here and once in `app_wbtest.mbt` — and neither could fail
/// when the other changed. A test that is a transcription of the implementation is not a test.
fn tool_event(
  path : String,
  id : String,
  name : String,
  detail : String,
  done : Bool,
  output : String,
  is_error : Bool,
) -> Json {
  session_event(path, "tool", [
    ("id", Json::string(id)),
    ("name", Json::string(name)),
    ("detail", Json::string(detail)),
    ("done", Json::boolean(done)),
    ("output", Json::string(output)),
    ("error", Json::boolean(is_error)),
  ])
}

///|
fn Shell::say_status(self : Shell, path : String, text : String) -> Unit {
  self.emit(status_event(path, text))
}

///|
/// What the shell is doing right now, as the wire carries it.
fn status_event(path : String, text : String) -> Json {
  session_event(path, "status", [("text", Json::string(text))])
}

///|
/// A turn is over. `text` is empty when it finished normally — the answer is the report — and
/// otherwise says which guard stopped it, which is the one thing the figures cannot say.
fn Shell::say_end(
  self : Shell,
  path : String,
  text : String,
  calls : Int,
  tools : Int,
  cost : Double,
) -> Unit {
  self.emit(end_event(path, text, calls, tools, cost))
}

///|
/// A turn's ending and its figures, as the wire carries them.
fn end_event(
  path : String,
  text : String,
  calls : Int,
  tools : Int,
  cost : Double,
) -> Json {
  session_event(path, "end", [
    ("text", Json::string(text)),
    // Given an integer spelling rather than a float: JSON has one number type and a host that
    // decoded these as doubles would have to decide what `19.0` means for a count.
    ("calls", Json::number(calls.to_double(), repr=calls.to_string())),
    ("tools", Json::number(tools.to_double(), repr=tools.to_string())),
    ("cost", Json::string(@core.format_cost(cost))),
  ])
}

///|
/// Something went wrong, and which session it went wrong in.
///
/// Defaulted to the session on screen because that is what almost every failure is about: a path the
/// reader picked, a model id they chose, a turn they asked for. The exception is a turn failing, and
/// it passes its own path — a background conversation breaking must not stop the one being watched
/// from being able to send.
fn Shell::say_error(
  self : Shell,
  text : String,
  session? : String = "",
) -> Unit {
  self.emit(error_event(session, text))
}

///|
/// Something went wrong, and which session it went wrong in.
fn error_event(session : String, text : String) -> Json {
  session_event(session, "error", [("text", Json::string(text))])
}

///|
/// Every model this build can call, which of them the session is on, and what each one costs.
///
/// Sent because the picker is a host control and the catalog is compiled into the shell: a list the
/// host kept of its own would be a second place for the two to disagree about what can be called, and
/// the shell is the one that refuses an id it does not know. The `vision` flag comes along so the
/// picker can say which models can be shown a picture — the reader is the one who has to decide
/// between the model and the screenshot they just attached.
///
/// **The prices come along as strings, already cut to their columns.** They are the reason a reader
/// opens this menu at all — the pro model is nine times flash's input rate, which is what the entry's
/// own doc comment in `core/model_catalog.mbt` says makes it worth choosing deliberately — and they
/// arrive formatted rather than as numbers because what the host does with them is *place* them: three
/// prices compared down a list need equal widths, which is a fact about the characters, and deriving
/// that in Swift would be a second implementation of the same rule. `unit` is the sentence the menu
/// says once instead of three times.
fn Shell::say_models(self : Shell, open : Open) -> Unit {
  self.emit(models_event(open.path, open.model_id))
}

///|
/// The same event, built from the model in force rather than from the shell.
///
/// Split out so the field names can be asserted without a session on disk, the same way the sessions
/// and the usage events are.
fn models_event(path : String, current : String) -> Json {
  let items : Array[Json] = []
  for spec in @core.model_catalog() {
    let (input, output, cached) = spec.pricing.columns()
    items.push(
      Json::object(
        Map([
          ("id", Json::string(spec.id)),
          ("label", Json::string(spec.label())),
          ("vision", Json::boolean(spec.vision)),
          (
            "prices",
            Json::object(
              Map([
                ("input", Json::string(input)),
                ("output", Json::string(output)),
                ("cached", Json::string(cached)),
              ]),
            ),
          ),
        ]),
      ),
    )
  }
  session_event(path, "models", [
    ("items", Json::array(items)),
    // The session's own model, which is the log's answer rather than the picker's: a resumed session
    // runs on whatever it recorded, and the picker has to show that rather than the default.
    ("current", Json::string(current)),
    // Empty when there is nothing to say, which is what the host checks before drawing a header.
    ("unit", Json::string(price_unit())),
  ])
}

///|
/// What the price columns are denominated in, said once for the whole menu.
///
/// A sentence rather than a unit symbol because the symbol would have to be repeated on every number to
/// be true of it (`$0.14`), which is three glyphs and three spaces of column width per row for a fact
/// that is the same on all of them. `in · out · cached` names the three columns in the order the rows
/// print them, so the header is also the legend.
fn price_unit() -> String {
  "US dollars per million tokens — in · out · cached"
}

///|
/// Say what thinking level the session is on.
///
/// One event for both the menu and the sentence about it, because they are two views of one fact: the
/// shell answers a reader twice from the same pair of values, and a second event built from the same
/// pair would be a second place for them to disagree.
fn Shell::say_think(self : Shell, open : Open) -> Unit {
  self.emit(think_event(open.path, open.model_id, open.think_level))
}

///|
/// The levels a model offers, and the one in force, as the wire carries them.
///
/// The items are the *model's* levels (`ThinkingLevels::offered`), not a list compiled in here: the
/// levels are per model, and a menu drawn from a shared table would offer `low` on a model that
/// rejects it. `current` is always one of them, because `Open::think_level` is kept that way.
///
/// Each item carries its own sentence, so the words a reader acts on are written next to the level
/// they are about — and in the shell, where the level's meaning is known, rather than in a host that
/// would have to learn what `xhigh` is. `default` marks the level a session gets when nobody has
/// said; the menu shows it rather than promising a behaviour it would have to re-derive.
///
/// Built from arguments rather than from `Open` so the field names can be asserted without a session
/// on disk, the same way `models_event` is.
fn think_event(path : String, model_id : String, current : String) -> Json {
  let levels = @core.model_spec_for(model_id).0.thinking_levels
  let fallback = levels.default_level()
  let items : Array[Json] = []
  for level in levels.offered() {
    items.push(
      Json::object(
        Map([
          ("id", Json::string(level)),
          ("label", Json::string(level_label(level))),
          ("detail", Json::string(level_detail(level))),
          ("default", Json::boolean(level == fallback)),
        ]),
      ),
    )
  }
  session_event(path, "think", [
    ("items", Json::array(items)),
    ("current", Json::string(current)),
  ])
}

///|
/// What a level calls itself, in words a reader picks by rather than the word the API takes.
///
/// `max` is left as it is because that is what it means: the most thinking this model does. A name
/// with no entry is shown as itself — a level this build has never heard of is still a level the
/// session is on, and hiding it would leave the menu with nothing ticked.
fn level_label(level : String) -> String {
  match level {
    "off" => "Off"
    "minimal" => "Minimal"
    "low" => "Low"
    "medium" => "Medium"
    "high" => "High"
    "xhigh" => "Extra high"
    "max" => "Max"
    _ => level
  }
}

///|
/// The one line that says what picking a level buys.
///
/// Written to be read *after* the level's own name — the menu shows `Low — thinks briefly — sooner first
/// word` — so each one says what the reader gets and pays rather than what the model does internally:
/// the reason to pick `low` is that it starts answering sooner, and "reasoning effort: low" says nothing
/// a reader could act on.
///
/// **Short, and measured.** A first version said all of it out in full sentences ("thinks a little: a
/// sooner first word, a smaller bill"), and the menu came out **511 points wide** — more than half the
/// window, for a control whose whole point is being a small choice (`AXMenuItem … [953,706 511x24]`,
/// read with the AX probe in `docs/macos-pitfalls.md` 第六节). That is the menu's own arithmetic and not
/// a style opinion: its width is its longest item, so every extra word is paid for in the one dimension
/// a menu cannot wrap. These are the same sentences cut to one clause each — measured as text, the
/// longest went from 470 to 330 points (`NSFont.menuFont`, both numbers in the same place).
///
/// Empty is a real answer, for a level this build has no words for: the host falls back to the name
/// rather than showing a sentence it had to invent.
fn level_detail(level : String) -> String {
  match level {
    "off" => "fastest and cheapest; answers may be shallower"
    "minimal" => "barely any thinking"
    "low" => "thinks briefly; a sooner first word"
    "medium" => "thinks a moderate amount"
    "high" => "thinks before answering"
    "xhigh" => "thinks at length"
    "max" => "thinks longest; slowest and dearest"
    _ => ""
  }
}

///|
/// The background jobs, as the panel draws them.
///
/// Only the live ones. The store keeps finished jobs — it is how a restart accounts for a process it
/// did not start, and how a kill still reaches every pid — but the panel answers "what is still
/// running", and a row for work that is over is a row with no action on it.
///
/// The pids that are still alive come along rather than the list as recorded: a command is registered
/// with its own shell and with the helper that reported it, and neither is what a reader looking for
/// the process in `ps` wants to see.
fn Shell::say_jobs(self : Shell) -> Unit {
  let json = jobs_event(
    self.jobs.list(),
    self.live_pids,
    @env.now().reinterpret_as_int64(),
  )
  // Sent when it changed, and only then. The tick is every two seconds and most of the time nothing
  // is running, so an unconditional send would put thirty identical empty events a minute on the
  // wire and wake the host just as often for a panel that is not on screen. A running job always
  // changes — its age moves — so the update still arrives while there is something to show.
  let text = json.stringify()
  if text == self.sent_jobs {
    return
  }
  self.sent_jobs = text
  self.emit(json)
}

///|
/// The same event, from the facts rather than from the shell.
///
/// Split out for the reason the others are: the field names are the contract with the host, and a
/// contract that can only be asserted by standing up a whole shell is one nobody asserts.
fn jobs_event(
  jobs : Array[@core.Job],
  live_pids : Array[Int],
  now : Int64,
) -> Json {
  let items : Array[Json] = []
  for job in jobs {
    if !job.is_live() {
      continue
    }
    let pids : Array[Json] = []
    for pid in job.pids {
      if live_pids.contains(pid) {
        pids.push(Json::number(pid.to_double(), repr=pid.to_string()))
      }
    }
    let age = job.age_ms(now)
    items.push(
      Json::object(
        Map([
          ("id", Json::string(job.id)),
          ("kind", Json::string(job.kind)),
          ("label", Json::string(job.label)),
          ("status", Json::string(job.status.to_string())),
          // Milliseconds, and an integer on the wire: the host formats it and keeps it counting, and
          // a duration is not a number a host should have to round.
          ("age_ms", Json::number(age.to_double(), repr=age.to_string())),
          ("pids", Json::array(pids)),
          ("session", Json::string(job.session)),
        ]),
      ),
    )
  }
  event("jobs", [("items", Json::array(items))])
}

///|
/// A row that stands in for something the conversation no longer holds in full.
///
/// A compaction is the case: the reader's own words are gone from what the model is sent, replaced by
/// a summary of them, and nothing else on the wire says so. It is a fact about the transcript rather
/// than about the turn's figures, which is why it is a row and not a status line — it belongs at the
/// point in the conversation where it happened.
///
/// `label` is what makes it legible: without it the summary is a paragraph a reader takes for an
/// answer. The same field carries the title of a branch summary, so one shape covers both.
fn Shell::say_note(
  self : Shell,
  path : String,
  text : String,
  label : String,
) -> Unit {
  self.emit(note_event(path, text, label))
}

///|
/// A row that stands in for something the conversation no longer holds, as the wire carries it.
fn note_event(path : String, text : String, label : String) -> Json {
  session_event(path, "note", [
    ("text", Json::string(text)),
    ("name", Json::string(label)),
  ])
}

///|
/// How many compactions a session's path holds, and the newest one's summary.
///
/// Counted rather than flagged: a turn can compact more than once, and what the host needs to know is
/// that the number went *up* — a boolean would miss the second one inside one turn.
fn compaction_state(session : @core.Session) -> (Int, String) {
  let mut count = 0
  let mut latest = ""
  for entry in session.path() {
    match entry.kind {
      @core.Compaction(summary~, ..) => {
        count += 1
        latest = summary
      }
      _ => ()
    }
  }
  (count, latest)
}

///|
/// The pictures waiting to go out with the next prompt.
///
/// Sent whole, on every change, for the same reason the session list is: the host draws the list of
/// attachments it was told about, and a host that had to apply adds and removes of its own would be
/// a second opinion about what is on its way. The bytes come along because they are what the host
/// previews from — a thumbnail it can draw without reading the file again, which is also what makes
/// the preview the picture the model will actually see.
fn Shell::say_images(self : Shell, open : Open) -> Unit {
  self.emit(
    images_event(
      open.path,
      open.attached,
      @core.model_sees_images(open.model_id),
    ),
  )
}

///|
/// The same event, built from the facts rather than from the shell.
///
/// Split out for the same reason `sessions_event` is: the field names are the contract with the host,
/// and a contract that can only be asserted by standing up a whole shell is one that gets asserted by
/// nobody.
fn images_event(
  path : String,
  items : Array[Attachment],
  can_send : Bool,
) -> Json {
  let images : Array[Json] = []
  for attachment in items {
    images.push(
      Json::object(
        Map([
          ("path", Json::string(attachment.path)),
          ("mime", Json::string(attachment.mime_type)),
          ("data", Json::string(attachment.data)),
        ]),
      ),
    )
  }
  session_event(path, "images", [
    ("items", Json::array(images)),
    // Whether the model on screen can be shown a picture at all. A fact about the model, sent with
    // the pictures because it is only interesting next to them, and because a reader who attaches a
    // screenshot to a text-only model should hear it before sending rather than after.
    ("can_send", Json::boolean(can_send)),
  ])
}

///|
/// What this session has used, and what the last turn cost.
///
/// Two figures rather than one, because they answer two questions a reader asks at different times.
/// The session total is what the conversation has cost; the turn's own numbers are what the last
/// question cost, which is what the line under the composer is for while a reader is deciding
/// whether to ask another one.
///
/// The numbers are raw and the formatting is the host's, except for cost: the cents-vs-dollars
/// decision is `core`'s (a turn costs a fraction of a cent, and rounding to cents would print every
/// turn as `$0.00`), and doing it twice is how the two front ends come to disagree.
///
/// `prompt` is the size of the most recent request as the provider measured it, which is the honest
/// answer to "how full is the context": it is what was actually sent, not an estimate of what would
/// be. Before anything has been sent there is no measurement, and zero is what that means.
///
/// The other half of the context story comes with it now — what the *next* request would cost, and
/// whether that is close enough to the window for compaction. See `ContextFacts`.
async fn Shell::say_usage(self : Shell, open : Open) -> Unit {
  let facts = self.context_facts(open)
  self.emit(
    usage_event(
      open.path,
      open.session.usage(),
      open.session.last_prompt_tokens(),
      facts,
      open.last_turn,
    ),
  )
}

///|
/// What the next request would cost, and how sure that is.
///
/// Apart from the totals because it answers a different question, and the difference is the one that
/// changes what happens next: the totals are what has been spent, and this is what is still
/// available. `tokens` is `core`'s anchored figure (the last size the provider reported, plus what
/// has been added since), and `source` says which of the two it leaned on — a host that prints an
/// estimate as if it were a measurement would be lying about the only number that decides when the
/// conversation is summarized.
///
/// `overhead` is carried separately rather than folded in, because "of which ~1,300 are the system
/// prompt and the tool schemas" is the part a reader can do nothing about and therefore wants named
/// rather than hidden in the total.
///
/// `compact_soon` is the same comparison the driver makes before it sends a request
/// (`@core.should_compact` with the reserve for this window), asked here so that the window can warn
/// *before* the turn that would summarize the conversation — which is the one moment this figure is
/// worth a reader's attention.
priv struct ContextFacts {
  tokens : Int
  provider_measured : Bool
  overhead : Int
  window : Int
  compact_soon : Bool
}

///|
/// The system prompt this session's next turn would send.
///
/// One definition, used by the turn that sends it and by the figure that prices it: a context
/// estimate built from a *different* prompt than the one on the wire is an estimate of a request
/// that never goes out, and the two would drift the first time either side changed.
async fn Shell::system_prompt(
  self : Shell,
  open : Open,
  tools : Array[@core.ToolDef],
) -> String {
  @core.build_system_prompt(
    open.cwd,
    tools,
    mode=self.settings.tool_mode,
    instructions=self.instructions(open),
    // The catalog the model reads to decide whether a skill applies. It was missing here while this
    // function's own comment said it was present, and the web and vim front ends both sent it: a
    // macOS session could only use a skill the reader already knew the name of, because nothing in
    // the prompt said which ones existed. Discovery and the setting are both per directory and
    // cached, so this adds no I/O to the turn.
    skills=self.enabled_skills(open.cwd),
    // Empty unless this conversation already ran with a tool the current mode does not have. The
    // setting can change mid-session, and without this the model would keep reaching for a tool
    // that is no longer declared.
    stale_tools=@core.stale_tool_names(open.session.context(), tools),
  )
}

///|
/// The instructions this workspace contributes, if any.
///
/// Split out because building it reads `AGENTS.md` and that is the only part of the estimate that is
/// I/O. Kept async rather than cached: a file the reader edits mid-session is a file the next turn
/// picks up, and a cached copy would price a prompt that no longer exists.
async fn Shell::instructions(self : Shell, open : Open) -> String {
  @core.choose_instructions(
    self.settings,
    @platform.workspace_agents_md(open.cwd),
  ).text
}

///|
/// Where the session stands against the window its model has.
///
/// `tokens` is zero for a conversation with nothing in it yet, and that is the same convention
/// `prompt` uses: a session that has asked nothing has no context to report, and a figure would be
/// the system prompt's own size dressed up as the conversation's.
async fn Shell::context_facts(self : Shell, open : Open) -> ContextFacts {
  let window = @core.model_spec_for(open.model_id).0.context_window
  let tools = @core.tools_for_mode(self.settings.tool_mode)
  let overhead = @core.request_overhead_tokens(
    self.system_prompt(open, tools),
    tools,
  )
  let has_conversation = !open.session.context().messages.is_empty()
  if !has_conversation {
    return {
      tokens: 0,
      provider_measured: false,
      overhead,
      window,
      compact_soon: false,
    }
  }
  // The prepared context rather than the raw one: trimming is part of what the next request will
  // carry, and a figure that ignored it would run ahead of the conversation it describes.
  let pressure = @core.context_pressure(
    open.session.prepared_context().messages,
    overhead,
  )
  {
    tokens: pressure.tokens,
    provider_measured: pressure.source is @core.Provider,
    overhead,
    window,
    compact_soon: @core.should_compact(
      pressure.tokens,
      window,
      reserve_tokens=@core.CompactionSettings::for_window(window).reserve_tokens,
    ),
  }
}

///|
/// The same event, built from the facts rather than from the shell.
///
/// Split out for the reason `images_event` is: this shape is read by a host that was written against
/// the field names, and pinning it should not require a session file.
fn usage_event(
  path : String,
  total : @core.SessionUsage,
  prompt : Int,
  context : ContextFacts,
  last : LastTurn,
) -> Json {
  // Built as a list of pairs, because the shape is flat and the optional fields are the only
  // interesting part: a cache share that does not exist is a field left out rather than a zero.
  // No `mut` on the binding: an array is a mutable structure, and this only ever grows it.
  let fields : Array[(String, Json)] = [
    (
      "turns",
      Json::number(total.replies.to_double(), repr=total.replies.to_string()),
    ),
    (
      "total",
      Json::number(
        total.total_tokens.to_double(),
        repr=total.total_tokens.to_string(),
      ),
    ),
    (
      "input",
      Json::number(total.input.to_double(), repr=total.input.to_string()),
    ),
    (
      "output",
      Json::number(total.output.to_double(), repr=total.output.to_string()),
    ),
    (
      "cache_read",
      Json::number(
        total.cache_read.to_double(),
        repr=total.cache_read.to_string(),
      ),
    ),
    (
      "cache_write",
      Json::number(
        total.cache_write.to_double(),
        repr=total.cache_write.to_string(),
      ),
    ),
    // Session reasoning tokens. Absent from a provider that does not report them, so it stays zero
    // rather than becoming a missing field: a total of nothing is zero, which is a fact, and the
    // host draws it as nothing said rather than as nothing measured.
    (
      "reasoning",
      Json::number(
        total.reasoning.to_double(),
        repr=total.reasoning.to_string(),
      ),
    ),
    ("prompt", Json::number(prompt.to_double(), repr=prompt.to_string())),
    // What the next request would carry, which is the prompt figure plus whatever has been added
    // since it was measured. Zero for a conversation with nothing in it — see `context_facts`.
    (
      "context",
      Json::number(context.tokens.to_double(), repr=context.tokens.to_string()),
    ),
    (
      "context_source",
      Json::string(
        if context.provider_measured {
          "provider"
        } else {
          "estimated"
        },
      ),
    ),
    (
      "overhead",
      Json::number(
        context.overhead.to_double(),
        repr=context.overhead.to_string(),
      ),
    ),
    (
      "window",
      Json::number(context.window.to_double(), repr=context.window.to_string()),
    ),
    ("compact_soon", Json::boolean(context.compact_soon)),
    ("cost", Json::string(@core.format_cost(total.cost.total))),
    ("cost_input", Json::string(@core.format_cost(total.cost.input))),
    ("cost_output", Json::string(@core.format_cost(total.cost.output))),
    ("cost_cache_read", Json::string(@core.format_cost(total.cost.cache_read))),
    (
      "cost_cache_write",
      Json::string(@core.format_cost(total.cost.cache_write)),
    ),
  ]
  match @core.format_cache_hit_percent(total.cache_read, total.billed_input()) {
    Some(percent) => fields.push(("cache_hit", Json::string(percent)))
    None => ()
  }
  if last.present {
    fields.push(
      (
        "last_model_calls",
        Json::number(
          last.model_calls.to_double(),
          repr=last.model_calls.to_string(),
        ),
      ),
    )
    fields.push(
      (
        "last_tool_calls",
        Json::number(
          last.tool_calls.to_double(),
          repr=last.tool_calls.to_string(),
        ),
      ),
    )
    fields.push(
      (
        "last_total",
        Json::number(
          last.usage.total_tokens.to_double(),
          repr=last.usage.total_tokens.to_string(),
        ),
      ),
    )
    // The last turn's own cache and reasoning figures, which are what explain the two cases a reader
    // notices: a turn that was cheap because its prompt was already cached, and a turn that was
    // expensive without producing much text. Both are left out when they are nothing, the way the
    // session's cache share is: a field that exists only to hold a zero is a field the host has to
    // learn to ignore.
    if last.usage.cache_read > 0 {
      fields.push(
        (
          "last_cache_read",
          Json::number(
            last.usage.cache_read.to_double(),
            repr=last.usage.cache_read.to_string(),
          ),
        ),
      )
    }
    match last.usage.reasoning {
      Some(reasoning) if reasoning > 0 =>
        fields.push(
          (
            "last_reasoning",
            Json::number(reasoning.to_double(), repr=reasoning.to_string()),
          ),
        )
      _ => ()
    }
    fields.push(
      (
        "last_input",
        Json::number(
          last.usage.input.to_double(),
          repr=last.usage.input.to_string(),
        ),
      ),
    )
    fields.push(
      (
        "last_output",
        Json::number(
          last.usage.output.to_double(),
          repr=last.usage.output.to_string(),
        ),
      ),
    )
    fields.push(("last_cost", Json::string(@core.format_cost(last.cost))))
  }
  session_event(path, "usage", fields)
}
