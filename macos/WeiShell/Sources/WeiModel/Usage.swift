import Foundation

/// A picture on its way to the model with the next prompt.
///
/// The bytes come with it rather than a path to read later, and both halves of that matter: the
/// composer draws the thumbnail from the same bytes the request will carry, so the preview is the
/// picture the model sees; and a file that changes between the pick and the send cannot change what
/// was sent.
public struct Attachment: Equatable, Decodable, Identifiable {
    /// Where the reader picked it. The identity of the row, and what a remove names.
    public let path: String
    /// The media type the shell recognized from the file's own bytes.
    public let mime: String
    /// Base64 of those bytes, which is how an image travels.
    public let data: String

    public var id: String { path }

    /// What to call it: the file name, because that is what the reader picked and what they will
    /// recognize in a row of thumbnails.
    public var name: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String, mime: String, data: String) {
        self.path = path
        self.mime = mime
        self.data = data
    }
}

/// What the last turn cost, on its own.
///
/// Apart from the session totals because it answers a different question: the totals are what this
/// conversation has spent, and this is what the question just answered cost — which is the one a
/// reader is deciding about when they are deciding whether to ask another.
///
/// The cache and reasoning figures are the two that explain a turn which surprises a reader: one that
/// cost almost nothing because its prompt was already cached, and one that cost a lot while writing
/// few words because it thought first. Both are the *last* turn's, not the session's, for the same
/// reason the cost is: a session total tells you a conversation was like that, and this tells you the
/// one you just paid for was.
public struct TurnUsage: Equatable {
    public let modelCalls: Int
    public let toolCalls: Int
    public let total: Int
    public let input: Int
    public let output: Int
    /// Prompt tokens that came from the provider's cache rather than being billed fresh.
    public let cacheRead: Int
    /// Thinking tokens, when the provider reports them at all.
    public let reasoning: Int?
    /// Already formatted by the shell, which is where the decimals rule lives.
    public let cost: String

    public init(
        modelCalls: Int,
        toolCalls: Int,
        total: Int,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        reasoning: Int? = nil,
        cost: String
    ) {
        self.modelCalls = modelCalls
        self.toolCalls = toolCalls
        self.total = total
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.cost = cost
    }
}

/// What a session has used, and what its last turn cost.
///
/// The figures are the shell's — summed from the session log, and formatted there too. In particular
/// `cost` is a string: a turn costs a fraction of a cent, and the number of decimals to show is a
/// decision `core` makes for both front ends, so formatting it again here would be the second opinion
/// that makes the web UI and this window disagree about the same turn.
public struct Usage: Equatable, Decodable {
    /// How many priced model calls the totals cover: every assistant message on the path, plus the
    /// summarization call behind each compaction. The shell's `replies`.
    ///
    /// Counted on the same walk as the tokens, which is why it is one number for "expensive" (the
    /// bill) and "long" (the conversation) — and why it can be called a call count rather than a
    /// guess: in this system one model call produces exactly one priced message.
    public let turns: Int
    /// Every token the provider billed, prompt and completion together.
    public let total: Int
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    /// Thinking tokens for the whole session, when the provider reports them. Zero for one that does
    /// not, which is a fact about the provider rather than about the conversation — the panel says so
    /// by leaving the row out.
    public let reasoning: Int
    /// The size of the most recent request, as the provider measured it. Zero before anything has
    /// been sent, which is what that means rather than a missing value.
    public let prompt: Int
    /// What the **next** request would carry, as `core`'s anchored estimate: the last size the
    /// provider reported plus everything appended since. This is the figure the compaction decision is
    /// made on, so it is the one to show against the window — `prompt` is where the last request
    /// landed, which is history rather than pressure.
    public let context: Int
    /// Whichever of the two `context` leaned on. `nil` only for a payload written before this field
    /// existed, which is drawn as an estimate rather than as a measurement it cannot prove.
    public let contextSource: String?
    /// Tokens every request carries outside the conversation: the system prompt and the tool schemas.
    /// Named separately because a reader can do nothing about it, and a context figure without it
    /// looks like the mirror of the conversation when it is nothing of the kind.
    public let overhead: Int
    /// The context window of the model this session runs on.
    public let window: Int
    /// Whether this conversation is close enough to the window that the next turn could summarize it.
    public let compactSoon: Bool
    public let cost: String
    public let costInput: String
    public let costOutput: String
    public let costCacheRead: String
    public let costCacheWrite: String
    /// Share of the prompt that came from the provider's cache, as a percentage. `nil` when no
    /// prompt was sent: a share of nothing is not a number to show.
    public let cacheHit: String?
    /// Absent until a turn has finished in this session.
    public let last: TurnUsage?

