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
    /// Assistant replies the totals cover, so a reader can tell "expensive" from "long".
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

    public init(id: String, label: String, vision: Bool) {
        self.id = id
        self.label = label
        self.vision = vision
    }
}

/// The models this build can call, and which one the session is on.
public struct ModelCatalog: Equatable, Decodable {
    public let items: [ModelChoice]
    /// The session's own model id. Empty until the shell says, which is drawn as "no model yet"
    /// rather than as a guess.
    public let current: String

    public static let empty = ModelCatalog(items: [], current: "")

    public init(items: [ModelChoice], current: String) {
        self.items = items
        self.current = current
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
