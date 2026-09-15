import SwiftUI

import PiKit
import PiModel

/// The settings window: a list of sections on the left, one section's detail on the right.
///
/// That arrangement is Notes' — a `NavigationSplitView` inside the settings scene — and it is the
/// right one for the same reason it is right there: there are now five unrelated kinds of setting,
/// and a single scrolling form of five kinds is a page a reader has to hunt through. A list that
/// names them costs one click and makes every section's contents obvious before it is opened.
///
/// The test for what belongs in here is the one the web panel uses: **can a running process honour
/// it?** A key, a tool mode, a skill switch, the fallback instructions and the turn limits are all
/// read at the top of a turn, so saving one means the *next* turn uses it. The store, the endpoint
/// and the model are decided at launch — the model belongs to a session, and is changed from the
/// composer — so there is no control for them, only a path for a reader who would rather edit the
/// file by hand.
///
/// Nothing here holds a copy of the settings to apply later. Each control asks the shell for a change
/// and every field redraws from the answer, which is what keeps a save that failed from leaving the
/// window describing a state that never existed.
struct SettingsView: View {
    @ObservedObject var client: PiClient

    /// Which section is showing. A selection rather than a `TabView`, because this is a list of
    /// places: the sidebar names them and the detail is one of them, which is what the split view is
    /// for.
    @State private var pane: Pane? = .key

    /// What the five kinds are. Raw values are stable strings so that the selection can live in
    /// `@State` — and so that a pane can be deep-linked later without a second vocabulary.
    ///
    /// Named `Pane` rather than `Section`: `SwiftUI.Section` is the thing each of these *draws*,
    /// and a nested type with that name shadows it inside this file — every `Section("API Key")`
    /// then refers to the enum and stops being a view.
    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case key, tools, skills, instructions, limits

        var id: String { rawValue }

        var title: String {
            switch self {
            case .key: return "API Key"
            case .tools: return "Tools"
            case .skills: return "Skills"
            case .instructions: return "Instructions"
            case .limits: return "Turn Limits"
            }
        }

