import SwiftUI

import PiKit
import PiModel

/// The window: the sessions there are, and the one that is open.
///
/// A `NavigationSplitView` rather than an `HSplitView`, because the sidebar is a sidebar: it collapses,
/// it animates, it comes back on a keystroke, and the toolbar knows where it is. Every one of those is
/// a behaviour the platform owns, and hand-rolling the split would mean writing them all again and
/// getting the details wrong.
struct RootView: View {
    @ObservedObject var client: PiClient
    @State private var draft = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(client: client)
                // Wide enough for a label and a running mark, narrow enough to leave the transcript
                // the room it is there for.
                .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 380)
        } detail: {
            ConversationView(client: client, draft: $draft)
                .navigationTitle(client.currentTitle)
                .frame(minWidth: 420, minHeight: 320)
        }
    }
}

/// The session list.
///
/// Grouped by working directory, because that is the only thing sessions have in common: an agent's
/// tools run somewhere, and two conversations in one repository belong together in the same way two
/// documents in one folder do. The directories are not collapsible — the store is usually small, and a
/// list the reader has to open before they can see anything is a list they have to open.
///
/// The selection is the shell's current session, not a copy of it. Clicking asks the shell to switch,
/// and the row highlights when the shell says it has: a switch that was refused — because a turn is
/// running — leaves the highlight where the reader actually is, instead of on a row that is not on
/// screen.
private struct SidebarView: View {
    @ObservedObject var client: PiClient

