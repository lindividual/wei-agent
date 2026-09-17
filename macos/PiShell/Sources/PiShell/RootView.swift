import SwiftUI

import PiKit
import PiModel

/// The primary window: three columns — the projects, the sessions in one of them, and the conversation.
///
/// A `NavigationSplitView` rather than an `HSplitView`, because these columns are columns: the first
/// collapses, comes back on a keystroke, and the toolbar knows where it is. Every one of those is a
/// behaviour the platform owns, and hand-rolling the split would mean writing them all again.
///
/// **Three columns because there are three things.** A session has a project, a name and a conversation,
/// and the two-column version had to fold the first two into one list: the sidebar was workspaces *with*
/// their sessions nested under them, which reads fine at eleven sessions and badly at a hundred — the
/// reader scrolls past one project to reach another, and every project's headings push the next one down.
/// Separating them also gives the session list a place to be *about* one project, which is what makes
/// heading it by time possible.
///
/// The shape is Notes': a source column, a list column, a content column, each with its own job. The
/// advice is worth following because it is what a Mac reader already knows — and the parts of Notes that
/// do not apply here (a formatting toolbar, a scrapbook of attachments) are not copied. See
/// `macos/README.md` for what was taken and what was left.
struct RootView: View {
    @ObservedObject var client: PiClient
    @ObservedObject var actions: WindowActions
    /// Which project's sessions the middle column is listing.
    ///
    /// A window fact, not a shell fact, and the distinction is the reason this is `@State` rather than
    /// something the shell sends: **browsing is not opening.** Clicking a project shows its sessions; it
    /// does not switch the conversation, which would change where an agent's tools run and could cut
    /// across a turn that is still running. The shell's answer to "which session is open" is
    /// `client.currentPath`, and the two are allowed to disagree — that is what browsing another project
    /// *is*.
    @State private var browsing = ""

    /// What the search field holds. On the window rather than on the list, because the window's title uses
    /// it: in a three-column split the middle column owns the titlebar, and a title that read "Search" while
    /// the field was empty — or a count that disagreed with the list — is the kind of drift that comes from
    /// two places computing one fact.
    @State private var search = ""

    /// The project whose sessions are listed: the reader's choice when they have made one, and otherwise
    /// the project of the session that is open.
    private var browsed: String {
        client.groups.contains(where: { $0.cwd == browsing }) ? browsing : client.currentWorkspace
    }

    /// The window's two lines, from the same sections the list is drawn from: the project being browsed and how
    /// many sessions it has — or, while searching, what the search found, because then that is what the list is
    /// about and a result from another project has to say so.
    private var sessionListTitle: String {
        if searching { return "Search" }
        return client.groups.first(where: { $0.cwd == browsed })?.label
            ?? client.groups.first?.label
            ?? "Sessions"
    }

    private var sessionListSubtitle: String {
        let rows = sections.reduce(0) { $0 + $1.rows.count }
        if searching {
            return rows == 1 ? "1 result" : "\(rows) results"
        }
        return rows == 1 ? "1 session" : "\(rows) sessions"
    }

    /// The list's contents, computed once for the two places that need them: the list, and the title's count.
    private var sections: [SessionSection] {
        sessionSections(
            groups: client.groups,
            browsing: browsed,
            query: search,
            now: Date(),
            calendar: .current
        )
    }

    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            WorkspaceList(
                client: client,
                browsing: $browsing,
                search: $search,
                actions: actions
            )
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 300)
                // The column keeps its own title, and the detail column gives its title to the toolbar
                // instead — see `ConversationView`. Three columns means two headings that are not the
                // window's: this one, and the middle column's own.
                .navigationTitle("Projects")
        } content: {
            SessionList(
                client: client,
                browsing: browsed,
                sections: sections,
                searching: searching,
                onBrowse: { browsing = $0 }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 460)
            // **This column owns the window's title, and the detail column does not.** That is not a
            // preference, it is what a three-column `NavigationSplitView` does: with three columns the
            // *content* column elects the title and any `navigationTitle` on the detail is ignored. Found
            // by asking the window what it thought it was called (`NSWindow.title`, from inside, because
            // no permission is needed for that) — it said `pi`, the scene's own name, because the title it
            // was actually given computed to empty. The reader saw a titlebar reading "pi" forever.
            //
            // Which is the arrangement Notes has anyway: the titlebar above the list column says the
            // *folder* and how many notes are in it, not the note being read — the note names itself with
            // its first line, and a session names itself with its first question, which is the first row of
            // the transcript.
            // The window's title names **the list in this column**: which project, and how many sessions.
            //
            // It is not the conversation's name, and that was a mistake worth writing down: with a title in the
            // transcript as well, the session's name appeared twice on one screen — the titlebar had been given
            // it while the transcript still had its own heading. A window has one title; the thing this column
            // is a list *of* is what belongs in it.
            //
            // Mechanically this has to be the *content* column's title: in a three-column split that column
            // elects the window's title and the detail column's is ignored. Verified by asking the window what
            // it was called (`NSWindow.title`, read from inside the process — no permission needed).
            .navigationTitle(sessionListTitle)
            .navigationSubtitle(sessionListSubtitle)
        } detail: {
            ConversationView(client: client)
                .frame(minWidth: 420, minHeight: 320)
        }
        // The brand accent, applied where the platform applies it: with `.tint`, the system draws its own
        // selection, focus rings and default buttons in this colour. Setting it here rather than painting a
        // background per control is what keeps every control agreeing without being told separately — and it
        // is why the reader's own accent colour does not show through in this app.
        .tint(Wei.Palette.accent)
        // **The toolbar is transparent, so what shows through it is the page.** With a toolbar background
        // of its own, the top of the window is a strip that spans all three columns — and a strip that
        // spans them is what makes them read as one region. Measured against Notes: its toolbar differs
        // from its page by one step of grey (254 against 255); ours differed by fourteen, which is a band
        // however lightly it is drawn. `.windowToolbar` is the placement that means the window's own
        // toolbar rather than a column's.
        //
        // `toolbarBackgroundVisibility` is the current spelling of this (`toolbarBackground` is the older
        // one, deprecated at some unreleased version). It needed macOS 15 and the target was 14, which is
        // why this file used the old name; the target is 26 now, so it uses the new one.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Following the conversation: when the shell moves to another session — a click, `⌃⇥`, a new one,
        // a deleted one — the list has to be showing it, or the reader is looking at the wrong project
        // with the highlight nowhere. Deliberately keyed on the *path*, so browsing another project while
        // the same conversation stays open is not undone a moment later.
        .onChange(of: client.currentPath) { _, _ in browsing = client.currentWorkspace }
        .onAppear { browsing = client.currentWorkspace }
        // Choosing a directory to start a session in. `.folder` rather than an `NSOpenPanel`: this is the
        // same `fileImporter` the composer uses for images, it attaches to the window as a sheet, and the
        // host is the process that has a desktop session — the whole of `platform/picker.mbt`'s argument,
        // applied one layer out.
        .fileImporter(
            isPresented: $actions.choosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            // A cancelled chooser says nothing: the reader who changed their mind has already been
            // answered. An unreadable answer is not a thing to explain either — the shell checks the path
            // it is given, and it is the side that can say why.
            guard case let .success(urls) = result, let url = urls.first else { return }
            client.newSession(in: url.path)
        }
    }
}

