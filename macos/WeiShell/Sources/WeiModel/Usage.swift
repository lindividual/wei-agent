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
public struct TurnUsage: Equatable {
    public let modelCalls: Int
    public let toolCalls: Int
    public let total: Int
    public let input: Int
    public let output: Int
    /// Already formatted by the shell, which is where the decimals rule lives.
    public let cost: String

    public init(
        modelCalls: Int,
        toolCalls: Int,
        total: Int,
        input: Int,
        output: Int,
        cost: String
    ) {
        self.modelCalls = modelCalls
        self.toolCalls = toolCalls
        self.total = total
        self.input = input
        self.output = output
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
    /// The size of the most recent request, as the provider measured it. Zero before anything has
    /// been sent, which is what that means rather than a missing value.
    public let prompt: Int
    /// The context window of the model this session runs on.
    public let window: Int
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
        case turns, total, input, output, prompt, window, cost
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
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
        prompt = try fields.decode(Int.self, forKey: .prompt)
        window = try fields.decode(Int.self, forKey: .window)
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
                cost: cost
            )
        } else {
            last = nil
        }
    }

    /// How full the context is, as a fraction of the window. `nil` before anything has been sent,
    /// because an empty bar and a bar at zero are two different claims.
    public var contextFill: Double? {
        guard prompt > 0, window > 0 else { return nil }
        return min(1.0, Double(prompt) / Double(window))
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
