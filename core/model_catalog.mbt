///|
/// The models this build knows how to call.
///
/// A table rather than three loose constants, because the facts about a model are *one* fact in
/// three parts: the wire id, what a token costs, and how much of a conversation fits. Keeping them
/// in separate places is how the window of one model gets paired with the pricing of another, and
/// the wrong pairing is invisible — the cost figure is still a number and the context chip still
/// has a denominator. `AgentContext` already existed to keep them together for a single model;
/// this is the same idea extended to the set of models a session can be switched between.
///
/// The numbers are upstream's, and where they come from is worth naming so the next person can
/// re-derive rather than guess. They were read from the catalogue of the agent this project was
/// forked from, which resolved `--model` against a file of its own. That file is not read here —
/// this table is the copy, and keeping the provenance is what lets someone check it. Two things
/// are worth knowing before reading the table.
///
/// First, the same model can appear under two ids. `deepseek-v4-flash` is the id this repository's
/// recorded fixtures were captured with, and its rates (0.14 / 0.28 / 0.0028) are what those
/// fixtures bill at; upstream has since renamed the model to `deepseek-flash` and raised the rates
/// (0.3 / 1.2 / 0.006). Both are listed, because a session resumed from an old log names the old
/// id and must keep its recorded costs intact, while a new session should use the current one.
/// Rewriting the old numbers would make `harness/fixtures/live.json` wrong, and a fixture that no
/// longer matches the code it pins is worse than a stale id.
///
/// Second, the thinking levels are per model, not per provider: `deepseek-v4-pro` has no `low`
/// level, and a table that gave every model the same map would silently send `reasoning_effort:
/// low` to a model that rejects it.

///|
/// One model: what to send, what it costs, and how much it holds.
pub(all) struct ModelSpec {
  /// The wire id, which is what goes in the request and what a session's log records.
  id : String
  /// What to call it in a picker. The id is not always the right thing to show a reader.
  name : String
  provider : String
  /// USD per million tokens.
  pricing : Pricing
  /// Tokens of conversation the model accepts, from the same catalog as the pricing.
  context_window : Int
  /// The most it will emit in one response. Not sent — upstream does not send it either — so it is
  /// only a bound to reason about.
  max_tokens : Int
  /// Which thinking levels this model has, and what each is called on the wire.
  thinking_levels : ThinkingLevels
  /// Whether the model accepts images.
  ///
  /// A fact about the model, not about the request, which is why it sits here: the request builder
  /// needs it to decide between sending an image and sending a placeholder, and the two must never
  /// disagree with the model actually being called. Before this was in the catalog it was written
  /// as `vision: false` at the call site, so an image in a session was silently degraded even on a
  /// model that could see it.
  vision : Bool
} derive(Eq, Debug)

///|
/// The level a turn runs at when nobody has said.
///
/// Asked of the default model rather than written down as `"high"` in each front end: this is one
/// fact, and before this existed it was spelled out in three places (`cli/main.mbt`, `wei/main.mbt`,
/// `ui/turn.mbt`) — which is the state an invariant like "the default every front end uses is the
/// one the catalog names" cannot be checked in.
///
/// A front end with a session in hand should not use this: it should ask what the session recorded,
/// through `ThinkingLevels::in_force`, and fall back here only when the log has nothing. That is what
/// makes a reader's choice outlive the window they made it in.
pub fn default_thinking_level() -> String {
  default_model().thinking_levels.default_level()
}

///|
/// Every model this build can call, in picker order.
pub fn model_catalog() -> Array[ModelSpec] {
  [deepseek_v4_flash_spec(), deepseek_flash_spec(), deepseek_v4_pro_spec()]
}

///|
/// The id a session uses when nothing has chosen one.
pub fn default_model_id() -> String {
  "deepseek-v4-flash"
}

///|
/// The default model, as a spec.
///
/// A function rather than a constant so the fallback is in one place: every caller that needs "the
/// model to use when a session has not said" gets the same answer, including the pricing.
pub fn default_model() -> ModelSpec {
  match find_model(default_model_id()) {
    Some(spec) => spec
    None =>
      // Unreachable while the catalog contains the default, and written as a real value rather
      // than a panic because a missing entry is a build-time mistake, not a reason to take a
      // running process down. The test below pins the two together.
      deepseek_v4_flash_spec()
  }
}