/// The projects, and nothing else.
///
/// One row per working directory: a folder, the name, how many conversations are in it. **No sessions
/// here** — that is the whole of the change from two columns to three. A project is a place; its sessions
/// are what happened in that place, and they belong in a column that can be about one place at a time.
///
/// The list is not filterable and has no disclosure: with the sessions moved out, this column is short
/// enough to read, and a chevron that folds a row with nothing under it is a control that does nothing.
private struct WorkspaceList: View {
    @ObservedObject var client: PiClient
    @Binding var browsing: String
    /// The search field's text. Owned by the window (see `RootView`), because the window's title reads it.
    @Binding var search: String
    /// Adding a workspace opens the window's folder chooser, which is this object rather than this view —
    /// the File menu opens the same one.
    @ObservedObject var actions: WindowActions
    @Environment(\.openSettings) private var openSettings

    /// Sessions with a turn in flight, from the shell's per-row flag.
    ///
    /// Flat across workspaces on purpose: the question this section answers is "is anything running", and
    /// making the reader scan four projects to answer it is what the section is for. The row says which
    /// project it belongs to instead.
    private var running: [SessionRow] {
        client.groups.flatMap(\.sessions).filter(\.running)
    }

    var body: some View {
        VStack(spacing: 0) {
            wordmark
            List(selection: $browsing) {
                // **Two sections that are usually empty, and absent when they are.** Nothing running means
                // no heading rather than an empty one: a section that says "Running sessions" over an empty
                // space teaches the reader to skip the place where they will one day need to look. The web
                // UI's rule is the same, and for the same reason.
                if !running.isEmpty {
                    SectionTitle("Running sessions")
                    ForEach(running) { row in
                        // A button rather than a tagged row: this list's *selection* is which workspace it
                        // is listing, and a session picked from here opens a conversation instead — one List
                        // cannot be selecting two different kinds of thing.
                        Button {
                            client.open(row.path)
                        } label: {
                            RunningSessionRow(row: row, workspace: label(for: row))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !client.jobs.isEmpty {
                    SectionTitle("Running tool calls")
                    ForEach(client.jobs) { job in
                        JobRow(job: job, onKill: { client.killJob(job.id) })
                    }
                }
                SectionTitle("Workspaces")
                ForEach(client.groups) { group in
                    WorkspaceRow(group: group)
                        .tag(group.cwd)
                }
                // Adding one is a workspace action, so it belongs in this list rather than in the File menu
                // alone — the menu item stays, because a Mac reader looks for "New …" in File.
                Button {
                    actions.choosingFolder = true
                } label: {
                    Label("Add Workspace…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Wei.Palette.accent)
            }
            .listStyle(.sidebar)
            // The list's content is inset under the search field the platform places in this column, so its
            // first row lays out *above* the list's own top edge and is clipped: measured, the "Running tool
            // calls" title came out at ay 154 with the list's frame starting at 169. A top content margin is
            // what keeps the first row out of that band. (Found by dumping the accessibility tree, which is
            // the only way this shows up — the row is in the tree, with a real size, and simply not drawn.)
            .contentMargins(.top, Wei.Space.loose, for: .scrollContent)
            Divider()
            settings
        }
        // **The platform's own search, placed in the sidebar.** It was a hand-rolled capsule inside this
        // column's content, and that is the version this file argued for at length — the reasoning was
        // sound for a deployment target of macOS 14 and is wrong now on two counts.
        //
        // First, the scope: the query spans *every* project, and a field drawn inside the sessions column
        // read as "filter the list I am looking at". Put at the top of the workspace column it says what it
        // does — the search covers all of them — and `.sidebar` is the placement that means exactly this.
        //
        // Second, and what settled it: our capsule was `.glassEffect` on the app's own surface, and glass
        // over the sidebar's vibrant material renders *dark* (measured: fill 124–138 against the sidebar's
        // 220–247) — a black pill in a light sidebar. `.searchable` is the system's search field, so it
        // renders the way the platform renders one over a sidebar, in every appearance, without us keeping
        // a second implementation of a control the system already has.
        .searchable(text: $search, placement: .sidebar, prompt: "Search all sessions")
        // The register was refreshed when the popover opened; now that the rows are always on screen it is
        // refreshed when the column appears, and on every revision the shell sends (see `PiClient.jobs`).
        .onAppear { client.refreshJobs() }
    }

    /// Which project a running session belongs to, for the row that has room for one word of it.
    private func label(for row: SessionRow) -> String {
        client.groups.first(where: { $0.sessions.contains(where: { $0.path == row.path }) })?.label ?? ""
    }

    /// Settings, as the last list item rather than a button in the toolbar.
    ///
    /// It is the app's own control, not this column's and not that one's — and a control that belongs to no
    /// column is what the bottom of the first column is for. The web UI pins its equivalent to the bottom of
    /// the sidebar for exactly this reason, and a Mac reader looking for preferences looks in the app menu
    /// first anyway (`⌘,` is still wired).
    private var settings: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: Wei.Space.cozy) {
                Image(systemName: "gearshape")
                    .font(Wei.Font.control())
                    .frame(width: Wei.Icon.control, alignment: .center)
                Text("Settings")
                Spacer(minLength: 0)
            }
            .foregroundStyle(Wei.Palette.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Settings (⌘,)")
        .padding(.horizontal, Wei.Space.cozy)
        .padding(.vertical, Wei.Space.tight)
    }

    /// The mark and the app's name, at the top of the first column.
    ///
    /// It earns the space for a reason beyond decoration: **since the window's title became the project and
    /// its session count, the app's own name appears nowhere else in the interface.** The About box and the
    /// Dock, and neither is something a reader looks at. This is where a Mac app puts it.
    ///
    /// Drawn rather than imported, from `Wei.Mark` — the same geometry the icon is drawn from, so the two
    /// cannot drift, and recoloured by the palette like everything else.
    private var wordmark: some View {
        HStack(spacing: Wei.Space.cozy) {
            Wei.MarkView(height: 18)
            Text("wei Agent")
                .font(Wei.Font.control(.medium))
                .foregroundStyle(Wei.Palette.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Wei.Space.loose)
        .padding(.top, Wei.Space.regular)
        .padding(.bottom, Wei.Space.cozy)
        // **No hairline under it.** There was one — "so it reads as the app's own strip rather than as
        // the first row of the list" — and a strip is exactly what it made: a divider across the top of
        // the first column is the same tell as the band that used to sit over the third one, and it was
        // the last one left. On its own the wordmark reads the way Notes' "Mac" reads at the head of its
        // folder list: a heading, not a region. Same reason the toolbar lost its background.
    }
}

/// One project: a folder, its name, how many sessions, and whether the open conversation is inside it.
///
/// The dot is kept from the two-column version and means more here than it did: the middle column shows
/// whichever project the reader is *browsing*, which is not necessarily the one holding the open
/// conversation — so without a mark, browsing away from a running session hides where it is.
/// A section's title, as its own row.
///
/// **A row rather than a `Section` header, and that is a workaround with a measurement behind it.** With
/// `Section("Running tool calls") { … }`, the header of the *first* section in this list does not lay out at
/// all whenever that section is inside an `if` — the accessibility tree has it at zero size and above the
/// list's own top edge (measured: `AXHeading [0,956 0x0]`), so the title is simply invisible while its rows
/// are on screen. Removing the `if` made the same header lay out at `[22,171 97x14]`, which is how it was
/// identified. The sections here must be absent when they are empty — a heading over nothing is a heading
/// that teaches the reader to skip the place they will one day need — so the titles are drawn instead.
///
/// Styled to match what the platform's own sidebar header looked like in the one place it did render.
private struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Wei.Font.caption(.semibold))
            .foregroundStyle(Wei.Palette.secondary)
            .padding(.top, Wei.Space.cozy)
            .padding(.bottom, Wei.Space.tiny)
    }
}

/// One session with a turn in flight.
///
/// Two lines because there are two facts: which conversation, and which project it is in — the second is
/// what makes one flat list of every workspace readable. The spinner is the platform's rather than a drawn
/// dot, so it moves on its own without a timer here.
private struct RunningSessionRow: View {
    let row: SessionRow
    let workspace: String

    var body: some View {
        VStack(alignment: .leading, spacing: Wei.Space.tiny) {
            Text(row.label)
                .font(Wei.Font.control())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: Wei.Space.tight) {
                ProgressView()
                    .controlSize(.mini)
                Text(workspace)
                    .font(Wei.Font.caption())
                    .foregroundStyle(Wei.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(row.path)
    }
}

private struct WorkspaceRow: View {
    let group: SessionGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(Wei.Font.control())
                .foregroundStyle(Wei.Palette.secondary)
            Text(group.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if group.current {
                Image(systemName: "circle.fill")
                    .font(.system(size: Wei.Icon.mark))
                    .foregroundStyle(Wei.Palette.accent)
            }
            Text("\(group.sessions.count)")
                .monospacedDigit()
                .foregroundStyle(Wei.Palette.tertiary)
        }
        // The path, because two projects can share a name and the name is all there is room for.
        .help(group.cwd)
    }
}

/// The sessions of one project.
///
/// Headed by *when* rather than by project — the project is already chosen, and it is the first column's
/// job to say which one. What a reader needs from this list is "the one from this afternoon" or "the one
/// from June", which is what the headings give them; see `timeSections`.
///
/// **This column lists the results; the field that produces them is in the workspace column.** They were in
/// one place, on the argument that a field belongs in the list it filters — which holds for a filter and
/// fails for a search. This one reaches every project, so in this column it read as "filter the project I am
/// looking at", and a result headed by some *other* project arrived as a surprise.
///
/// Deliberately not a search of the *transcripts*: that would mean reading every file, which is the cost the
/// shell avoids everywhere else, and a list that pauses to read the disk is a list that stops responding.
private struct SessionList: View {
    @ObservedObject var client: PiClient
    /// The project being browsed.
    let browsing: String
    /// What to draw, from the rules in `PiModel` — computed one level up, where the titlebar can see the
    /// count too.
    let sections: [SessionSection]
    /// Whether what is drawn is a *result set* rather than this project's sessions. A fact about the query,
    /// and the query belongs to the window now (the field is in the workspace column), so this column is
    /// told it rather than deriving it from a binding it no longer holds.
    let searching: Bool
    /// Called when a search result is clicked, so the first column can follow the reader into the project
    /// they just reached into — otherwise the two columns would disagree about where they are.
    let onBrowse: (String) -> Void
    /// The session deleted most recently, so the list can offer it back. The file was renamed rather than
    /// removed, so this is a convenience on top of a recovery that was already possible.
    @State private var deleted: (path: String, label: String)?
    @State private var undoTimer: Task<Void, Never>?
    @State private var renaming: SessionRow?
    @State private var newName = ""

    /// How long the offer to undo a delete stands. The same window the web UI uses, and for the same
    /// reason: an offer that stays until it is used is a row that never leaves.
    private static let undoWindow: Duration = .seconds(12)

    private var groups: [SessionGroup] {
        client.groups
    }

    /// The selection is the shell's current session, not a copy of it. Clicking asks the shell to switch,
    /// and the row highlights when the shell says it has.
    private var selection: Binding<String?> {
        Binding(
            get: { client.currentPath.isEmpty ? nil : client.currentPath },
            set: { path in
                guard let path else { return }
                // Reach into another project and the first column follows: the two are one browsing
                // position, and letting them drift would leave the middle column listing a project the
                // first column says the reader is not in.
                if let group = groups.first(where: { group in
                    group.sessions.contains { $0.path == path }
                }) {
                    onBrowse(group.cwd)
                }
                client.open(path)
            }
        )
    }

    var body: some View {
        // No field here any more: the query spans every project, so its control lives in the workspace
        // column. What is left in this one is the list that query produces.
        list
        // **The column's own action, in the column's own toolbar region.** Every control in this app
        // appears over the column it acts on — Notes' arrangement, and the reason its three columns are
        // legible from the titlebar alone. This button was in the detail column's toolbar, which put the
        // one control that adds a row to *this* list over the transcript instead: the top of the window
        // then read as two regions (a sidebar, and an everything-else that happened to be split), which
        // is exactly what a reader of this window reported seeing.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    client.newSession()
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("New session in this project (⌘N)")
            }
        }
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(sections) { section in
                SwiftUI.Section {
                    ForEach(section.rows) { row in
                        SessionRowView(
                            row: row,
                            onRename: { startRenaming(row) },
                            onDelete: { delete(row) }
                        )
                        .tag(row.path)
                    }
                } header: {
                    // These are *time* headings — Today, Previous 30 Days — and they carry the same job
                    // Notes' month headings do: they are how a reader finds a session by when it was
                    // rather than by what it was called. Notes sets its own at the control size and
                    // semibold; the list style's default here is a caption, which measured 10 points of
                    // ink against Notes' 13.5 and read as a caption rather than as a heading.
                    Text(section.title)
                        .font(Wei.Font.control(.semibold))
                }
            }
            if let deleted {
                SwiftUI.Section {
                    UndoRow(label: deleted.label) {
                        client.restore(deleted.path)
                        self.deleted = nil
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            // Nothing to show says why: an empty list with no message is indistinguishable from a list
            // that has not loaded.
            if sections.isEmpty {
                Text(emptyMessage)
                    .font(Wei.Font.control())
                    .foregroundStyle(Wei.Palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .alert("Rename Session", isPresented: renameBinding) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { client.rename(renaming.path, to: newName) }
                renaming = nil
            }
        } message: {
            Text("The name is written into the session's own file, so it travels with it.")
        }
    }

    private var emptyMessage: String {
        if searching {
            return "No sessions match."
        }
        // Said without pointing at a control: the button that starts one is in this column's own
        // toolbar, and the sentence that used to be here ("Type below to start one") pointed at a
        // composer that lives in the next column over.
        return groups.contains(where: { $0.cwd == browsing })
            ? "No sessions in this project."
            : "No project selected."
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private func startRenaming(_ row: SessionRow) {
        newName = row.label
        renaming = row
    }

    private func delete(_ row: SessionRow) {
        client.delete(row.path)
        deleted = (row.path, row.label)
        // The offer withdraws itself. A button that waits forever is a button that is still there
        // tomorrow, and by then it is not an undo any more — it is a piece of the interface nobody can
        // account for.
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(for: Self.undoWindow)
            if !Task.isCancelled { deleted = nil }
        }
    }
}

/// A small capsule saying something about a row that is not its name: running, for now.
///
/// On the *highlight* fill rather than the accent, which is the whole of the two-hue system in one control:
/// the chip is a background, so it takes the hue that works as a background in this appearance, and its text
/// takes the hue that is readable — which in light mode means purple on amber and in dark mode amber on
/// purple. Neither hue is "the" brand colour; each is the one that works here.
///
/// Text and dot rather than a spinner — a spinner in a 300-point column draws the eye to whatever is moving,
/// and with more than one session able to run at once that is the wrong thing to be looking at most of the
/// time.
private struct StatusChip: View {
    let text: String

    var body: some View {
        HStack(spacing: Wei.Space.tight) {
            Circle()
                .fill(Wei.Palette.onHighlight)
                .frame(width: Wei.Icon.mark, height: Wei.Icon.mark)
            Text(text)
        }
        .padding(.horizontal, Wei.Space.tight)
        .padding(.vertical, Wei.Space.tiny)
        .background(Wei.Palette.highlightWash, in: Capsule())
        .foregroundStyle(Wei.Palette.onHighlight)
    }
}

/// The line that says what was deleted, with the way back.
///
/// The web UI shows the same thing, over the same window, and it earns its place the same way: the file is
/// renamed rather than removed, so this is a convenience on top of a recovery that was already there — but
/// a reader who deleted the wrong row should not have to open Finder to find out.
private struct UndoRow: View {
    let label: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(Wei.Font.caption())
                .foregroundStyle(Wei.Palette.secondary)
            Text("Deleted “\(label)”")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Undo", action: undo)
                .buttonStyle(.link)
                .font(Wei.Font.caption())
        }
    }
}

/// One session, in the list.
///
/// Two lines, which is what makes the list scannable rather than a wall of first sentences: the label is
/// what the reader is looking for, and under it the two facts that decide whether this is the one they
/// want — how long ago it was used, and whether anything is still happening in it. One line forced both
/// onto the same row and left no room for the second, which is how this read before.
private struct SessionRowView: View {
    let row: SessionRow
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
                .font(Wei.Font.control())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                Text(sessionAgeText(modified: row.modified, now: Date(), calendar: .current))
                if row.running {
                    // A turn in flight *in this session*. With more than one conversation able to run at
                    // once this is a per-row fact rather than a statement about the window, which is
                    // exactly what the shell sends it as — and it is the only state the wire carries per
                    // row, so it is the only one drawn.
                    StatusChip(text: "Running")
                }
            }
            .font(Wei.Font.caption())
            .foregroundStyle(Wei.Palette.secondary)
        }
        // Taller than one line of text, and the same height whatever the second line holds, so the list
        // does not step: a row with a status chip is not a taller row than one without.
        .frame(minHeight: Wei.Control.row, alignment: .leading)
        .padding(.vertical, 2)
        .help(row.path)
        .contextMenu {
            // Renaming is offered on every row and refused by the shell for a session that is not open:
            // the log of a session this process is not holding must not be rewritten from here, and a menu
            // item that vanishes with the selection is a menu item nobody finds.
            Button("Rename…", action: onRename)
            Divider()
            // The file is renamed aside rather than removed, and the list offers it back for a few seconds
            // — so the confirmation says what actually happens rather than warning about a loss that will
            // not occur.
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
            Text("The conversation file is renamed .deleted, and you can undo this from the list.")
        }
    }
}