    private enum CodingKeys: String, CodingKey {
        case turns, total, input, output, prompt, window, cost, context, overhead, reasoning
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case contextSource = "context_source"
        case compactSoon = "compact_soon"
        case costInput = "cost_input"
        case costOutput = "cost_output"
        case costCacheRead = "cost_cache_read"
        case costCacheWrite = "cost_cache_write"
        case cacheHit = "cache_hit"
        case lastModelCalls = "last_model_calls"
        case lastToolCalls = "last_tool_calls"
        case lastTotal = "last_total"
        case lastInput = "last_input"
        case lastOutput = "last_output"
        case lastCacheRead = "last_cache_read"
        case lastReasoning = "last_reasoning"
        case lastCost = "last_cost"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        turns = try fields.decode(Int.self, forKey: .turns)
        total = try fields.decode(Int.self, forKey: .total)
        input = try fields.decode(Int.self, forKey: .input)
        output = try fields.decode(Int.self, forKey: .output)
        cacheRead = try fields.decode(Int.self, forKey: .cacheRead)
        cacheWrite = try fields.decode(Int.self, forKey: .cacheWrite)
        reasoning = (try fields.decodeIfPresent(Int.self, forKey: .reasoning)) ?? 0
        prompt = try fields.decode(Int.self, forKey: .prompt)
        context = (try fields.decodeIfPresent(Int.self, forKey: .context)) ?? 0
        contextSource = try fields.decodeIfPresent(String.self, forKey: .contextSource)
        overhead = (try fields.decodeIfPresent(Int.self, forKey: .overhead)) ?? 0
        window = try fields.decode(Int.self, forKey: .window)
        compactSoon = (try fields.decodeIfPresent(Bool.self, forKey: .compactSoon)) ?? false
        cost = try fields.decode(String.self, forKey: .cost)
        costInput = try fields.decode(String.self, forKey: .costInput)
        costOutput = try fields.decode(String.self, forKey: .costOutput)
        costCacheRead = try fields.decode(String.self, forKey: .costCacheRead)
        costCacheWrite = try fields.decode(String.self, forKey: .costCacheWrite)
        cacheHit = try fields.decodeIfPresent(String.self, forKey: .cacheHit)
        // The last turn is all-or-nothing, and the calls and the cost are what say so: a turn that
        // happened made at least one model call and cost something. Anything else is half a turn,
        // which is a shell bug rather than a state to draw.
        if let calls = try fields.decodeIfPresent(Int.self, forKey: .lastModelCalls),
           let tools = try fields.decodeIfPresent(Int.self, forKey: .lastToolCalls),
           let cost = try fields.decodeIfPresent(String.self, forKey: .lastCost) {
            last = TurnUsage(
                modelCalls: calls,
                toolCalls: tools,
                total: (try fields.decodeIfPresent(Int.self, forKey: .lastTotal)) ?? 0,
                input: (try fields.decodeIfPresent(Int.self, forKey: .lastInput)) ?? 0,
                output: (try fields.decodeIfPresent(Int.self, forKey: .lastOutput)) ?? 0,
                // Absent means the turn read nothing from the cache, which is the same fact as zero
                // — unlike `reasoning`, where absent means the provider does not report it at all.
                cacheRead: (try fields.decodeIfPresent(Int.self, forKey: .lastCacheRead)) ?? 0,
                reasoning: try fields.decodeIfPresent(Int.self, forKey: .lastReasoning),
                cost: cost
            )
        } else {
            last = nil
        }
    }

