import SwiftUI

import PiKit
import PiModel

/// The settings panel.
///
/// Three things, and the test for what belongs here is the one the web panel uses: **can a running
/// process honour it?** A key and a tool mode are read at the top of every turn, so saving either
/// means the next turn uses it rather than the next process. The store, the endpoint and the model
/// are decided at launch — the model belongs to a session, and is changed from the header — so there
/// is no control for them, only the file's path for a reader who would rather edit by hand.
///
/// Nothing here holds a copy of the settings to apply later. Each control asks the shell for a change
/// and the fields redraw from the answer, which is what keeps a save that failed from leaving the
/// window describing a state that never existed.
struct SettingsView: View {
    @ObservedObject var client: PiClient
    @State private var draftKey = ""

    var body: some View {
        Form {
            if let settings = client.settings {
                keySection(settings)
                toolsSection(settings)
                factsSection(settings)
            } else {
                // No guess at what is in force: the fields below all describe the shell's answer, and
                // one made up here would be a panel that disagrees with the next turn.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("asking the shell…").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        // Asked for on appear rather than only at startup: the settings file is hand-editable, and a
        // panel that reported whatever was true when the app launched would be wrong exactly when
        // someone had just been in the file.
        .onAppear { client.refreshSettings() }
    }

    private func keySection(_ settings: ShellSettings) -> some View {
        Section("API Key") {
            LabeledContent("In use") {
                Text(settings.keySummary)
                    .foregroundStyle(settings.key == "none" ? .orange : .primary)
            }
            if settings.savedKeyIsOverruled {
                Text("DEEPSEEK_API_KEY is set, so it wins over the saved key. Unset it to use the saved one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                SecureField("Paste a key to save it here", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button("Save", action: saveKey)
                    .disabled(draftKey.isEmpty)
            }
            if settings.saved {
                Button("Clear Saved Key", role: .destructive) {
                    client.clearSavedKey()
                }
            }
        }
    }

    private func toolsSection(_ settings: ShellSettings) -> some View {
        Section("Tools") {
            Picker("Turn gets", selection: modeBinding(settings)) {
                Text("Eight tools").tag("tools")
                Text("Code mode (exec, wait)").tag("code")
            }
            // Said rather than implied, because a mode change on a session that has already used the
            // other mode's tools is exactly the case that surprises people: the model can see calls
            // to tools this turn does not have.
            Text("A change applies to the next turn. Resuming a session that used the other mode's tools costs one extra instruction.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func factsSection(_ settings: ShellSettings) -> some View {
        Section("Not Changeable Here") {
            Text("The model belongs to a session and is shown above the conversation. The store and the endpoint are decided when the app launches.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Settings file") {
                Text(settings.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    /// The picker's value comes from the shell, and setting it asks for a change. So the selection
    /// snaps back on its own if the shell declines — nothing has to remember the old value.
    private func modeBinding(_ settings: ShellSettings) -> Binding<String> {
        Binding<String>(
            get: { settings.mode },
            set: { client.setMode($0) }
        )
    }

    private func saveKey() {
        guard !draftKey.isEmpty else { return }
        client.saveKey(draftKey)
        draftKey = ""
    }
}