/// What the shell is, what it has said, and a box to answer it in.
///
/// **The name of the conversation is the only heading, and it is a bar rather than a band.** This column
/// once opened with an opaque band — the name, the model, and the working directory on a material with a
/// hairline under it, running edge to edge — and that is what was removed: a band is the mark of a
/// *panel*, which is why the window read as a sidebar and an everything-else that happened to be split
/// rather than as three columns. A bar is not that. It has no background and no rule, it is one line of
/// type at the column's leading edge, and what separates it from the conversation is the conversation
/// itself going blurry underneath it.
///
/// The other two facts the band carried are still gone, and deliberately: the model is on the composer's
/// own picker, next to the message it will answer; the directory is the project the middle column is
/// listing. Every state the band reported — starting, no key, a turn that failed — is the composer's
/// status line, which says it under the field where a reader is looking anyway (`PiClient.blocked`).
private struct ConversationView: View {
    @ObservedObject var client: PiClient
    /// Shared with the transcript, which decides when it keeps up, and with the send button, which is
    /// the one thing that overrides that decision.
    @StateObject private var scroll = TranscriptScroll()

    /// How tall the bar over the transcript is, as laid out. See `ConversationTitleHeightKey` for why the
    /// margin below the toolbar has to be told about it rather than recomputing it.
    @State private var titleHeight: CGFloat = 0

