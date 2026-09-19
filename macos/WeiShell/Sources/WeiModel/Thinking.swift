import Foundation

/// One level of thinking a model can be asked for.
///
/// The label, the sentence and the default flag all arrive from the shell, and that is the point
/// rather than laziness: which levels exist is a fact about the model (the catalog is compiled into
/// the MoonBit side, which is also the side that refuses a level it does not know), and what a level
/// *means* is a fact about the provider's effort strings. A host that re-derived either would be a
/// second place for them to disagree — the same argument the model picker is drawn under.
///
/// The id is what goes back over the wire, and it is the only field here that has to match something
/// on the other side.
public struct ThinkLevel: Equatable, Decodable, Identifiable, Sendable {
    public let id: String
    /// What the menu shows.
    public let label: String
    /// The one line beside it saying what it does. Empty for a level this build has no words for.
    public let detail: String
    /// Whether this is the level a session runs at when nobody has said. Drawn in the menu, because
    /// "which one do I get" is otherwise a question the reader has to answer by experiment.
    public let isDefault: Bool

    public init(id: String, label: String, detail: String, isDefault: Bool) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, detail
        // `default` is a Swift keyword and a JSON field that reads perfectly well on the producing
        // side: renamed here rather than escaped there, so the wire keeps the name the shell chose.
        case isDefault = "default"
    }
}

/// The thinking levels the session's model offers, and the one in force.
///
/// Sent whenever either half changes — a turn starting, a model switch, or the reader picking a level
/// — so the menu is a snapshot rather than a running total, the same shape the model catalog has.
public struct ThinkLevels: Equatable, Decodable, Sendable {
    public let items: [ThinkLevel]
    /// The level the next turn will ask for. Always one of `items`, because the shell settles it
    /// against the model before it says it.
    public let current: String

    public static let empty = ThinkLevels(items: [], current: "")

    public init(items: [ThinkLevel], current: String) {
        self.items = items
        self.current = current
    }

    public var currentLevel: ThinkLevel? {
        items.first { $0.id == current }
    }

    /// What to draw on the closed menu.
    ///
    /// The label when the shell knows the level, the raw id when a session's log names one this build
    /// has never heard of — which is a state worth showing rather than one worth hiding, because it is
    /// the level that will actually be sent. Empty only before the shell has said anything, which the
    /// menu draws as a plain "Thinking" with nothing picked.
    public var currentLabel: String {
        if let known = currentLevel { return known.label }
        return current
    }

    /// Whether the reader can choose anything. False before the shell has answered, which is what
    /// keeps a menu of nothing from being offered on the first frame.
    public var isOffered: Bool {
        !items.isEmpty
    }
}