    /// How full the context is, as a fraction of the window. `nil` before anything has been sent,
    /// because an empty bar and a bar at zero are two different claims.
    ///
    /// Measured on `contextFigure` rather than `prompt`, which is the difference between "what the
    /// last request was" and "what the next one will be". The bar answers the second question, so it
    /// is the second figure: a conversation that has grown 20k tokens since its last reply is nearer
    /// the window than that reply's own size makes it look.
    public var contextFill: Double? {
        guard contextFigure > 0, window > 0 else { return nil }
        return min(1.0, Double(contextFigure) / Double(window))
    }

    /// The figure the ring and the panel draw: what the next request would carry.
    ///
    /// Falls back to `prompt` for a payload written before the shell sent a context figure — the last
    /// request's own measured size. That is a worse answer to the question the ring asks, and a much
    /// better one than zero: the shell and the window are built together, so the only way to meet this
    /// is a window running against a shell older than it, and the right response to that is slightly
    /// old figures rather than none.
    public var contextFigure: Int { context > 0 ? context : prompt }

    /// Whether the figure behind the ring rests on something the provider reported.
    ///
    /// True for an anchored estimate — its whole construction is "the last measured prompt plus what
    /// was added" — and true for the fallback above, which *is* a measurement. False only when nothing
    /// in this conversation has been measured at all, which is the one case where the figure is the
    /// four-bytes-per-token heuristic and nothing else.
    public var contextIsMeasured: Bool {
        guard context > 0 else { return prompt > 0 }
        return contextSource == "provider"
    }

    /// The whole session, as the line under the composer says it.
    ///
    /// What this replaces and why: the line used to carry the **last turn's** figures, which the
    /// transcript already ends that turn with (a `note` row, "3 model calls · 2 tool calls · $0.01") —
    /// so the same numbers were on screen twice, and the figures that were *not* anywhere on screen
    /// were the session's. A reader deciding whether to keep going is asking about the conversation,
    /// not about the turn they have just read the end of.
    ///
    /// `in / out` rather than a single total, and that is the one place this could mislead: the cache
    /// reads are neither — they are counted separately because they are billed separately, and they
    /// are the largest number of the three in a long conversation. A single "189M tokens" that is
    /// four fifths cache reads would read as a spend rather than as a saving.
    ///
    /// Empty for a session that has asked nothing, which is the same convention `contextFill` uses:
    /// a line of zeroes is a claim that a turn was free, and there has not been a turn.
    public var sessionSummary: String {
        guard turns > 0 else { return "" }
        var parts: [String] = []
        parts.append("\(turns) model call\(turns == 1 ? "" : "s")")
        parts.append("\(TokenText.compact(input)) in / \(TokenText.compact(output)) out")
        // Thinking is part of what was bought and invisible in the answer, which is the case where a
        // reader wonders what they paid for. Left out rather than shown as `0` when the provider does
        // not report it: that is a fact about the provider, not about the conversation.
        if reasoning > 0 {
            parts.append("\(TokenText.compact(reasoning)) thinking")
        }
        return parts.joined(separator: " · ")
    }
}

/// The three rates for one model, as the shell formatted them.
///
/// **Strings rather than numbers, deliberately.** These are drawn as three columns read *down* a menu
/// — is this model dearer than that one — and a column that moves cannot be read that way. Equal widths
/// are a fact about characters, so the side that owns the catalog does the cutting (`Pricing::columns`
/// in `core/model_catalog.mbt`) rather than this side re-deriving it from Doubles.
///
/// USD per million tokens. The unit itself travels once, on `ModelCatalog.unit`.
public struct ModelPrices: Equatable, Decodable, Sendable {
    public let input: String
    public let output: String
    public let cached: String