    /// How far the title is lifted out of the bar's own row and onto the toolbar's centre line, so that the
    /// name shares a row with the toolbar's controls instead of sitting a line below them.
    ///
    /// A safe-area bar is drawn *below* the toolbar, so sharing that row means moving the type up by the
    /// toolbar's height less the half-line the platform centres its own items on. The same amount is given
    /// back as bottom padding, so the bar's own height — and with it the clearance the first row of the
    /// conversation needs — is unchanged. **Measured against a running window**: 46 puts the text's centre on
    /// the toolbar's, 26, for this font at `Wei.Control.toolbar`. Re-measure if either changes.
    private static let titleLift: CGFloat = 46

    /// Room on the trailing side for the toolbar's own control.
    ///
    /// A toolbar item sits in the last stretch of its column, and this column ends where the session button
    /// is: measured on a running window, that button occupies the last 49 points of the width. 64 clears it
    /// with a gap on the 4-point grid — and it is also where a long name gets its ellipsis, which is why the
    /// title is truncated rather than running underneath the button.
    private static let titleTrailingInset: CGFloat = 64

    var body: some View {
        TranscriptView(
            conversation: client.conversation,
            revision: client.revision,
            session: client.currentPath,
            interruptedPrompt: client.interrupted
                ? (client.interruptedPrompt.isEmpty ? "" : client.interruptedPrompt)
                : nil,
            onContinue: { client.continueTurn() },
            onDismiss: { client.dismissTurn() },
            scroll: scroll,
            // The first row has to clear both the toolbar and this column's own title.
            topMargin: Wei.Control.toolbar + (sessionName == nil ? 0 : titleHeight)
        )
            // And the same treatment at the other end, for the same reason: the composer is a card that
            // **floats over** the conversation. It is an inset rather than the last child of a `VStack`
            // because the stack is what shortens the transcript to make room and leaves a hard opaque edge
            // above the card; as an inset the transcript keeps its height, the last row scrolls *under* the
            // card, and the card's own gradient is what it fades into. That is the arrangement
            // `macos/README.md` describes ("浮在对话上的卡片"), and the elevation is the whole of it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(
                    client: client,
                    enabled: client.state != .starting,
                    // A prompt went out, so the reader is asking rather than reading back: the transcript
                    // follows again from here, whatever it had been told before.
                    onSent: { scroll.promptSent() },
                    onStop: { client.stop() }
                )
            }
            // **What this conversation is called, at this column's leading edge.**
            //
            // It says something the window's title does not: that one names the *list* the middle column
            // is showing (which project, how many sessions), because a window has one title and the list
            // is what it is about. A reader who has scrolled into an answer is looking at one conversation,
            // and the name of it belongs where they are looking.
            //
            // The repetition is deliberate. The same name is on the row in the middle column, and that is
            // correct rather than a mistake to be tidied away: one is the name of a thing in a list of
            // things, and this one is the name of the thing on screen. (What *was* a mistake — written down
            // at the top of this column's history — is the version that made the window's title and the
            // transcript's heading say the same words: a window has one title, and two of them read as a
            // program that does not know what it is showing.)
            //
            // `safeAreaBar` rather than a `HStack` above the transcript, and that is the whole of the
            // effect: a bar insets the safe area and **extends the scroll edge effect with it**, so the
            // conversation keeps scrolling *under* the name and is blurred where it passes beneath — the
            // arrangement the settings panel has at the top of its right-hand column. A heading that is
            // simply the first child of a `VStack` shortens the scroll view instead, so nothing ever goes
            // under it and the blur is spent on empty space.
            //
            // No background and no hairline under it. A band with a rule under it is the mark of a *panel*,
            // which is exactly what this column used to open with and why the window read as a sidebar and
            // everything else; the blur is what separates the name from what passes under it.
            .safeAreaBar(edge: .top, alignment: .leading) {
                if let name = sessionName {
                    Text(name)
                        .font(Wei.Font.title())
                        // One line, and the end of it if it does not fit: a question can be long, and a
                        // title that wraps to four lines is a title that has become the first paragraph.
                        // The tail rather than the middle, so what the reader sees is how the question
                        // *begins* — which is how they would recognize it in the list — and so the
                        // ellipsis is where they expect one.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The width is the room there is, not the width of the words: this is what makes
                        // the platform truncate, rather than the text being clipped by its neighbours.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Wei.Space.section)
                        .padding(.trailing, Self.titleTrailingInset)
                        .padding(.top, Wei.Space.cozy - Self.titleLift)
                        .padding(.bottom, Wei.Space.cozy + Self.titleLift)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ConversationTitleHeightKey.self,
                                    value: geometry.size.height
                                )
                            }
                        )
                        // The whole question on hover, since the line above may be showing a third of it.
                        .help(name)
                }
            }
            .onPreferenceChange(ConversationTitleHeightKey.self) { height in
                titleHeight = height
            }
        // Deliberately no `navigationTitle` here. In a three-column split the *content* column elects the
        // window's title and this one's is ignored — the two facts that used to live here have moved: the
        // model is on the composer's own picker, next to the message it will answer, and the directory is
        // the project the middle column is listing, whose full path is on its row's tooltip.
        // Deliberately no `toolbar` at all. What used to be here — the running-jobs register and Settings —
        // has moved to the workspace column, which is where the web UI keeps both and where they describe
        // something that spans the window rather than this column: jobs run in *any* session, and settings
        // belong to the app. What the window's toolbar holds now is one control per column, each over the
        // column it acts on: Hide Sidebar over the workspace column, New Session over the session list.
        //
        // And **deliberately no `toolbar(removing: .title)`**, which is how the settings panel gets its
        // leading-edge title: there the window's title and the drawn one are the same fact and one of them
        // has to go. Here they are two facts — the list, and the conversation on screen — so the window's
        // title stays where the system puts it, over the column it is about.
    }

    /// What the session on screen is called: the reader's own name for it, else its first question, else
    /// the id — the three-source rule the list's rows are already labelled by (`SessionRow.label`).
    ///
    /// Read from those same rows rather than computed again, so the title here and the row in the middle
    /// column cannot drift apart. `nil` while the store has not listed the session, which is a session
    /// created a moment ago: the bar is simply not drawn rather than drawn empty.
    private var sessionName: String? {
        guard let label = client.sessions.first(where: { $0.path == client.currentPath })?.label,
            !label.isEmpty
        else { return nil }
        return label
    }
}