///|
/// The spec for an id, or `None` when this build does not know the model.
///
/// `None` rather than a default, deliberately: the caller has two different questions to answer
/// with it — "may I switch this session to that model" (no) and "what window and pricing should I
/// show for a session whose log names a model I do not know" (the default's, said out loud). Both
/// callers need to know the difference, so it is not papered over here.
pub fn find_model(id : String) -> ModelSpec? {
  for spec in model_catalog() {
    if spec.id == id {
      return Some(spec)
    }
  }
  None
}

///|
/// Whether a string names a model this build can call.
pub fn is_known_model(id : String) -> Bool {
  find_model(id) != None
}

///|
/// The thinking levels this model offers a reader, least thinking first, `off` included.
///
/// A view of `map` rather than a second table: a level is offered exactly when `map` recognises it,
/// and the mapping itself is the request builder's business. `off` is in every model's list — it is
/// not an effort, it is the state a request expresses by disabling thinking, and a log may record a
/// session that ran in it (`agent/driver.mbt`). A level `map` holds as `None` is *not* offered: for
/// `minimal` on flash and `low` on pro, `None` means the model has no such setting, and this is the
/// question a picker has to ask before it can draw one — see `ThinkingLevels::resolve` for what
/// happens to a name that is sent anyway.
pub fn ThinkingLevels::offered(self : ThinkingLevels) -> Array[String] {
  let offered : Array[String] = ["off"]
  for name in self.map.keys() {
    match self.map.get(name) {
      Some(Some(_)) => offered.push(name)
      _ => ()
    }
  }
  // Ordered rather than left in the map's order, which is whatever the hash table does: a picker
  // draws these in the order they arrive, and "the levels from least thinking to most" is a fact
  // about the levels, not about the table they are stored in.
  let order = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
  let sorted : Array[String] = []
  for name in order {
    if offered.contains(name) {
      sorted.push(name)
    }
  }
  sorted
}

///|
/// The level this model uses when nobody has said.
///
/// `high`, which is what every front end in this repository has always asked for — so adding a
/// choice does not change what happens when nobody makes one. A model that does not have `high`
/// gets the most thinking it does have, and a model with no levels at all gets `off`. Both are
/// unreachable while the catalog holds only DeepSeek entries, and they are written as real answers
/// rather than as a panic for the reason `default_model` gives.
pub fn ThinkingLevels::default_level(self : ThinkingLevels) -> String {
  let offered = self.offered()
  if offered.contains("high") {
    return "high"
  }
  let mut highest = "off"
  for name in offered {
    if name != "off" {
      highest = name
    }
  }
  highest
}

///|
/// The level the next request should run at: `wanted` when this model has it, the default otherwise.
///
/// The one place that turns "what was asked for" into "what will be sent", and it exists because
/// the two differ in a case that is easy to get wrong: the levels are per model, and a session
/// carries its level in its log, so switching models can leave a session asking for a level the new
/// model does not have (`low` on flash, then pro). Answering with the model's default says what the
/// session will actually do, and lets the caller write that down — see `Shell::think_level` in
/// `macos/appffi/app.mbt`, which persists exactly this answer.
///
/// `None` and an unavailable name are answered the same way, deliberately: neither is a level this
/// model can run at, and the reader is owed the level that is in force rather than a refusal.
pub fn ThinkingLevels::in_force(
  self : ThinkingLevels,
  wanted : String?,
) -> String {
  match wanted {
    Some(name) =>
      if self.offered().contains(name) {
        name
      } else {
        self.default_level()
      }
    None => self.default_level()
  }
}

///|

///|
/// Whether the model a session runs on can be shown an image.
///
/// The question the read tool and the request builder both have to answer, answered from the one
/// place that knows: the catalog. A session naming a model this build does not have falls back to
/// the default, whose answer is the honest one — the request really will go to a model that can
/// see, because that is the model it will be sent to.
pub fn model_sees_images(id : String) -> Bool {
  model_spec_for(id).0.vision
}

///|
/// The spec to use for a session that claims to run on `id`.
///
/// An unknown id falls back to the default rather than being refused, because the id came from a
/// session log: the model really was used, so the session must stay openable, and the only facts
/// missing are the ones a log cannot supply — what it costs and how much it holds. The `Bool`
/// says whether the fallback happened, so the one place that can tell the reader (the model chip)
/// can do so instead of quietly pricing a session on a model it is not running.
pub fn model_spec_for(id : String) -> (ModelSpec, Bool) {
  match find_model(id) {
    Some(spec) => (spec, true)
    None => (default_model(), false)
  }
}

