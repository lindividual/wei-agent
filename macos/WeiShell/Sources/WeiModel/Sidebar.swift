import Foundation

/// The session list, as the `sessions` event describes it.
///
/// A flat description rather than a link to the store: the host draws a sidebar, and a sidebar needs
/// labels, times and three flags — not file paths it would have to interpret. `macos/appffi/sessions.mbt`
/// is the other half of this shape, and the literals in `macos/appffi/app_wbtest.mbt` and
/// `WeiModelTests/SidebarTests.swift` are the same ones.
public struct SessionRow: Identifiable, Equatable, Decodable {
    /// The file. The identity of a session, and the only name that survives a rename — which is why
    /// the row carries it rather than an index into a list the shell might have reordered.
    public let path: String
    /// Eight hex characters, as upstream names its files. What the web UI shows for a session nobody has
    /// asked anything in yet, and read from the wire's `id`.
    ///
    /// Not the row's identity, which is `path`: two sessions in different workspaces could share
    /// these eight characters, and the list has to be able to tell them apart.
    public let shortID: String
    /// What to call it: the reader's own name, else the first question, else the id.
    public let label: String
    /// Milliseconds since the epoch, so that the host does its own "3 minutes ago" — the age of a row
    /// changes while the list stands still, and only the side drawing it can say so.
    public let modified: Int64
    /// Whether this is the session on screen.
    public let current: Bool
    /// Whether a turn is running *in this session*.
    ///
    /// Per row rather than per window, because more than one can be true at once: two conversations can
    /// each have a turn in flight, and the spinner is the only thing on the sidebar that says a
    /// background one is still going.
    public let running: Bool
    /// Whether the reader keeps this session at the top of the list.
    ///
    /// A fact about the reader's list rather than about the conversation, which is why it is a flag on
    /// the row and not something in the log: see `core/pins.mbt`. Nothing on this side sorts by it
    /// either — the pinned rows keep the order they arrive in, and the *view* is what lifts them into
    /// their own section above the day headings.
    public let pinned: Bool

    /// A memberwise initializer, for building a row outside the wire: the tests, and every place a row
    /// is stood in for. `pinned` defaults because most rows are not, and a call site that has to say
    /// "not pinned" for a test about something else is noise.
    public init(
        path: String,
        shortID: String,
        label: String,
        modified: Int64,
        current: Bool,
        running: Bool,
        pinned: Bool = false
    ) {
        self.path = path
        self.shortID = shortID
        self.label = label
        self.modified = modified
        self.current = current
        self.running = running
        self.pinned = pinned
    }

    /// **Decoded by hand rather than synthesized, for one field.** `pinned` is absent from every shell
    /// built before it, and a row that failed to decode would empty the whole list — so it reads as
    /// "no" when it is not there, which is the same rule the event decoder applies to every other
    /// field that arrived after its first reader.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        path = try fields.decode(String.self, forKey: .path)
        shortID = try fields.decode(String.self, forKey: .shortID)
        label = try fields.decode(String.self, forKey: .label)
        modified = try fields.decode(Int64.self, forKey: .modified)
        current = try fields.decode(Bool.self, forKey: .current)
        running = try fields.decode(Bool.self, forKey: .running)
        pinned = try fields.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    public var id: String { path }

    /// The wire's `id` and this type's identity are different facts, so the decoded field is named
    /// for what it is rather than for what it comes from.
    private enum CodingKeys: String, CodingKey {
        case path, label, modified, current, running, pinned
        case shortID = "id"
    }
}

/// The session the two move-between-sessions commands should show next, or `nil` when there is no
/// other one to move to.
///
/// `step` is 1 for the row below and −1 for the one above, and it wraps at both ends: a reader
/// holding the shortcut down is cycling, and a list that stops at the last row is a list that looks
/// like the shortcut broke.
///
/// `rows` is the list in the order the sidebar draws it, and `path` the session on screen. A
/// `current` that is not in `rows` — a session created in this process and not yet written, or one
/// the store has since lost — has no neighbour, which is a refusal rather than a move to the top of
/// the list: nothing was asked for that a jump to an arbitrary row would satisfy.
///
/// Pure, and here rather than in the client, for the reason this whole module is apart from the
/// runtime: the ordering rule is the part that can be wrong in a way a test can see.
public func neighbourSession(rows: [SessionRow], from path: String, step: Int) -> SessionRow? {
    guard rows.count > 1, let here = rows.firstIndex(where: { $0.path == path }) else { return nil }
    let count = rows.count
    // `%` on a negative index stays negative in Swift, hence the second correction.
    let next = (((here + step) % count) + count) % count
    return rows[next]
}

