import SwiftUI

import PiKit
import PiModel

/// The window: what the shell is, what it has said, and a box to answer it in.
struct RootView: View {
    @ObservedObject var client: PiClient
    @State private var draft = ""

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

/// One line above the conversation: which session, which model, and where its tools run.
///
/// Small and secondary on purpose. It is not a control — the MVP has nothing to change here — and
/// a row of grey text is the honest weight for three facts nobody acts on.
private struct Header: View {
    let state: ShellState
    let revision: Int

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
                Text("export DEEPSEEK_API_KEY").foregroundStyle(.secondary)
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
            .onChange(of: revision) { _ in
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
