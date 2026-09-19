import SwiftUI

import WeiKit
import WeiModel

/// The settings window: **the platform's own preference tabs**, one pane each.
///
/// That is the answer to "is there a standard component": `TabView` inside a `Settings` scene, which macOS
/// draws as the preference toolbar — one toolbar button per pane, the window titled by the one selected
/// (verified by reading this process's own accessibility tree: `AXToolbar` with one `AXButton` per tab).
/// Terminal draws its settings this way, and so does Notes — which is the reference this whole window is
/// aligned to, so the settings panel should not be the one place that disagrees with it.
///
/// It was a `NavigationSplitView`: a list of five panes on the left, one pane's form on the right, 640 × 460.
/// Nothing was wrong with it — System Settings is a list too — but a list needs a column, and a column for
/// five rows costs a fifth of the window *and* one click before the pane's own contents are on screen. Five
/// panes of a few controls each fit across a titlebar; the reader sees what is here at a glance and reaches
/// any of it in one click.
///
/// The test for what belongs in here is the one the web panel uses: **can a running process honour
/// it?** A key, a tool mode, a skill switch, the fallback instructions and the turn limits are all
/// read at the top of a turn, so saving one means the *next* turn uses it. The store, the endpoint
/// and the model are decided at launch — the model belongs to a session, and is changed from the
/// composer — so there are no controls for them, only a path for a reader who would rather edit the
/// file by hand.
///
/// Nothing here holds a copy of the settings to apply later. Each control asks the shell for a change
/// and every field redraws from the answer, which is what keeps a save that failed from leaving the
/// window describing a state that never existed.
struct SettingsView: View {
    @ObservedObject var client: ShellClient

    /// Which pane is showing.
    @State private var pane: Pane? = .key

    /// What the five kinds are. Raw values are stable strings so that the selection can live in
    /// `@State` — and so that a pane can be deep-linked later without a second vocabulary.
    ///
    /// Named `Pane` rather than `Section`: `SwiftUI.Section` is the thing each of these *draws*,
    /// and a nested type with that name shadows it inside this file — every `Section("API Key")`
    /// then refers to the enum and stops being a view.
    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case key, tools, skills, instructions, limits