/// The sidebar's order, kept as the reader is already looking at it.
///
/// **The wire's order is "the most recently written first", and that order is not stable enough to draw.**
/// `list_workspaces` sorts projects by the mtime of the newest session in each one
/// (`platform/session.mbt`), and a turn appends to its session's file as it works — measured on a live
/// store: two projects with turns running sat **0s and 2s** apart and kept taking turns at being
/// "newest". Every `sessions` event therefore arrived with those two rows swapped, and the rest of the
/// column moved down a row (32 points) and back a moment later. The rows *inside* a group are ordered
/// by the same field, which is what the middle column lists and what the register under the projects is
/// drawn from.
///
/// So the rule is split in two, and the split is the point. *Which project was written to last* is the
/// shell's answer, and it is the **seed**: the first list of a run lays the column out the way the store
/// has it. After that the window owns the order, because "the list must not rearrange itself under the
/// reader" is a fact about this window and not about the store — and a session that has just
/// been written is not a session the reader has touched.
///
/// What does move is what the list has never seen: it goes to the top of its group. That is the reader's
/// own action arriving — a session they just started, a project they just added — and it has to be where
/// they are looking. See `ShellClient.receive` for where this is applied.
public func stableSidebarOrder(incoming: [SessionGroup], previous: [SessionGroup]) -> [SessionGroup] {
    var oldRank: [String: Int] = [:]
    var oldRows: [String: [String]] = [:]
    // **Two lookups, because this function was quadratic in the size of a store.** It ran per group per
    // *row* — `Array.contains` over the previous order to find what was unseen, and `first(where:)`
    // over the incoming rows to fetch each one that stayed — so a project with a thousand sessions
    // paid a thousand squared string comparisons, on **every** `sessions` event (each turn's start and
    // end, every rename, every pin). Measured on 10000 synthetic rows: **23.1 ms → 1.05 ms**.
    //
    // The two dictionaries are the same facts the loops were re-deriving: which paths were seen, and
    // where each incoming row is.
    var oldSeen: [String: Set<String>] = [:]
    for (rank, group) in previous.enumerated() {
        oldRank[group.cwd] = rank
        let paths = group.sessions.map(\.path)
        oldRows[group.cwd] = paths
        oldSeen[group.cwd] = Set(paths)
    }

    var kept: [(Int, SessionGroup)] = []
    var fresh: [SessionGroup] = []
    for group in incoming {
        let rows: [SessionRow]
        if let seen = oldSeen[group.cwd], let order = oldRows[group.cwd] {
            // Unseen rows keep the wire's position, which is the top — the shell puts a session the
            // reader has just started there — and seen rows keep the place they are already in, which
            // is why the second half is walked in the *old* order rather than the new one.
            var byPath: [String: SessionRow] = [:]
            byPath.reserveCapacity(group.sessions.count)
            for row in group.sessions { byPath[row.path] = row }
            let unseen = group.sessions.filter { !seen.contains($0.path) }
            let stayed = order.compactMap { byPath[$0] }
            rows = unseen + stayed
        } else {
            rows = group.sessions
        }
        let rebuilt = SessionGroup(
            cwd: group.cwd, label: group.label, current: group.current, sessions: rows
        )
        if let rank = oldRank[group.cwd] {
            kept.append((rank, rebuilt))
        } else {
            fresh.append(rebuilt)
        }
    }
    return fresh + kept.sorted { $0.0 < $1.0 }.map(\.1)
}

/// One working directory's sessions, most recently used first.
public struct SessionGroup: Identifiable, Equatable, Decodable {
    /// Where the tools run. The identity of a group, and `upstream`'s own name for a workspace.
    public let cwd: String