///|
/// What a picker shows for a model: its name.
///
/// **The name alone, and the id is deliberately not appended.** It used to be `Name (id)`, with the
/// id there for the reader who has to type it later — in a `curl`, in a log. That reader exists, and
/// this is not where they are: the menu beside the composer is a message about to be sent, and what
/// belongs next to a model there is what it costs, not the string the API is called with. Measured on
/// this build's own menu: appending the id made every row ~110 points wider while adding no fact a
/// reader of that menu can act on (the ids here differ from the names only in case and hyphens).
///
/// The id is still shown where it is an answer rather than noise: `/model` and `model_report` name it
/// on purpose, `ModelCatalog.currentLabel` falls back to the raw id for a log-session this build does
/// not know, and the picker carries it as the value it sends. That is `label_with_id`, one call site.
pub fn ModelSpec::label(self : ModelSpec) -> String {
  self.name
}

///|
/// The name and the id, for the one place a reader is being told which string to type.
///
/// A model whose name *is* its id does not repeat itself.
pub fn ModelSpec::label_with_id(self : ModelSpec) -> String {
  if self.name == self.id {
    self.id
  } else {
    "\{self.name} (\{self.id})"
  }
}

///|
/// The price columns a picker draws, as three strings that line up down the menu.
///
/// USD per million tokens, input / output / cache read — and the reason this returns **strings** rather
/// than the three numbers is the whole of it: three prices in a menu are compared *down* the list, one
/// row against the next, and a column that moves cannot be compared by eye. The widths are taken from
/// every model in the catalog rather than from this one, so `0.14` and `1.32` and `0.0028` all land in
/// the same columns on every row.
///
/// Two decimals is the floor and more are added where the numbers need them: cache reads are a
/// fiftieth of input on these models, and `$0.00` for one is not a smaller number, it is a wrong one.
/// The digits after the point are padded rather than trimmed, which is what makes the strings equal in
/// length — measured as text, this build's three rows are `0.14  0.28  0.0028`, `0.30  1.20  0.0060`
/// and `1.32  3.96  0.0440`.
pub fn Pricing::columns(self : Pricing) -> (String, String, String) {
  let specs = model_catalog()
  let (in_digits, in_decimals) = price_shape(
    specs.map(spec => spec.pricing.input),
  )
  let (out_digits, out_decimals) = price_shape(
    specs.map(spec => spec.pricing.output),
  )
  let (cache_digits, cache_decimals) = price_shape(
    specs.map(spec => spec.pricing.cache_read),
  )
  (
    price_text(self.input, in_digits, in_decimals),
    price_text(self.output, out_digits, out_decimals),
    price_text(self.cache_read, cache_digits, cache_decimals),
  )
}

///|
/// How wide one column of prices has to be: digits before the point, digits after.
///
/// One column at a time, because the three do not need the same width — input is `0.14` and a cache
/// read is `0.0028`, and padding the first to four decimals to match the second would be four
/// characters of noise on every row.
fn price_shape(values : Array[Double]) -> (Int, Int) {
  let mut integer_digits = 1
  let mut decimals = 2
  for value in values {
    let whole = value.to_int()
    let digits = if whole == 0 { 1 } else { whole.to_string().length() }
    if digits > integer_digits {
      integer_digits = digits
    }
    // The floor is two; a price that is not a whole number of cents sets the width for the column,
    // because printing it rounded to cents would be printing a different price.
    while decimals < PRICE_DECIMALS_MAX && !price_fits(value, decimals) {
      decimals = decimals + 1
    }
  }
  (integer_digits, decimals)
}

///|
/// The most decimals a price is ever printed with.
///
/// Bounded because this is a menu row and not an accounting system: a price that needs more than six
/// digits to say what it costs is a catalog mistake, and a column that grew to whatever it took would
/// take the window with it.
const PRICE_DECIMALS_MAX : Int = 6

///|
/// Whether a price is exactly representable at a given number of decimals.
///
/// Compared with a tolerance, because these are `Double`s: `0.006 * 1000` is not exactly `6` in binary
/// floating point, and a strict equality would push every cache-read column to six decimals.
fn price_fits(value : Double, decimals : Int) -> Bool {
  let scaled = value * price_scale(decimals)
  (scaled - scaled.round()).abs() < 0.0001
}

///|
/// `10 ^ decimals`, for the values `price_shape` can settle on.
fn price_scale(decimals : Int) -> Double {
  match decimals {
    0 => 1.0
    1 => 10.0
    2 => 100.0
    3 => 1000.0
    4 => 10000.0
    5 => 100000.0
    _ => 1000000.0
  }
}