/// What the window is in the middle of doing.
///
/// A reference type shared by the scene and the view tree, because two places have to start the same
/// thing: the File menu (where a Mac user looks for "New …") and the toolbar. State that both of them
/// write cannot be a `@State` on one view and a closure handed to the other — that is the shape that
/// produced a message which never left the app (see `docs/macos-pitfalls.md`), because a closure
/// captures a value and this is a thing that changes.
@MainActor
final class WindowActions: ObservableObject {
    /// Whether the folder chooser is open. Owned here rather than by the view that draws it, so the
    /// menu bar can open it too.
    @Published var choosingFolder = false
}

/// Where the transcript is scrolled to, and whether it should keep up with what arrives.
///
/// A reference type because two views that do not own each other have to agree about it: the
/// transcript measures and decides, and the composer's send is the one thing that overrides.
///
/// The decision itself is `ScrollFollow` in `PiModel` — this holds the geometry and the reader's
/// gestures, which are the two facts that rule needs.
@MainActor
private final class TranscriptScroll: ObservableObject {
    private var follow = ScrollFollow()
    /// The bottom of the transcript, in the scroll view's own coordinates, and the height of the
    /// window onto it. Both from a preference pass rather than from a scroll event, because a
    /// layout-driven measurement is the one that arrives *after* the thing that changed.
    private var bottom: CGFloat = 0
    private var viewport: CGFloat = 0

    /// How close to the end counts as being at it. A line's worth, so the last row being fully
    /// visible is "the bottom" rather than a half-hidden row.
    private let margin: CGFloat = 24

    /// Whether the end of the transcript is currently in view.
    var atBottom: Bool { bottom <= viewport + margin }

    func measured(bottom: CGFloat, viewport: CGFloat) {
        self.bottom = bottom
        self.viewport = viewport
    }

    /// The reader scrolled. `up` is whether the content moved down the screen.
    func readerScrolled(up: Bool) {
        follow.readerScrolled(up: up, atBottom: atBottom)
    }

    /// A prompt went out.
    func promptSent() {
        follow.promptSent()
    }

    /// Another session's transcript is now on screen.
    ///
    /// Forced rather than measured, for the same reason as a prompt: the rows have not been drawn yet, so the
    /// measurements this would consult are of a transcript that is not on screen any more.
    func opened() {
        follow.opened()
    }

    /// Whether a new row should be scrolled to. Read at the moment a revision arrives, rather than
    /// published: nothing is drawn differently either way.
    var following: Bool { follow.following }
}