    /// A memberwise initializer, for building a group outside the wire: the tests, and the search —
    /// which narrows a group's sessions without the shell knowing, and a filtered group is still a
    /// group. Same directory, same title, fewer rows.
    public init(cwd: String, label: String, current: Bool, sessions: [SessionRow]) {
        self.cwd = cwd
        self.label = label
        self.current = current
        self.sessions = sessions
    }

    /// What to call it: the reader's title for the workspace, else the last path component.
    public let label: String
    /// Whether the session on screen lives here.
    public let current: Bool
    public let sessions: [SessionRow]

    public var id: String { cwd }
}

/// Which project a session belongs to, named the way the project list names it.
///
/// Two places need this answer and they must not disagree: the session list, where the name is the subtitle
/// under a row, and the flat "Running sessions" list, where it is what makes one list of every project
/// readable. The session row itself carries no workspace — identity is the file path, and a session found by
/// search comes from a project the reader is not browsing — so the lookup is by containment, and empty when
/// the store has not listed it yet.
public func workspaceLabel(of row: SessionRow, in groups: [SessionGroup]) -> String {
    for group in groups where group.sessions.contains(where: { $0.path == row.path }) {
        return group.label
    }
    return ""
}

/// What the list calls a session, by path — the name to use for one *off* the list.
///
/// The notice above the transcript names a conversation the reader is not looking at, and the only
/// place that name exists on this side is the sidebar row the shell sent. The fallback is the row's own:
/// a session whose first turn has not been written yet has no label, and eight hex characters are still
/// a way to recognise it — a notice that said nothing at all about *which* conversation it was about
/// would be a notice the reader cannot act on.
///
/// Empty when the store has not listed it, which is not a failure: a session the shell has open but not
/// yet written has no row here, and the line is drawn without a name.
public func sessionName(of path: String, in groups: [SessionGroup]) -> String {
    for group in groups {
        if let row = group.sessions.first(where: { $0.path == path }) {
            return row.label.isEmpty ? row.shortID : row.label
        }
    }
    return ""
}

/// One finished block of markdown, as the shell parsed it.
///
/// The parse happens in the shell — `md/`, which is cmark, the same engine the web UI renders with — and
/// crosses as data. Not because a native host has no markdown parser: `AttributedString(markdown:)` does
/// parse tables, with their alignments, and does keep a fence's language. It crosses because the two front
/// ends have to agree, and they only can if the parse is one parser's — the system's follows the OS version
/// rather than this build, and the picture policy it applies (`src` of any scheme, including `javascript:`)
/// is not the one `md/walk.mbt` decided.
///
/// Coarse on purpose. What crosses is what this agent's answers actually use: headings, paragraphs,
/// code, lists, quotes, rules, tables, and a few inline spans. Anything outside that set is plain text
/// rather than nothing — a block the host cannot draw is still text it can show.
public enum Block: Equatable, Decodable {
    case paragraph([Span])
    case heading(level: Int, spans: [Span])
    case code(lang: String, text: String)
    case bullets([[Block]])
    case numbers(start: Int, items: [[Block]])
    case quote([Block])
    case rule
    case table(header: [[Span]], rows: [[[Span]]], align: [Align])

    /// How a column's cells line up. The one thing a markdown table says that its cells do not.
    public enum Align: String, Equatable, Decodable {
        case left
        case center
        case right
    }