    /// What a build that predates the price columns sends. Drawn as three em dashes rather than as
    /// zeros: a menu row reading `0.00` would be claiming the model is free.
    public static let unknown = ModelPrices(input: "—", output: "—", cached: "—")

    public init(input: String, output: String, cached: String) {
        self.input = input
        self.output = output
        self.cached = cached
    }
}

/// One entry in the model picker.
public struct ModelChoice: Equatable, Decodable, Identifiable {
    /// The wire id: what goes in the request, and what `send` names.
    public let id: String
    /// What to draw. The id is not always the right thing to show a reader.
    public let label: String
    /// Whether this model accepts images. Shown in the picker because a reader who has just attached
    /// a screenshot is the one choosing a model.
    public let vision: Bool
    /// What it costs, already cut to its column.
    public let prices: ModelPrices

    public init(id: String, label: String, vision: Bool, prices: ModelPrices = .unknown) {
        self.id = id
        self.label = label
        self.vision = vision
        self.prices = prices
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, vision, prices
    }

    /// `prices` is read leniently: a shell that predates the columns sends none, and a missing value
    /// draws as em dashes in that shell's own menu rather than as a catalog this side refuses.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        label = try fields.decode(String.self, forKey: .label)
        vision = try fields.decode(Bool.self, forKey: .vision)
        prices = try fields.decodeIfPresent(ModelPrices.self, forKey: .prices) ?? .unknown
    }
}

/// The models this build can call, and which one the session is on.
public struct ModelCatalog: Equatable, Decodable {
    public let items: [ModelChoice]
    /// The session's own model id. Empty until the shell says, which is drawn as "no model yet"
    /// rather than as a guess.
    public let current: String
    /// What the prices are denominated in and which column is which, said once for the whole menu.
    /// Empty for a shell that does not send it, and the menu then draws no header.
    public let unit: String

    public static let empty = ModelCatalog(items: [], current: "", unit: "")

    public init(items: [ModelChoice], current: String, unit: String = "") {
        self.items = items
        self.current = current
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case items, current, unit
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        items = try fields.decode([ModelChoice].self, forKey: .items)
        current = try fields.decode(String.self, forKey: .current)
        // Absent from a shell older than the price columns: a missing header draws no header, which is
        // what that shell's menu did — rather than refusing to decode the whole catalog, which would
        // leave a picker with nothing in it.
        unit = try fields.decodeIfPresent(String.self, forKey: .unit) ?? ""
    }

    public var currentChoice: ModelChoice? {
        items.first { $0.id == current }
    }

    /// What to draw for the model in force. The label when the shell knows it, the raw id when the
    /// session's log names a model this build does not have — which is a state worth showing rather
    /// than hiding, because every figure on the line below is priced by that model.
    public var currentLabel: String {
        currentChoice?.label ?? current
    }
}

/// Numbers as the composer's line draws them.
///
/// In Swift rather than on the wire because they are presentation, and because the web UI has its own
/// helpers for the same job in TypeScript: what both have to agree on is the figure, not the comma.
public enum TokenText {
    /// A count as a reader reads it: thousands abbreviated, because `18422` is a number nobody takes
    /// in at a glance in a line of small grey text.
    public static func compact(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        if value < 1_000_000 {
            let thousands = (Double(value) / 1000.0 * 10.0).rounded() / 10.0
            return trim(thousands) + "k"
        }
        let millions = (Double(value) / 1_000_000.0 * 10.0).rounded() / 10.0
        return trim(millions) + "M"
    }

    /// The exact count, grouped: what a reader checks against a bill.
    public static func exact(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// `1.2k` rather than `1.0k`; `12k` rather than `12.0k`.
    private static func trim(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        return String(format: "%.1f", value)
    }
}