        var symbol: String {
            switch self {
            case .key: return "key"
            case .tools: return "wrench.and.screwdriver"
            case .skills: return "sparkles"
            case .instructions: return "text.document"
            case .limits: return "gauge.with.dots.needle.33percent"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Form {
                if let settings = client.settings {
                    detail(settings)
                } else {
                    waiting
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane?.title ?? "Settings")
        }
        .frame(width: 640, height: 460)
        // Asked for again on appear, even though the shell pushes the settings at startup: the file is
        // hand-editable, and a panel that reported whatever was true when the app launched would be
        // wrong exactly when someone had just been in the file. The push is what keeps the first
        // render from depending on this — which is what it did, and the panel sat here asking.
        .onAppear { client.refreshSettings() }
    }

    @ViewBuilder
    private func detail(_ settings: ShellSettings) -> some View {
        switch pane ?? .key {
        case .key: keySection(settings)
        case .tools: toolsSection(settings)
        case .skills: skillsSection(settings)
        case .instructions: instructionsSection(settings)
        case .limits: limitsSection(settings)
        }
    }

    // ── key ───────────────────────────────────────────────────────────────

    @State private var draftKey = ""

    @ViewBuilder
    private func keySection(_ settings: ShellSettings) -> some View {
        rebuild {
            Section("API Key") {
                LabeledContent("In use") {
                    Text(settings.keySummary)
                        .foregroundStyle(settings.key == "none" ? .orange : .primary)
                }
                if settings.savedKeyIsOverruled {
                    // The one combination worth a sentence of its own: the reader has no way to see it
                    // from the fields, and "I saved it and it still uses the old one" reads as a bug.
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
            fileSection(settings)
        }
    }

    /// A container for a pane's several `Section`s.
    ///
    /// Explicit rather than `Group`, whose builder is generic over table columns and cannot be
    /// inferred from a list of sections — the error it gives names `TableColumnBuilder`, which is not
    /// a helpful thing to read at 2am.
    @ViewBuilder
    private func rebuild<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
    }

    private func saveKey() {
        guard !draftKey.isEmpty else { return }
        client.saveKey(draftKey)
        draftKey = ""
    }

    // ── tools ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private func toolsSection(_ settings: ShellSettings) -> some View {
        rebuild {
            Section("Tools") {
                Picker("Turn gets", selection: modeBinding(settings)) {
                    Text("Eight tools").tag("tools")
                    Text("Code mode (exec, wait)").tag("code")
                }
                // Said rather than implied, because a mode change on a session that has already used
                // the other mode's tools is exactly the case that surprises people: the model can see
                // calls to tools this turn does not have.
                Text("A change applies to the next turn. Resuming a session that used the other mode's tools costs one extra instruction.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Not Changeable Here") {
                Text("The model belongs to a session and is chosen in the composer. The store and the endpoint are decided when the app launches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            fileSection(settings)
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

    // ── skills ────────────────────────────────────────────────────────────

    @ViewBuilder
    private func skillsSection(_ settings: ShellSettings) -> some View {
        rebuild {
            if settings.skills.isEmpty {
                Section("Skills") {
                    Text("No skills on this machine. A skill is a directory with a `SKILL.md` in `~/.pi/skills` or a workspace's `.pi/skills`.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Skills") {
                    ForEach(settings.skills) { skill in
                        Toggle(isOn: skillBinding(skill)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.name)
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                // Where the file is, for a name that has one, and said plainly when
                                // it does not: a skill switched off and then uninstalled is a row
                                // that exists only so its setting can be undone.
                                Text(skill.path.isEmpty ? "the file is gone — this name is only a setting" : skill.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(skill.path.isEmpty ? Color.orange : Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                Section {
                    Text("Switches apply to the next turn. A switched-off skill is not offered to the model and cannot be invoked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            fileSection(settings)
        }
    }

    /// A skill's switch asks the shell to toggle it, and reads back whatever the shell then says. The
    /// binding never holds the new value: a toggle that flipped locally and was then refused would be
    /// a switch describing a state that does not exist.
    private func skillBinding(_ skill: SkillEntry) -> Binding<Bool> {
        Binding<Bool>(
            get: { skill.enabled },
            set: { _ in client.toggleSkill(skill.name) }
        )
    }

    // ── instructions ──────────────────────────────────────────────────────

    @State private var draftInstructions = ""
    @State private var instructionsLoaded = false

    @ViewBuilder
    private func instructionsSection(_ settings: ShellSettings) -> some View {
        rebuild {
            Section("Instructions") {
                Text(sourceSentence(settings))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draftInstructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                HStack(spacing: 8) {
                    Button("Save") { client.saveInstructions(draftInstructions) }
                    Button("Clear", role: .destructive) {
                        draftInstructions = ""
                        client.saveInstructions("")
                    }
                    .disabled(draftInstructions.isEmpty)
                    Spacer()
                    Text("Used where there is no AGENTS.md.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            fileSection(settings)
        }
        // Loaded from the shell once, and then left alone: the field is a draft, and re-syncing it on
        // every settings event would delete what the reader is halfway through typing the moment any
        // other setting changed — a skills toggle, say, from a different section.
        .onAppear {
            if !instructionsLoaded {
                draftInstructions = settings.instructions
                instructionsLoaded = true
            }
        }
        .onChange(of: settings.instructions) { _, value in
            // The one case where the shell's answer does replace the draft: the text in force is now
            // what the reader just saved, so the two agree and there is nothing to lose.
            if value == draftInstructions || !instructionsLoaded { return }
            if draftInstructions.isEmpty || value.hasPrefix(String(draftInstructions.prefix(40))) {
                draftInstructions = value
            }
        }
    }

    /// Where the instructions in force came from, said as a sentence.
    ///
    /// The case worth explaining is `file`: a reader who saved instructions here and sees a
    /// repository's text in the box has to be told which one won, or they will save again and watch
    /// nothing change.
    private func sourceSentence(_ settings: ShellSettings) -> String {
        switch settings.instructionsSource {
        case "file": return "In force: this workspace's AGENTS.md. What you save here is used in workspaces that have none."
        case "saved": return "In force: the text below."
        default: return "Nothing in force: no AGENTS.md here and nothing saved."
        }
    }

    // ── limits ────────────────────────────────────────────────────────────

    @State private var draftRounds = ""
    @State private var draftCost = ""
    @State private var draftSeconds = ""
    @State private var limitsLoaded = false

    @ViewBuilder
    private func limitsSection(_ settings: ShellSettings) -> some View {
        rebuild {
            Section("Turn Limits") {
                limitRow(
                    "Model calls per turn",
                    help: "0 switches the bound off.",
                    value: $draftRounds,
                    limit: settings.limits.rounds,
                    prompt: defaultRounds
                )
                limitRow(
                    "Cost per turn (USD)",
                    help: "0 switches the bound off.",
                    value: $draftCost,
                    limit: settings.limits.cost,
                    prompt: defaultCost
                )
                limitRow(
                    "Time per turn (seconds)",
                    help: "0 switches the bound off.",
                    value: $draftSeconds,
                    limit: settings.limits.seconds,
                    prompt: defaultSeconds
                )
                HStack(spacing: 8) {
                    Button("Apply") {
                        client.saveLimits(
                            rounds: draftRounds,
                            cost: draftCost,
                            seconds: draftSeconds
                        )
                    }
                    Button("Reset to Defaults") {
                        draftRounds = ""
                        draftCost = ""
                        draftSeconds = ""
                        client.saveLimits(rounds: "", cost: "", seconds: "")
                    }
                    Spacer()
                }
            }
            Section {
                Text("An empty field means no opinion, and the built-in default comes back. A limit set by a command-line flag is shown but cannot be edited here: the process would ignore the new value, and a field that appears to accept one is worse than no field.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            fileSection(settings)
        }
        .onAppear {
            if !limitsLoaded {
                draftRounds = settings.limits.rounds.isFromFlag ? "" : settings.limits.rounds.value
                draftCost = settings.limits.cost.isFromFlag ? "" : settings.limits.cost.value
                draftSeconds = settings.limits.seconds.isFromFlag ? "" : settings.limits.seconds.value
                limitsLoaded = true
            }
        }
    }

    /// One limit: its name, where the value in force came from, and the field.
    private func limitRow(
        _ title: String,
        help: String,
        value: Binding<String>,
        limit: Limit,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                TextField(prompt, text: value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .disabled(limit.isFromFlag)
            }
            HStack(spacing: 6) {
                Text(sourceLabel(limit))
                    .font(.caption)
                    .foregroundStyle(limit.isFromFlag ? .orange : .secondary)
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// What a limit's value is, and who decided it. The value is repeated here rather than only in
    /// the field, because a field showing a *draft* and a line showing what is *in force* answer two
    /// different questions — and after a save they are the same number, which is what makes the line
    /// worth reading.
    private func sourceLabel(_ limit: Limit) -> String {
        if limit.isFromFlag { return "in force: \(limit.value) (from a flag)" }
        if limit.isOff { return "off" }
        switch limit.source {
        case "saved": return "in force: \(limit.value) (saved)"
        default: return "in force: \(limit.value) (default)"
        }
    }

    private var defaultRounds: String { "200" }
    private var defaultCost: String { "1" }
    private var defaultSeconds: String { "1800" }

    // ── shared ────────────────────────────────────────────────────────────

    private func fileSection(_ settings: ShellSettings) -> some View {
        Section {
            LabeledContent("Settings file") {
                Text(settings.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help("Everything this panel writes, in the same file — hand-editable if you would rather.")
        }
    }

    /// What to show when there is nothing to show yet.
    ///
    /// Not an eternal spinner: the shell says what it is doing, and this says the same thing in the
    /// same words, with a way to ask again. A dead end is worse than a delay.
    @ViewBuilder
    private var waiting: some View {
        switch client.state {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("starting the shell…").foregroundStyle(.secondary)
            }
        case let .failed(reason):
            Text(reason).foregroundStyle(.red)
            retry
        default:
            Text("The shell has not said what is in force.").foregroundStyle(.secondary)
            retry
        }
    }

    private var retry: some View {
        Button("Ask Again") { client.refreshSettings() }
    }
}