/// Where the bottom of the transcript is, reported to the view that decides whether to follow.
private struct TranscriptBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// And how tall the window onto it is.
private struct TranscriptViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// How tall the bar over the transcript is, including its own padding.
///
/// Needed because the two numbers are separate mechanisms and only one of them knows about the other: the
/// bar insets the *safe area*, while what keeps the transcript's first row from being hidden for good is a
/// content margin (`Wei.Control.toolbar`, measured from the window's top edge). Adding the bar on top of
/// that margin without measuring it put the title on the first line of the conversation — which is what the
/// first version of this did, and what a screenshot showed. Measured rather than written as a constant so
/// that the font size and the padding stay the only places that decide it.
private struct ConversationTitleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TranscriptView: View {
    let conversation: Conversation
    let revision: Int
    /// Which session this transcript belongs to. Changes when the reader switches, which is what makes the
    /// view land at the end of the new one.
    let session: String
    /// The transcript as turns — the grouping rule lives in `PiModel`, where it is tested.
    private var turns: [Turn] { PiModel.turns(of: conversation.rows) }

    /// The turn that was interrupted, if the session has one open.
    ///
    /// Pinned above the scroll view rather than put inside it, and the difference is the whole of a bug
    /// a screenshot found: it used to be the first row *of* the transcript, which meant that on any
    /// conversation long enough to scroll — which is every conversation an interrupted turn happens in —
    /// it sat off the top of the screen. The two buttons that are the only way out were therefore
    /// unreachable at exactly the moment they were needed, and the code's own comment ("it has to stay
    /// reachable while they read back what happened") described the intent rather than the behaviour.
    let interruptedPrompt: String?
    let onContinue: () -> Void
    let onDismiss: () -> Void
    @ObservedObject var scroll: TranscriptScroll

    /// How far below the window's top edge the first row must start — the toolbar, plus whatever bar the
    /// column draws over the top of the scroll view. The view above this one knows about its own bar and
    /// passes the sum; `Wei.Control.toolbar` is the answer for a column that draws none.
    var topMargin: CGFloat = Wei.Control.toolbar

    /// The app-wide scroll monitor, installed while the transcript is on screen. See `onAppear`.
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            if let interruptedPrompt {
                InterruptedTurnNotice(
                    prompt: interruptedPrompt,
                    onContinue: onContinue,
                    onDismiss: onDismiss
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            // The transcript takes the top of the column over; the notice does not. The two buttons that
            // are the only way out of an interrupted turn are the last thing that should have a toolbar
            // drawn on top of them, so when there is a notice the transcript gives the top edge back
            // (`ignoresSafeArea` with no edges) and the notice keeps its place below the toolbar.
            transcript
                .ignoresSafeArea(.container, edges: interruptedPrompt == nil ? .top : [])
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Wei.Space.section) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        TurnView(
                            turn: turn,
                            // A turn that is still arriving stays open: a fold a reader has to open to watch
                            // the agent work is a fold opened on every turn. Everything else folds, which is
                            // the web UI's rule and the reason a long conversation is readable at all.
                            live: index == turns.count - 1 && conversation.running
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Wei.Space.section)
                // The two measurements: where the content ends, and how tall the window is. The
                // sentinel sits after the content, so its position in the scroll view's coordinates
                // is the bottom — a positive number that grows towards the viewport height as the
                // reader approaches the end.
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: TranscriptBottomKey.self,
                            value: geometry.frame(in: .named("transcript")).maxY
                        )
                    }
                )
            }
            .coordinateSpace(name: "transcript")
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TranscriptViewportKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .onPreferenceChange(TranscriptBottomKey.self) { bottom in
                scroll.measured(bottom: bottom, viewport: viewportHeight)
            }
            .onPreferenceChange(TranscriptViewportKey.self) { height in
                viewportHeight = height
            }
            // Follows the newest line, but only while the reader is at the end of it. See
            // `ScrollFollow` for what is allowed to stop that, and — more importantly — what is not.
            //
            // The two-parameter form is the one macOS 14 introduced: the old signature is deprecated
            // and warns on every build. Neither argument is used — the revision is what changed, and
            // the view body already knows that.
            // The content starts below the toolbar even though the scroll view does not.
            //
            // This is the half of "runs under the toolbar" that is easy to forget: the scroll view begins
            // at the window's top edge now, so without a margin on the *content* the first row of the
            // conversation would sit behind the toolbar for good — visible while scrolling past, never
            // visible at the top, which is a row the reader could never read. A content margin keeps both
            // facts: what scrolls goes under the toolbar, and nothing is permanently hidden by it.
            .contentMargins(.top, topMargin, for: .scrollContent)
            // **And what passes under the toolbar is blurred, by the platform.** `scrollEdgeEffectStyle`
            // is macOS 26's own answer to "content runs under a floating control": a progressive blur at
            // the scroll edge, strongest at the edge and gone a little below it. Measured from Podcasts —
            // a Catalyst app using the same effect — the band is about 60 points, and per-row edge energy
            // goes 0.0–0.9 at the edge, 2.9–5.3 at 50 points, and 18–25 by 70, where text is crisp again.
            //
            // This is what both earlier attempts were reaching for and could not get: an *opaque* band
            // hid the first row for good ("全遮挡了"), and a bare content margin left rows colliding with
            // the toolbar's own controls, which reads as a bug rather than as depth. A blur says the third
            // thing — this is still there, you are scrolling past it. `.soft` is the subtle variant; `.hard`
            // is the stronger one, and `nil` (or `scrollEdgeEffectHidden`) turns the whole thing off.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: revision) { _, _ in
                guard scroll.following, let last = conversation.rows.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            // Opening a session lands at its end, whatever the reader was doing in the last one.
            //
            // Not the same rule as following, and deliberately not: following is "keep up with a growing
            // transcript", which must respect a reader who has scrolled up to read something. This is "I have
            // just been handed a different conversation", and a conversation is read from its end — the first
            // frame of a switch otherwise shows the *top* of a ninety-turn log, which is the one place nobody
            // wants to start. The web UI made the same call for the same reason.
            .onChange(of: session) { _, _ in
                scroll.opened()
                guard let last = conversation.rows.last else { return }
                // After the rows are laid out: scrolling to a row the view has not built yet does nothing.
                DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            // The reader's own scrolling, which is the only thing that can stop the following. A
            // local monitor because SwiftUI on macOS 14 has no "the user scrolled" callback: the
            // alternatives are all measurements, and a measurement cannot tell a reader moving from
            // content growing — which is the whole distinction the rule is made of.
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
                    let up = event.scrollingDeltaY > 0
                    Task { @MainActor in scroll.readerScrolled(up: up) }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }
    }

    /// Held outside the preference closure so the two measurements can be combined into one decision
    /// without either of them being stale.
    @State private var viewportHeight: CGFloat = 0
}