        /// The same five panes as `SettingsPane`, which is the vocabulary the *window* uses when it
        /// sends a reader here ("no API key — Open Settings"). One mapping, in one place, so that a
        /// pane added or renamed on this side is a compile error there rather than a string that
        /// quietly stops matching.
        init(_ pane: SettingsPane) {
            switch pane {
            case .key: self = .key
            case .tools: self = .tools
            case .skills: self = .skills
            case .instructions: self = .instructions
            case .limits: self = .limits
            }
        }

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
        VStack(spacing: 0) {
            TabView(selection: $pane) {
                // Keyed by the item rather than read back from `pane`: while the tab bar is animating there
                // is a moment when the selection is neither, and a pane that switched on that value would
                // draw the wrong form under the right label.
                ForEach(Pane.allCases) { item in
                    Form {
                        if let settings = client.settings {
                            detail(item, settings)
                        } else {
                            waiting
                        }
                    }
                    .formStyle(.grouped)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
                }
            }
            settingsFile
        }
        .frame(width: 520, height: 360)
        // Asked for again on appear, even though the shell pushes the settings at startup: the file is
        // hand-editable, and a panel that reported whatever was true when the app launched would be
        // wrong exactly when someone had just been in the file. The push is what keeps the first
        // render from depending on this — which is what it did, and the panel sat here asking.
        .onAppear {
            client.refreshSettings()
            openWhereAsked()
        }
        // **And again on every request**, which is the half `.onAppear` cannot cover: this window
        // outlives being closed (`Settings` is a scene, and macOS keeps it), so a reader who left it
        // on Turn Limits and then pressed "Open Settings" under the composer would be shown the pane
        // about turn limits. `.onChange` rather than a binding to the client's own value: the request
        // is an event, and reading it as state would re-open the pane every time anything else
        // redrew.
        .onChange(of: client.settingsAsk) { _, _ in openWhereAsked() }
    }

    /// Move to the pane the reader was sent to, if any.
    ///
    /// On the first launch nothing has asked for anything — `settingsAsk` is 0 — and the default
    /// below is `.key`, which is the pane a reader with no key needs. So the untold case and the
    /// asked-for-key case agree, and only a *later* request (from the wall under the composer, after
    /// the panel has been somewhere else) has to move anything.
    private func openWhereAsked() {
        guard client.settingsAsk > 0 else { return }
        let wanted = Pane(client.settingsPane)
        if pane != wanted { pane = wanted }
    }

    @ViewBuilder
    private func detail(_ pane: Pane, _ settings: ShellSettings) -> some View {
        switch pane {
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
        }
    }

    /// Where the file is, once, for the whole window.
    ///
    /// It used to be a section at the bottom of *every* pane — five copies of one path, each taking a group's
    /// worth of height to say a fact that belongs to the window rather than to the pane. One line at the foot
    /// of the window says it wherever the reader is, which is also where a reader who has just changed
    /// something looks to find out what was written.
    private var settingsFile: some View {
        HStack(spacing: Wei.Space.cozy) {
            Text("Settings file")
                .foregroundStyle(Wei.Palette.tertiary)
            Text(client.settings?.path ?? "—")
                .foregroundStyle(Wei.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Wei.Font.code(Wei.Size.micro))
        .padding(.horizontal, Wei.Space.loose)
        .padding(.vertical, Wei.Space.cozy)
        .help("Everything this panel writes, in the same file — hand-editable if you would rather.")
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
            // The sentence about the *mode change* is the section's footer rather than a paragraph of its own:
            // it qualifies the picker above it, and a heading over one sentence is a heading the reader has to
            // read to learn there is nothing under it. (`formStyle(.grouped)` draws a footer as small secondary
            // text under its group — the platform's own way of saying this.)
            Section {
                Picker("Turn gets", selection: modeBinding(settings)) {
                    Text("Eight tools").tag("tools")
                    Text("Code mode (exec, wait)").tag("code")
                }
            } footer: {
                Text("Applies to the next turn. Resuming a session that used the other mode's tools costs one extra instruction.")
            }
            // Kept, in the pane a reader would look in for it: "where do I change the model" has an answer, and
            // hunting for a control that is deliberately in another window is the cost of not giving one.
            Section("Not Changeable Here") {
                Text("The model belongs to a session and is chosen in the composer. The store and the endpoint are decided when the app launches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    // ── skills ────────────────────────────────────────────────────────────

    @ViewBuilder
    private func skillsSection(_ settings: ShellSettings) -> some View {
        rebuild {
            if settings.skills.isEmpty {
                Section("Skills") {
                    Text("No skills on this machine. A skill is a directory with a `SKILL.md` in `~/.wei/skills` or a workspace's `.wei/skills`.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
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
                } footer: {
                    Text("Switches apply to the next turn. A switched-off skill is not offered to the model and cannot be invoked.")
                }
            }
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
            Section {
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
                }
            } header: {
                Text("Instructions")
            } footer: {
                Text("Used where there is no AGENTS.md.")
            }
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
            Section {
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
            } footer: {
                Text("An empty field means no opinion, and the built-in default comes back. A limit set by a command-line flag is shown but cannot be edited here: the process would ignore the new value, and a field that appears to accept one is worse than no field.")
            }
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

    /// What to show when there is nothing to show yet.
    ///
    /// Not an eternal spinner: the shell says what it is doing, and this says the same thing in the
    /// same words, with a way to ask again. A dead end is worse than a delay.
    ///
    /// **Its own `Section`, because all five panes are built at once in a `TabView`** — a failed shell would
    /// otherwise draw those three lines five times down one pane and hide the form's own rows behind them.
    @ViewBuilder
    private var waiting: some View {
        Section {
            switch client.state {
            case .starting:
                HStack(spacing: Wei.Space.cozy) {
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
    }

    private var retry: some View {
        Button("Ask Again") { client.refreshSettings() }
    }
}
