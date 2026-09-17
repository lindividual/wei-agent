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
/// What a picker shows for a model.
///
/// The name, and the id when the two differ — a reader who has to type the id later (in a `curl`,
/// in a log) should be able to see which one it is without hovering.
pub fn ModelSpec::label(self : ModelSpec) -> String {
  if self.name == self.id {
    self.id
  } else {
    "\{self.name} (\{self.id})"
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