/// One turn: the question, the work (folded once the turn is over), the answer, and the figures.
///
/// The shape is the web UI's *exchange* — `html/render.mbt`'s `render_exchange` — and this is deliberately a
/// copy of it rather than a second opinion: a conversation reads the same way in both front ends, or the two
/// stops agreeing about what a turn is. What the reader gets is the answer and a line saying how much work
/// went into it; the work itself is one click away.
private struct TurnView: View {
    let turn: Turn
    /// Whether this turn is still arriving. A live turn draws its work open.
    let live: Bool

    @State private var workOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Wei.Space.regular) {
            if let question = turn.question {
                RowView(row: question)
            }
            if turn.hasWork {
                // The toggle is **above** the work, in both states.
                //
                // It was below the expanded work first, which put the way to close it under however many rows
                // had just been opened — so folding a turn back up meant scrolling to the bottom of the thing
                // you had just asked to see. A disclosure's control belongs where the reader's eye already is,
                // which is the line it opened with.
                foldButton(open: workOpen || live)
                if workOpen || live {
                    VStack(alignment: .leading, spacing: Wei.Space.regular) {
                        ForEach(turn.work) { row in
                            RowView(row: row).id(row.id)
                        }
                    }
                }
            }
            if let answer = turn.answer {
                RowView(row: answer)
            }
            if let figures = turn.figures {
                TurnFigures(text: figures)
            }
        }
    }

    private func foldButton(open: Bool) -> some View {
        Button {
            workOpen.toggle()
        } label: {
            HStack(spacing: Wei.Space.tight) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: Wei.Icon.inline - 2, weight: .semibold))
                Text(turn.workLabel)
                    .font(Wei.Font.caption())
            }
            .foregroundStyle(Wei.Palette.secondary)
        }
        .buttonStyle(.plain)
        .help(open ? "Hide what it did" : "Show what it did")
    }
}

/// A finished turn's figures: what it cost, and how much of a seat it took.
///
/// The web UI's footer, in the same place for the same reason: it is about the turn, so it sits under it —
/// and it is a *line of figures* rather than a row in the conversation, because a reader deciding whether to
/// ask another question looks at it and a reader reading the answer does not.
private struct TurnFigures: View {
    let text: String

    var body: some View {
        HStack(spacing: Wei.Space.tight) {
            Image(systemName: "chart.bar")
                .font(.system(size: Wei.Icon.inline - 1))
            Text(text)
                .font(Wei.Font.caption())
        }
        .foregroundStyle(Wei.Palette.tertiary)
        .padding(.top, Wei.Space.tiny)
    }
}

/// The reasoning of a turn: dimmed, indented, and folded once it has stopped arriving.
private struct ThinkingRow: View {
    let row: Row
    @State private var expanded = false

    /// Folded only when the block is finished *and* the reader has not opened it: a block still arriving is
    /// open, because that is what the reader is watching.
    private var showsText: Bool {
        expanded || !row.complete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Wei.Space.tight) {
            if showsText {
                Text(row.text)
                    .font(Wei.Font.code())
                    .foregroundStyle(Wei.Palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.complete {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: Wei.Space.tight) {
                        Image(systemName: "brain")
                            .font(.system(size: Wei.Icon.inline - 1))
                        Text(expanded ? "Hide reasoning" : "Reasoning")
                    }
                    .font(Wei.Font.caption())
                }
                .buttonStyle(.link)
                .foregroundStyle(Wei.Palette.secondary)
            }
        }
        .padding(.leading, Wei.Space.regular)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 2)
        }
    }
}

/// The notice above a session whose last turn was interrupted.
///
/// The same two ways out the web UI offers, because they are the only two there are: carry on with
/// the question that was already asked — the work already done stays in front of the model — or
/// close the turn and start fresh. It is drawn as a row above the transcript rather than as a modal,
/// because reading back what happened is exactly what a reader wants to do before choosing.
private struct InterruptedTurnNotice: View {
    let prompt: String
    let onContinue: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(Wei.Font.control())
            VStack(alignment: .leading, spacing: 4) {
                Text("This turn was interrupted")
                    .fontWeight(.medium)
                if !prompt.isEmpty {
                    // Quoted rather than paraphrased: it is the question the model would be handed
                    // again, and a reader deciding whether to continue should be able to check it
                    // against what they remember asking.
                    Text("“\(prompt)”")
                        .foregroundStyle(Wei.Palette.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Start Fresh", action: onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Close this turn. Nothing is resumed and nothing is lost.")
        }
        .font(Wei.Font.control())
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Wei.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Wei.Radius.panel).strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct RowView: View {
    let row: Row

    var body: some View {
        switch row.kind {
        case .user:
            Text(row.text)
                .font(Wei.Font.body())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Wei.Palette.highlightWash, in: RoundedRectangle(cornerRadius: Wei.Radius.control))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .reply:
            // The parse if the shell has sent one, the raw text if it has not. Either way the words are
            // the same; what the parse adds is what markdown *means* — a table, a heading, a fence's
            // language — which is the part `AttributedString(markdown:)` gets wrong and the reason the
            // shell parses at all.
            BlockView(blocks: row.blocks, plain: row.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking:
            // Reasoning, folded: it is worth being able to read and not worth competing with the answer.
            //
            // It arrives before the answer and is often the longest thing in a turn, so leaving it open puts a
            // page of working-out between the reader's question and its answer. The web UI folds it for the
            // same reason; a summary line says there was some, and a click opens it.
            //
            // Kept open while it is still arriving: a fold that has to be opened to watch the agent think is a
            // fold opened and closed on every turn.
            ThinkingRow(row: row)

        case .tool:
            ToolRow(row: row)

        case .note:
            // A labelled note is a disclosure; an unlabelled one is a line of small print — the
            // figures at the end of a turn.
            //
            // The label is what makes the difference, and the summary is what is folded away: it is
            // the longest text in the transcript and the least often read, so it gets a summary line
            // a reader can ignore and a click that opens it when they want to check what was kept.
            // Drawing it open would put a page of somebody else's prose in the middle of the
            // conversation — which is what it was before this was a row rather than a paragraph.
            if row.name.isEmpty {
                Text(row.text)
                    .font(Wei.Font.caption())
                    .foregroundStyle(Wei.Palette.tertiary)
            } else {
                DisclosureGroup {
                    Text(row.text)
                        .font(Wei.Font.control())
                        .foregroundStyle(Wei.Palette.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: Wei.Icon.inline - 2, weight: .semibold))
                        Text(row.name)
                            .font(Wei.Font.caption(.medium))
                    }
                    .foregroundStyle(Wei.Palette.secondary)
                }
                .padding(.vertical, 2)
            }
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
                        .foregroundStyle(row.isError ? Color(nsColor: .systemRed) : Wei.Palette.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(row.name).font(Wei.Font.control(.medium))
                if !row.detail.isEmpty {
                    Text(row.detail).font(Wei.Font.caption()).foregroundStyle(Wei.Palette.secondary).lineLimit(1)
                }
                Spacer()
                if row.output.isEmpty {
                    EmptyView()
                } else if !row.complete {
                    // Only while it is still running: once there is output the fold below is the control.
                    EmptyView()
                }
            }
            if !row.output.isEmpty {
                // Output is **clipped until asked for**, and the clip is what makes a transcript readable:
                // a tool that printed 400 lines is the common case, not the exception, and a log that is
                // always open pushes the next thing the reader wants off the screen. The first two lines are
                // shown, which is enough to tell "it worked" from "it did not", and the rest is a click away.
                //
                // A `Text` with a line limit rather than a fixed-height box: it is the same font and the same
                // wrapping as the expanded version, so nothing shifts when it opens.
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.output)
                        .font(Wei.Font.code(Wei.Size.control))
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(Wei.Font.caption())
                        .padding(.top, Wei.Space.tight)
                }
                .padding(Wei.Space.cozy)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Wei.Radius.chip))
            }
        }
        .padding(.leading, 2)
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
                .font(Wei.Font.body())
                .textSelection(.enabled)
        }
    }
}