///|
/// One price, padded to a fixed width: `0.14`, `1.32`, `0.0028`.
///
/// Built from an integer rather than by formatting a `Double`, for the reason the three columns exist:
/// `Double::to_string` decides its own decimals per value (`0.006` next to `0.044`), so a column of
/// them comes out ragged. This is `format_cost`'s arithmetic with a width it is given instead of one
/// it chooses.
fn price_text(value : Double, integer_digits : Int, decimals : Int) -> String {
  // The digits as one integer, so the width is the two digit counts and nothing else — the point is
  // put in afterwards, which is why it is not counted here.
  let width = integer_digits + decimals
  let digits = (value * price_scale(decimals)).round().to_int().to_string()
  let padded = if digits.length() >= width {
    digits
  } else {
    zeroes(width - digits.length()) + digits
  }
  let cut = padded.length() - decimals
  if decimals == 0 {
    padded
  } else {
    padded[:cut].to_owned() + "." + padded[cut:].to_owned()
  }
}

// ── the entries ────────────────────────────────────────────────────────────

///|
/// `deepseek-v4-flash`, the default, and the id the recorded fixtures use.
///
/// Its pricing and window come from the accessors beside the request builder rather than being
/// restated here: those are the values `harness/fixtures/live.json` bills at, and a second copy of
/// a number that a fixture pins is a second thing to get out of step. The consistency test below
/// is what keeps this delegation honest.
fn deepseek_v4_flash_spec() -> ModelSpec {
  {
    id: "deepseek-v4-flash",
    name: "DeepSeek V4 Flash",
    provider: "deepseek",
    pricing: deepseek_v4_flash_pricing(),
    context_window: deepseek_v4_flash_context_window(),
    max_tokens: deepseek_v4_flash_max_tokens(),
    thinking_levels: deepseek_v4_thinking_levels(),
    // The upstream catalogue lists this model's input as text *and* image, so a screenshot read
    // with it is sent rather than replaced.
    vision: true,
  }
}

///|
/// `deepseek-flash`: what `deepseek-v4-flash` is called now, at current prices.
///
/// A separate entry rather than a rename, because the id is recorded in a session's log and a log
/// is history. Rates from the same catalogue as the entry above (input 0.3, output 1.2, cache read
/// 0.006 — a cache read at a fiftieth of input, the same ratio the flash entry uses).
fn deepseek_flash_spec() -> ModelSpec {
  {
    id: "deepseek-flash",
    name: "DeepSeek V4.1 Flash",
    provider: "deepseek",
    pricing: { input: 0.3, output: 1.2, cache_read: 0.006, cache_write: 0.0, },
    context_window: 1000000,
    max_tokens: 384000,
    thinking_levels: deepseek_v4_thinking_levels(),
    // Same input modalities as the id it replaced.
    vision: true,
  }
}

///|
/// `deepseek-v4-pro`: the expensive one, and the reason the model is per session.
///
/// Nine times the input price of flash. A turn that is worth running on it is a turn worth choosing
/// deliberately, which is what a picker next to the composer is for. Rates from the same catalog
/// file (1.32 / 3.96 / 0.044).
///
/// Its thinking levels differ from flash's: `low` is not a level this model has, and it is listed
/// as `None` rather than dropped so that a request for it falls back the way every other
/// unavailable level does instead of being sent as an effort the API would reject.
fn deepseek_v4_pro_spec() -> ModelSpec {
  let levels : Map[String, String?] = Map([
    ("off", None),
    ("minimal", None),
    ("low", None),
    ("medium", None),
    ("high", Some("high")),
    ("xhigh", None),
    ("max", Some("max")),
  ])
  {
    id: "deepseek-v4-pro",
    name: "DeepSeek V4 Pro",
    provider: "deepseek",
    pricing: { input: 1.32, output: 3.96, cache_read: 0.044, cache_write: 0.0, },
    context_window: 1000000,
    max_tokens: 384000,
    thinking_levels: { map: levels, },
    // Text only, per the catalog: an image sent here would be rejected, so the request builder
    // must degrade it to a placeholder instead.
    vision: false,
  }
}

///|
/// Every model id, for an error message that has to say what there was to choose from.
pub fn model_ids() -> Array[String] {
  let out : Array[String] = []
  for spec in model_catalog() {
    out.push(spec.id)
  }
  out
}