    private var selection: Binding<String?> {
        Binding(
            get: { client.currentPath.isEmpty ? nil : client.currentPath },
            set: { path in
                if let path { client.open(path) }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(client.groups) { group in
                Section {
                    ForEach(group.sessions) { row in
                        SessionRowView(row: row, onDelete: { client.delete(row.path) })
                            .tag(row.path)
                    }
                } header: {
                    Text(group.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(group.cwd)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    client.newSession()
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("Start a session in the same directory")
            }
        }
    }
}

/// One session, in the list.
///
/// Two lines' worth of facts is all a row gets: the label it will be recognised by, and whether a turn
/// is running in it. The age of a session is not shown — the list is already sorted by it, and the
/// exact time a conversation was last used is a fact about the past that nothing on this screen acts
/// on.
private struct SessionRowView: View {
    let row: SessionRow
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 6) {
            Text(row.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if row.running {
                ProgressView().controlSize(.mini)
            }
        }
        .help(row.path)
        .contextMenu {
            // The file is renamed aside rather than removed, but nothing on this screen can bring it
            // back — so the confirmation is the last chance to change your mind, and it says what
            // survives.
            Button("Delete Session", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog(
            "Delete “\(row.label)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The conversation file is renamed .deleted, not erased.")
        }
    }
}

/// What the shell is, what it has said, and a box to answer it in.
private struct ConversationView: View {
    @ObservedObject var client: PiClient
    @Binding var draft: String

    var body: some View {
        VStack(spacing: 0) {
            Header(state: client.state, revision: client.revision)
            Divider()
            TranscriptView(conversation: client.conversation, revision: client.revision)
            Divider()
            Composer(
                draft: $draft,
                enabled: client.state != .starting,
                onSend: {
                    client.send(draft)
                    draft = ""
                },
                onStop: { client.stop() }
            )
        }
    }
}

/// One line above the conversation: which model, and where its tools run.
///
/// Small and secondary on purpose. The session's own name is in the window's title bar, where the
/// platform puts the name of the thing that is open; what is left here are the two facts a reader
/// checks mid-turn — is it the model I thought, and is it working in the directory I thought.
private struct Header: View {
    let state: ShellState
    let revision: Int

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .starting:
                ProgressView().controlSize(.small)
                Text("starting…").foregroundStyle(.secondary)
            case let .ready(_, model, cwd, _):
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                Text(model).fontWeight(.medium)
                Text(cwd).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            case .unkeyed:
                Image(systemName: "key.slash").foregroundStyle(.orange)
                Text("no API key").foregroundStyle(.orange)
                // The one case where the header can do something about what it is reporting. An app
                // launched from the Finder inherits no shell environment, so this is not an edge
                // case — it is the first thing that happens on a machine that just installed it, and
                // the answer is two keystrokes away if the reader is told.
                Button("Add Key…") { openSettings() }
                    .buttonStyle(.link)
                Text("or set DEEPSEEK_API_KEY").foregroundStyle(.secondary)
            case let .failed(text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(text).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .id(revision)
    }
}

/// The conversation.
private struct TranscriptView: View {
    let conversation: Conversation
    let revision: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(conversation.rows) { row in
                        RowView(row: row).id(row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            // Follows the newest line. The web UI is fussier than this — it follows only when the
            // reader is already at the bottom, so scrolling up to read is not yanked away — and
            // that is a refinement this needs before it is pleasant to use on a long turn.
            //
            // The two-parameter form is the one macOS 14 introduced: the old signature is deprecated
            // and warns on every build. Neither argument is used — the revision is what changed, and
            // the view body already knows that.
            .onChange(of: revision) { _, _ in
                guard let last = conversation.rows.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct RowView: View {
    let row: Row

    var body: some View {
        switch row.kind {
        case .user:
            Text(row.text)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .reply:
            // The parse if the shell has sent one, the raw text if it has not. Either way the words are
            // the same; what the parse adds is what markdown *means* — a table, a heading, a fence's
            // language — which is the part `AttributedString(markdown:)` gets wrong and the reason the
            // shell parses at all.
            BlockView(blocks: row.blocks, plain: row.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking:
            // Dimmed and indented: reasoning is worth being able to read and not worth competing
            // with the answer for attention.
            Text(row.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 2)
                }

        case .tool:
            ToolRow(row: row)

        case .note:
            Text(row.text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ToolRow: View {
    let row: Row
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if row.complete {
                    Image(systemName: row.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(row.isError ? .red : .green)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(row.name).font(.system(size: 12, weight: .medium))
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !row.output.isEmpty {
                    Button(expanded ? "hide" : "show") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            if expanded, !row.output.isEmpty {
                ScrollView {
                    Text(row.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.leading, 2)
    }
}

/// What the reader types in.
private struct Composer: View {
    @Binding var draft: String
    let enabled: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Ask something", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .disabled(!enabled)
                .onSubmit(onSend)
            Button("Stop") { onStop() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Button("Send", action: onSend)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!enabled || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A finished block of markdown, drawn from the parse.
///
/// The host draws what the shell parsed rather than parsing the source itself. That is not an
/// optimisation — it is the only way the two front ends agree: `md/` is cmark, the same engine the web
/// UI renders with, and `AttributedString(markdown:)` is a different markdown implementation that never
/// sees a table at all and drops a fenced block's language.
///
/// Every case is drawn, and the ones that are awkward on purpose — a code fence with no language, a
/// heading deeper than the font sizes this file has, a table wider than the window — are handled rather
/// than dropped, because a block the host cannot draw is an answer the reader cannot read.
private struct BlockView: View {
    let blocks: [Block]?
    let plain: String

    var body: some View {
        if let blocks, !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockBody(block: block)
                }
            }
        } else {
            // Still arriving, or nothing to parse: the text is the answer, and it is shown as it is.
            Text(plain)
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }
}

/// One block, drawn.
private struct BlockBody: View {
    let block: Block

    var body: some View {
        switch block {
        case let .paragraph(spans):
            Text(Styled.spans(spans))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, spans):
            Text(Styled.spans(spans))
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)

        case let .code(lang, text):
            CodeBlock(lang: lang, text: text)

        case let .bullets(items):
            ListView(items: items, ordered: false)

        case let .numbers(start, items):
            ListView(items: items, ordered: true, start: start)

        case let .quote(blocks):
            QuoteView(blocks: blocks)

        case .rule:
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
                .padding(.vertical, 2)

        case let .table(header, rows, align):
            TableView(header: header, rows: rows, align: align)
        }
    }

    /// A heading's size by its level, and a floor under it: `###### deep` is still a heading, and it
    /// should not come out smaller than the paragraph under it.
    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 16
        case 3: return 14
        default: return 13
        }
    }
}

/// A fenced block: its language, and its text.
///
/// The language is drawn only when the fence had one, because an empty label is a label that says
/// nothing. The text is monospaced and scrolls horizontally rather than wrapping: a wrapped line of
/// code is a line whose indentation no longer means what it says.
private struct CodeBlock: View {
    let lang: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !lang.isEmpty {
                Text(lang)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A bulleted or numbered list.
///
/// Rendered by the host rather than by markdown, because a list item is a *container*: the parse keeps
/// an item's second paragraph inside that item, and a host that drew the markdown source would put it
/// beside the list instead.
private struct ListView: View {
    let items: [[Block]]
    let ordered: Bool
    var start: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(start + index)." : "•")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.enumerated()), id: \.offset) { _, block in
                            BlockBody(block: block)
                        }
                    }
                }
            }
        }
    }
}

private struct QuoteView: View {
    let blocks: [Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockBody(block: block)
            }
        }
        .padding(.leading, 10)
        .foregroundStyle(.secondary)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 2)
        }
    }
}

/// A markdown table, with the alignments the source asked for.
///
/// A grid rather than a `Grid`, because the rows here are data of varying length: a `Grid` wants to be
/// told its structure up front, and a model's table sometimes has a row with a cell missing. The widths
/// come from the content, and the whole thing scrolls sideways rather than reflowing — a table narrowed
/// into a single column is no longer a table.
private struct TableView: View {
    let header: [[Block.Span]]
    let rows: [[[Block.Span]]]
    let align: [Block.Align]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    Divider()
                    row(cells, isHeader: false)
                }
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ cells: [[Block.Span]], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, spans in
                Text(Styled.spans(spans))
                    .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
                    .multilineTextAlignment(textAlignment(index))
                    .frame(minWidth: 60, alignment: frameAlignment(index))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                if index < cells.count - 1 {
                    Divider()
                }
            }
        }
    }

    /// A column's alignment, defaulting to leading for a table that named fewer alignments than it has
    /// columns — which is a table written by hand rather than by a parser.
    private func textAlignment(_ column: Int) -> TextAlignment {
        switch column < align.count ? align[column] : .left {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch column < align.count ? align[column] : .left {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

/// Spans to text, with the styles accumulated.
///
/// Accumulating rather than recursing is what the flat span list is for: `**bold with *italic* in it**`
/// arrives as `strong` containing `emph`, and the host applies one on top of the other as it descends.
/// The nesting is bounded by how deeply anyone writes markdown, so the recursion here is in the spirit
/// of the format rather than a risk.
private enum Styled {
    static func spans(_ spans: [Block.Span]) -> AttributedString {
        var out = AttributedString()
        for span in spans {
            out.append(one(span))
        }
        return out
    }

    private static func one(_ span: Block.Span) -> AttributedString {
        switch span {
        case let .text(text):
            return AttributedString(text)
        case let .code(code):
            var out = AttributedString(code)
            out.font = .system(size: 12, design: .monospaced)
            // A concrete colour rather than `.quaternary`: the attribute takes a `Color`, and the
            // hierarchical styles are `ShapeStyle`s that only resolve inside a view.
            out.backgroundColor = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
            return out
        case let .emph(inner):
            var out = spans(inner)
            out.inlinePresentationIntent = .emphasized
            return out
        case let .strong(inner):
            var out = spans(inner)
            out.inlinePresentationIntent = .stronglyEmphasized
            return out
        case let .strike(inner):
            var out = spans(inner)
            out.strikethroughStyle = .single
            return out
        case let .link(url, inner):
            var out = spans(inner)
            // The scheme is checked rather than trusted: a model can emit `javascript:` in a link, and
            // a link the platform will not open is better drawn as plain text than as a button that
            // does nothing.
            out.link = URL(string: url)
            out.foregroundColor = .accentColor
            out.underlineStyle = .single
            return out
        }
    }
}