/// A paragraph, with the pictures in it given their own line.
///
/// A picture cannot be drawn inside an `AttributedString` — the text attributes a `Text` takes carry
/// no image — so a paragraph containing one is laid out as *runs*: the text before it, the picture,
/// the text after it. Most answers are the easy case, because a picture is usually a line of its own,
/// which is one run and nothing changes.
///
/// The cost of the two-part paragraph is stated rather than hidden: prose does not flow around a
/// picture, so `before ![x](/tmp/x.png) after` is three lines rather than a sentence with a picture in
/// it. Laying that out properly is a text system of its own, and it would be spent on a shape no
/// answer here writes.
///
/// A run of nothing but whitespace is dropped rather than drawn. The newlines around an image are
/// how the markdown was written, not a gap the reader asked for.
private struct ParagraphView: View {
    let spans: [Block.Span]

    private enum Run {
        case text([Block.Span])
        case picture(target: String, alt: String)
    }

    var body: some View {
        if hasPicture {
            VStack(alignment: .leading, spacing: Wei.Space.cozy) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    switch run {
                    case let .text(spans):
                        line(spans)
                    case let .picture(target, alt):
                        Picture(target: target, alt: alt)
                    }
                }
            }
        } else {
            // No picture, which is nearly every paragraph: the text is the whole of it.
            line(spans)
        }
    }

    private func line(_ spans: [Block.Span]) -> some View {
        Text(Styled.spans(spans))
            .font(Wei.Font.body())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hasPicture: Bool {
        spans.contains { span in
            if case .image = span { return true }
            return false
        }
    }

    private var runs: [Run] {
        var out: [Run] = []
        var pending: [Block.Span] = []
        func flush() {
            defer { pending.removeAll() }
            guard !pending.isEmpty else { return }
            // A run that says nothing is the newline the markdown was written with, not a gap.
            let said = Styled.spans(pending).characters
            guard said.contains(where: { !$0.isWhitespace }) else { return }
            out.append(.text(pending))
        }
        for span in spans {
            guard case let .image(target, alt) = span else {
                pending.append(span)
                continue
            }
            flush()
            out.append(.picture(target: target, alt: alt))
        }
        flush()
        return out
    }
}

/// One block, drawn.
private struct BlockBody: View {
    let block: Block

    var body: some View {
        switch block {
        case let .paragraph(spans):
            ParagraphView(spans: spans)

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
                    .font(Wei.Font.micro())
                    .foregroundStyle(Wei.Palette.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Wei.Font.code())
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Wei.Radius.chip))
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
                        .font(Wei.Font.code(Wei.Size.body))
                        .foregroundStyle(Wei.Palette.secondary)
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
        .foregroundStyle(Wei.Palette.secondary)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 2)
        }
    }
}

/// A markdown table, with the alignments the source asked for.
///
/// The widths come from `tableLayout`, not from the cells: a cell that sized itself would make every row
/// its own table, which is what this looked like before a screenshot showed the vertical rules landing
/// at a different x on each row. One width per column, every cell drawn at it, and the whole thing
/// scrolls sideways rather than reflowing — a table narrowed into a single column is no longer a table.
private struct TableView: View {
    let header: [[Block.Span]]
    let rows: [[[Block.Span]]]
    let align: [Block.Align]

    /// A cell's horizontal padding. Applied here as part of the measured width, so a cell's box and its
    /// column's width are one number rather than two that have to agree.
    private static let padding: CGFloat = 10
    /// A floor, so a column of one-character cells is still a column.
    private static let minimum: CGFloat = 60
    /// A ceiling, so one long cell does not push the table off the side of the window. A cell wider than
    /// this wraps instead.
    private static let maximum: CGFloat = 320

    private var layout: TableLayout {
        tableLayout(
            header: header,
            rows: rows,
            align: align,
            padding: Self.padding,
            minimum: Self.minimum,
            maximum: Self.maximum,
            measure: Self.width
        )
    }

    var body: some View {
        let laid = layout
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(laid.header, isHeader: true, laid: laid)
                ForEach(Array(laid.rows.enumerated()), id: \.offset) { _, cells in
                    Divider()
                    row(cells, isHeader: false, laid: laid)
                }
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Wei.Radius.chip))
    }

    private func row(_ cells: [[Block.Span]], isHeader: Bool, laid: TableLayout) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, spans in
                Text(Styled.spans(spans))
                    .font(Wei.Font.control(isHeader ? .semibold : .regular))
                    .multilineTextAlignment(alignment(laid.align[index]))
                    .padding(.horizontal, Self.padding)
                    .padding(.vertical, 6)
                    // The whole point: a fixed width, the same number for every row, so the rules form
                    // vertical lines. The column's box is aligned too, so a right-aligned column is
                    // right against the rule rather than floating in the middle of its own width.
                    .frame(
                        width: laid.widths[index],
                        alignment: frame(laid.align[index])
                    )
                if index < cells.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func alignment(_ column : Block.Align) -> TextAlignment {
        switch column {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func frame(_ column : Block.Align) -> Alignment {
        switch column {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    /// How wide a cell's text is, in the font it will be drawn in.
    ///
    /// `NSAttributedString` rather than a `GeometryReader`: this is asked for every cell of every table
    /// before anything is drawn, and a reader that reported back would have to be measured twice (once
    /// unmeasured, once with the answer). The font has to be set here rather than inherited from the
    /// view, because the measurement happens outside it — and it has to be the *same* font, or the
    /// column is sized for text that is not what is drawn.
    private static func width(_ spans: [Block.Span]) -> CGFloat {
        let attributed = NSMutableAttributedString(
            attributedString: NSAttributedString(Styled.spans(spans))
        )
        guard attributed.length > 0 else { return 0 }
        attributed.addAttribute(
            NSAttributedString.Key.font,
            value: NSFont.systemFont(ofSize: 12),
            range: NSRange(location: 0, length: attributed.length)
        )
        return ceil(attributed.size().width)
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
            out.font = Wei.Font.code()
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
        case let .image(_, alt):
            // A picture inside a line of text — a table cell, a bullet, a heading. There is no
            // picture here, and the alt text is what the markdown itself provided as the words for
            // it: the same answer as a picture whose bytes could not be read, in the one place a
            // `Picture` view cannot be put.
            return AttributedString(alt)
        }
    }
}