    /// A run of styled text inside a block.
    ///
    /// A flat list rather than a tree, which is what makes `**bold and *italic***` one pass on this
    /// side: the nesting is *accumulated* as the host walks down. `link` is the one case that carries
    /// its own spans, because the target is a property of the link rather than of the words in it —
    /// and `image` is the same split HTML's `src`/`alt` makes: what to draw, and what to say when it
    /// cannot be drawn.
    public indirect enum Span: Equatable, Decodable {
        case text(String)
        case code(String)
        case emph([Span])
        case strong([Span])
        case strike([Span])
        case link(url: String, spans: [Span])
        case image(url: String, alt: String)

        /// The same tagged shape one level down, and the same reason for it.
        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: SpanKeys.self)
            let kind = try fields.decode(SpanKind.self, forKey: .t)
            switch kind {
            case .text:
                self = .text(try fields.decode(String.self, forKey: .text))
            case .code:
                self = .code(try fields.decode(String.self, forKey: .text))
            case .em:
                self = .emph(try fields.decode([Span].self, forKey: .spans))
            case .strong:
                self = .strong(try fields.decode([Span].self, forKey: .spans))
            case .del:
                self = .strike(try fields.decode([Span].self, forKey: .spans))
            case .link:
                self = .link(
                    url: try fields.decode(String.self, forKey: .url),
                    spans: try fields.decode([Span].self, forKey: .spans)
                )
            case .image:
                self = .image(
                    url: try fields.decode(String.self, forKey: .url),
                    alt: try fields.decode(String.self, forKey: .alt)
                )
            }
        }

        private enum SpanKeys: String, CodingKey {
            case t, text, spans, url, alt
        }

        private enum SpanKind: String, Decodable {
            case text, code, em, strong, del, link, image
        }
    }

    /// Tagged objects — `{"t":"heading",…}` — so a field added later cannot shift the meaning of one
    /// already there. The same reasoning as the events, and the same decoder.
    private enum CodingKeys: String, CodingKey {
        case t, level, text, lang, items, start, blocks, header, rows, align, spans
    }

    private enum Kind: String, Decodable {
        case p, h, code, ul, ol, quote, hr, table
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try fields.decode(Kind.self, forKey: .t)
        switch kind {
        case .p:
            self = .paragraph(try fields.decode([Span].self, forKey: .spans))
        case .h:
            self = .heading(
                level: try fields.decode(Int.self, forKey: .level),
                spans: try fields.decode([Span].self, forKey: .spans)
            )
        case .code:
            self = .code(
                lang: try fields.decode(String.self, forKey: .lang),
                text: try fields.decode(String.self, forKey: .text)
            )
        case .ul:
            self = .bullets(try fields.decode([[Block]].self, forKey: .items))
        case .ol:
            self = .numbers(
                start: try fields.decodeIfPresent(Int.self, forKey: .start) ?? 1,
                items: try fields.decode([[Block]].self, forKey: .items)
            )
        case .quote:
            self = .quote(try fields.decode([Block].self, forKey: .blocks))
        case .hr:
            self = .rule
        case .table:
            self = .table(
                header: try fields.decode([[Span]].self, forKey: .header),
                rows: try fields.decode([[[Span]]].self, forKey: .rows),
                align: try fields.decode([Align].self, forKey: .align)
            )
        }
    }
}

/// The part of a row's text that its parse does not cover: the one block that is still being written.
///
/// The shell parses only up to the end of the last line that cannot change again, and says where that
/// is (`Row.parsed`). What follows is one block the model has not finished — an open paragraph, an open
/// fence, an open table — and it is drawn from the text, which is what the host has been appending all
/// along. That is the whole trick of rendering an answer while it arrives: the finished part is a parse
/// and does not move, and the growing part is text and is allowed to.
///
/// Empty when the blocks are the whole row, which is every finished block and every row from the log.
///
/// Also empty for a boundary of `0`, which is not a boundary at all: a boundary is the far side of a
/// newline, so the smallest one the shell can send is 1. Reading that as "nothing is parsed yet" would
/// draw the whole row as text *under* the blocks that cover it — every word twice — so the reading here
/// is the one that shows less rather than more.
///
/// The boundary is counted in **UTF-16 code units** because that is what the shell counted in
/// (`String::length`); `String.Index(utf16Offset:in:)` is what keeps this right for a row with an emoji
/// ahead of its last blank line, where the two units disagree and dropping `parsed` *characters* would
/// cut a word in half.
///
/// The tail is trimmed, and for the same reason `ParagraphView` drops a whitespace-only run: the
/// newlines around a boundary are how the markdown was written, not a gap the reader asked for. A tail
/// that is nothing but whitespace — a blank line written after the last finished block — is therefore
/// drawn as nothing rather than as an empty line.
public func unparsedTail(text: String, parsed: Int) -> String {
    guard parsed > 0, parsed < text.utf16.count else { return "" }
    let start = String.Index(utf16Offset: parsed, in: text)
    return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
}
