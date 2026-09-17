import Foundation

/// The session list, as the `sessions` event describes it.
///
/// A flat description rather than a link to the store: the host draws a sidebar, and a sidebar needs
/// labels, times and two flags — not file paths it would have to interpret. `macos/appffi/sessions.mbt`
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

    public var id: String { path }

    /// The wire's `id` and this type's identity are different facts, so the decoded field is named
    /// for what it is rather than for what it comes from.
    private enum CodingKeys: String, CodingKey {
        case path, label, modified, current, running
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

/// One finished block of markdown, as the shell parsed it.
///
/// The parse happens in the shell — `md/`, which is cmark, the same engine the web UI renders with —
/// and crosses as data, because a native host has no parser of its own that agrees with it:
/// `AttributedString(markdown:)` takes the *source* rather than a parse, so a table arrives as its own
/// punctuation and a fenced block's language is dropped on the floor.
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
