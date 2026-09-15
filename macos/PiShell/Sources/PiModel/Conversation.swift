import Foundation

/// One row of the transcript.
///
/// One struct with a kind rather than a case per shape, and the reason is the streaming update:
/// a delta has to find *the row with this id* and append to it, which is a lookup by identity, not
/// a match on a payload. Keeping the kind as a field means the append does not have to know which
/// kinds it could be appending to.
public struct Row: Identifiable, Equatable, Decodable {
    public enum Kind: String, Equatable, Decodable {
        case user
        case reply
        case thinking
        case tool
        case note
    }

    public let id: String
    public var kind: Kind
    public var text: String = ""
    /// Whether this row has stopped changing.
    ///
    /// It is what makes rendering markdown affordable: a block that is still streaming is drawn as
    /// plain text, because re-parsing the whole of it on every delta is quadratic — the web UI
    /// learned that with 40KB of reasoning in 64-character frames. Markdown is for the finished
    /// article.
    public var complete: Bool = false
    /// Tools only.
    public var name: String = ""
    public var detail: String = ""
    public var output: String = ""
    public var isError: Bool = false

    /// `isError` crosses as `error`, the same name the `tool` event uses for the same fact — one
    /// field, spelled once, so a row from a history and a row from a live stream decode alike.
    private enum CodingKeys: String, CodingKey {
        case id, kind, text, complete, name, detail, output
        case isError = "error"
    }

    public init(
        id: String,
        kind: Kind,
        text: String = "",
        complete: Bool = false,
        name: String = "",
        detail: String = "",
        output: String = "",
        isError: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.complete = complete
        self.name = name
        self.detail = detail
        self.output = output
        self.isError = isError
    }
}

/// The conversation, as facts arrive.
///
/// A value type with a `mutating apply`, so that the whole of the transcript's behaviour is
/// testable without a runtime, a socket or a window — the events are the interface, and the tests
/// are a list of them.
public struct Conversation: Equatable {
    public private(set) var rows: [Row] = []
    public private(set) var status: String = ""
    /// The last thing the shell said about itself. Kept apart from the status line because it is a
    /// fact about the session rather than about this moment.
    public private(set) var ready: PiEvent?

    private var nextNote = 0

    public init() {}

    /// Which block the deltas are currently landing in, per kind.
    private var openBlock: [Row.Kind: String] = [:]

    public mutating func apply(_ event: PiEvent) {
        switch event {
        case let .history(rows):
            // A whole session in one event, because the host did not watch this one happen: every
            // block in it is finished and no delta is coming for any of them. Replacing rather than
            // appending is the point — the rows belong to a different session from the ones on
            // screen.
            self.rows = rows
            status = ""
            openBlock.removeAll()
            nextNote = 0
            return
        case .sessions, .session, .settings:
            // The sidebar's and the panel's own facts. The transcript is unchanged by any of them: a
            // switch says which session is open and only the history that follows says what is in it.
            return
        case let .ready(session, model, cwd, key):
            ready = event
            _ = (session, model, cwd, key)
            status = ""

        case let .user(text):
            rows.append(Row(id: "user-\(rows.count)", kind: .user, text: text, complete: true))
            // The prompt is what the answer is about, so everything before it is finished.
            closeAllBlocks()

        case let .reply(id, delta):
            append(id: id, kind: .reply, delta: delta)

        case let .thinking(id, delta):
            append(id: id, kind: .thinking, delta: delta)

        case let .tool(id, name, detail, done, output, isError):
            // One id for the whole life of the tool: the running row is the one the report
            // replaces, so a finished tool does not leave a spinner behind it.
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].name = name
                rows[index].detail = detail.isEmpty ? rows[index].detail : detail
                rows[index].output = output
                rows[index].isError = isError
                rows[index].complete = done
            } else {
                var row = Row(id: id, kind: .tool)
                row.name = name
                row.detail = detail
                row.output = output
                row.isError = isError
                row.complete = done
                rows.append(row)
            }
            // A tool call ends the answer block it interrupted, for the same reason the web UI
            // does: what comes next is about the tool, not a continuation of what came before.
            if done {
                closeAllBlocks()
            }

        case let .status(text):
            status = text

        case let .end(text, calls, tools, cost):
            closeAllBlocks()
            status = ""
            // The figures are a note rather than a status, because they are about a turn that is
            // over. Saying them on the status line too would put them on screen twice.
            nextNote += 1
            var row = Row(id: "note-\(nextNote)", kind: .note)
            row.text = summary(text: text, calls: calls, tools: tools, cost: cost)
            row.complete = true
            rows.append(row)

        case let .error(text):
            nextNote += 1
            var row = Row(id: "note-\(nextNote)", kind: .note)
            row.text = text
            row.complete = true
            rows.append(row)
            status = ""
        }
    }

    private mutating func append(id: String, kind: Row.Kind, delta: String) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].text += delta
            return
        }
        // A new block id means the previous one of this kind is over, which is the same rule the
        // web UI uses to settle a block: the server names a block once and moves to the next one
        // when the text stops being a continuation.
        if let previous = openBlock[kind], let index = rows.firstIndex(where: { $0.id == previous }) {
            rows[index].complete = true
        }
        openBlock[kind] = id
        rows.append(Row(id: id, kind: kind, text: delta))
    }

    private mutating func closeAllBlocks() {
        for (_, id) in openBlock {
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].complete = true
            }
        }
        openBlock.removeAll()
    }

    /// What one turn cost, said in a line.
    ///
    /// `text` is what the figures cannot say — which guard stopped the turn — and is empty for a
    /// turn that finished, in which case the answer is the report and there is nothing to add.
    private func summary(text: String, calls: Int, tools: Int, cost: String) -> String {
        var parts: [String] = []
        if !text.isEmpty {
            parts.append(text)
        }
        if calls > 0 {
            parts.append("\(calls) model call\(calls == 1 ? "" : "s")")
        }
        if tools > 0 {
            parts.append("\(tools) tool call\(tools == 1 ? "" : "s")")
        }
        if let value = Double(cost), value > 0 {
            parts.append("$\(cost)")
        }
        return parts.joined(separator: " · ")
    }
}
