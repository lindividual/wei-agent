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
            Text(rendered(row))
                .font(.system(size: 13))
                .textSelection(.enabled)
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

    /// Markdown for a finished block, plain text for one that is still arriving.
    ///
    /// The rule is the cost: re-parsing the whole of a growing block on every delta is quadratic,
    /// and the web UI paid for that lesson with 40KB of reasoning arriving in 64-character frames.
    private func rendered(_ row: Row) -> AttributedString {
        guard row.complete else { return AttributedString(row.text) }
        return (try? AttributedString(markdown: row.text)) ?? AttributedString(row.text)
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
