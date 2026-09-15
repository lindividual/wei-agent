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
    /// The parse of `text`, when the shell has sent one.
    ///
    /// `nil` for a row that is still arriving, and for one whose text has nothing to parse — the
    /// shell sends a parse once, when a block stops growing, because re-parsing a growing block on
    /// every delta is quadratic (the web UI measured it: 40KB of reasoning in 64-character frames).
    /// The view's rule is the simple one: draw the parse if it is here, the text otherwise.
    public var blocks: [Block]?

    /// `isError` crosses as `error`, the same name the `tool` event uses for the same fact — one
    /// field, spelled once, so a row from a history and a row from a live stream decode alike.
    private enum CodingKeys: String, CodingKey {
        case id, kind, text, complete, name, detail, output, blocks
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
        isError: Bool = false,
        blocks: [Block]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.complete = complete
        self.name = name
        self.detail = detail
        self.output = output
        self.isError = isError
        self.blocks = blocks
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
    /// The pictures on the next prompt, as the shell holds them.
    public private(set) var attachments: [Attachment] = []
    /// Whether the model the session is running on can be shown a picture at all. Drawn next to the
    /// attachments, because it is only interesting when there is one.
    public private(set) var canSendImages = true
    /// What the session has used, and what its last turn cost. `nil` until the shell says, which is
    /// drawn as absent rather than as zeroes.
    public private(set) var usage: Usage?
    /// Whether a turn is in flight.
    ///
    /// Read from the events rather than kept as its own flag across the wire: a turn starts when the
    /// shell echoes the prompt and ends at `end` — or at `error`, which is how the path that caught a
    /// failure ends one. There is no third way out, so there is nothing to keep in step.
    public private(set) var running = false
    /// The last thing the shell said about itself. Kept apart from the status line because it is a
    /// fact about the session rather than about this moment.
    public private(set) var ready: PiEvent?

    private var nextNote = 0

    /// Which turn the live rows on screen belong to.
    ///
    /// A live row's identity is this and the id the shell named, never the id alone. The shell names
    /// its blocks per turn — `<kind>-<turn>-<seq>`, so two turns cannot collide — but the host is the
    /// side that would *lose* a transcript if that stopped being true, and a delta is appended to
    /// whatever row carries the id it arrived under. Scoping here costs a counter and makes a
    /// repeated name from the shell append a new row instead of writing into the previous turn's:
    /// the failure it prevents is an answer that grows inside the one before it while its own
    /// thinking and tool rows are overwritten, which is silent and looks like nothing happening.
    ///
    /// The boundary is free: a prompt is one turn, and the shell echoes every prompt back.
    private var turn = 0

    /// The name a live row is looked up and stored under.
    ///
    /// The separator is one the shell never puts in an id, which is what keeps a scoped id from ever
    /// colliding with a history row, a user row or the note a finished turn leaves behind.
    private func live(_ id: String) -> String { "\(turn)/\(id)" }

    public init() {}

    /// Which block the deltas are currently landing in, per kind.
    private var openBlock: [Row.Kind: String] = [:]

    /// Apply one event.
    ///
    /// The session is not a parameter: the host routes by session *before* calling this — an event for
    /// another conversation goes to that conversation's own `Conversation`, not here — so the only
    /// events that reach this one are the ones this transcript is made of.
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
        case let .blocks(id, blocks):
            // The row stopped growing and this is how it should be drawn. Patched in place rather
            // than appended: the row is already on screen from its deltas, and the parse describes
            // the text that is already there.
            if let index = rows.firstIndex(where: { $0.id == live(id) }) {
                rows[index].blocks = blocks
            }

        case .sessions, .session, .settings, .models, .jobs:
            // The sidebar's, the panel's and the picker's own facts. The transcript is unchanged by any
            // of them: a switch says which session is open and only the history that follows says
            // what is in it.
            return

        case let .images(items, canSend):
            // Whole, not merged: the shell holds the list, and the composer draws it. A host that
            // applied its own adds and removes would be a second opinion about what is on its way.
            attachments = items
            canSendImages = canSend

        case let .usage(value):
            usage = value
        case let .ready(model, cwd, key):
            ready = event
            _ = (model, cwd, key)
            status = ""

        case let .user(text, continued):
            running = true
            // The prompt's own row is named by the turn rather than by how many rows there are: a
            // count is not an identity — a `history` replace resets it, and two rows that happened to
            // land on the same number would be one row as far as `ForEach` is concerned.
            turn += 1
            // A continued turn gets the new set of row names without a second question on screen:
            // the question is already the last user row, from the run that was interrupted.
            if !continued {
                rows.append(Row(id: "user-\(turn)", kind: .user, text: text, complete: true))
            }
            // The prompt is what the answer is about, so everything before it is finished.
            closeAllBlocks()

        case let .reply(id, delta):
            append(id: live(id), kind: .reply, delta: delta)

        case let .thinking(id, delta):
            append(id: live(id), kind: .thinking, delta: delta)

        case let .tool(id, name, detail, done, output, isError):
            // One id for the whole life of the tool: the running row is the one the report
            // replaces, so a finished tool does not leave a spinner behind it.
            let key = live(id)
            if let index = rows.firstIndex(where: { $0.id == key }) {
                rows[index].name = name
                rows[index].detail = detail.isEmpty ? rows[index].detail : detail
                rows[index].output = output
                rows[index].isError = isError
                rows[index].complete = done
            } else {
                var row = Row(id: key, kind: .tool)
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

        case let .note(text, label):
            // A row at the point in the conversation where the compacting happened, because that is
            // where the reader's own words stopped being what the model was sent. Everything before
            // it is finished: what it replaces is above it, and the summary is a different thing
            // from the answer that follows.
            closeAllBlocks()
            nextNote += 1
            var row = Row(id: "note-\(nextNote)", kind: .note)
            row.text = text
            row.name = label
            row.complete = true
            rows.append(row)

        case let .end(text, calls, tools, cost):
            closeAllBlocks()
            status = ""
            running = false
            // The figures are a note rather than a status, because they are about a turn that is
            // over. Saying them on the status line too would put them on screen twice.
            nextNote += 1
            var row = Row(id: "note-\(nextNote)", kind: .note)
            row.text = summary(text: text, calls: calls, tools: tools, cost: cost)
            row.complete = true
            rows.append(row)

        case let .error(text):
            // A failure during a turn is the turn ending: the shell's own path that catches one says
            // so and then stops. Setting this here rather than waiting for an `end` that is never
            // sent is what keeps the composer from offering Stop for the rest of the afternoon.
            running = false
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
