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
    /// Whether the background-jobs register is open. On the window rather than on a column: it is a
    /// popover from the toolbar, and every column can see it.
    @State private var showingJobs = false
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
            WorkspaceList(client: client, browsing: $browsing)
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
                search: $search,
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
            ConversationView(
                client: client,
                showingJobs: $showingJobs
            )
            .frame(minWidth: 420, minHeight: 320)
        }
        // The brand accent, applied where the platform applies it: with `.tint`, the system draws its own
        // selection, focus rings and default buttons in this colour. Setting it here rather than painting a
        // background per control is what keeps every control agreeing without being told separately — and it
        // is why the reader's own accent colour does not show through in this app.
        .tint(Wei.Palette.accent)
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

    var body: some View {
        VStack(spacing: 0) {
            wordmark
            List(selection: $browsing) {
                ForEach(client.groups) { group in
                    WorkspaceRow(group: group)
                        .tag(group.cwd)
                }
            }
            .listStyle(.sidebar)
        }
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
        // The mark is the brand's fill hue, so a hairline under the wordmark is what makes it read as the
        // app's own strip rather than as the first row of the list.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Wei.Palette.separator)
                .frame(height: Wei.Control.hairline)
        }
    }
}

/// One project: a folder, its name, how many sessions, and whether the open conversation is inside it.
///
/// The dot is kept from the two-column version and means more here than it did: the middle column shows
/// whichever project the reader is *browsing*, which is not necessarily the one holding the open
/// conversation — so without a mark, browsing away from a running session hides where it is.
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
/// The search field is here rather than in the sidebar because **this is the list it filters**. Typing
/// reaches every project, and a result is headed by the project it came from — a match in another
/// directory has to say so, or opening it is a jump with no explanation. Deliberately not a search of the
/// *transcripts*: that would mean reading every file, which is the cost the shell avoids everywhere else,
/// and a list that pauses to read the disk is a list that stops responding.
private struct SessionList: View {
    @ObservedObject var client: PiClient
    /// The project being browsed.
    let browsing: String
    /// What to draw, from the rules in `PiModel` — computed one level up, where the titlebar can see the
    /// count too.
    let sections: [SessionSection]
    /// The search field's text. Owned by the window (see `RootView`), because the title reads it.
    @Binding var search: String
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

    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
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
        VStack(spacing: 0) {
            searchField
            list
        }
    }

    /// A capsule field on the app's own surface, rather than `.searchable`.
    ///
    /// **The standard control, and why this is not it.** On macOS the standard search field is
    /// `NSSearchField`, which SwiftUI hands you as `.searchable` — a rounded *rectangle*, at control height,
    /// and either in the toolbar or in one of the placements the modifier documents. It is a good control
    /// and it is in the wrong place here: in a three-column split the placement meaning "this column" is not
    /// one of them, and a field that landed in the toolbar would look like it searched the conversation.
    /// A *capsule* is not standard on macOS at all — that shape is the toolbar's own button shape in macOS
    /// 26, which is why this is the reference the reader is comparing against.
    ///
    /// So: the standard control's *behaviour* (leading magnifier, inline clear button, Return to commit) at
    /// the toolbar's *shape* and height, inside the list it filters. Deviating from the platform's shape is
    /// a cost paid knowingly; the radius, the material and the height are all the platform's, and the
    /// magnifier and the clear button are where a Mac reader looks for them.
    ///
    /// Size: the toolbar's own control height, so the field lines up with the buttons in the titlebar
    /// rather than floating at some third height between them and the list.
    ///
    /// Kept *above* the list rather than scrolling with it — a control, not the first row, and a search
    /// field you have to scroll back up to is one you forget is there.
    private var searchField: some View {
        HStack(spacing: Wei.Space.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Wei.Icon.inline))
                .foregroundStyle(Wei.Palette.secondary)
            TextField("Search sessions", text: $search)
                .textFieldStyle(.plain)
                .font(Wei.Font.control())
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Wei.Icon.inline))
                        .foregroundStyle(Wei.Palette.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        // The toolbar control height, and the reason the field reads as belonging to the titlebar's row of
        // buttons rather than to the list underneath it.
        .frame(height: Wei.Control.regular)
        .padding(.horizontal, Wei.Space.regular)
        .weiSurface(in: Capsule())
        .padding(.horizontal, Wei.Space.loose)
        .padding(.top, Wei.Space.regular)
        .padding(.bottom, Wei.Space.cozy)
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
                    Text(section.title)
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
        return groups.contains(where: { $0.cwd == browsing })
            ? "No sessions in this project. Type below to start one."
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
/// The conversation carries **its own title**, over the transcript: the session by name, and under it the model
/// that will answer and where the tools run. The window's title says which *project* the middle column is
/// listing, so without this the window would not say which conversation it is showing.
private struct ConversationView: View {
    @ObservedObject var client: PiClient
    @Binding var showingJobs: Bool

    @Environment(\.openSettings) private var openSettings
    /// Shared with the transcript, which decides when it keeps up, and with the send button, which is
    /// the one thing that overrides that decision.
    @StateObject private var scroll = TranscriptScroll()

    /// The session's name, and the two facts about it that the title bar does not carry.
    ///
    /// A heading rather than a `navigationTitle`, because the window's title says which *project* the middle
    /// column is listing. What this adds is what the transcript is: the conversation by name, the model that
    /// will answer, and where the tools run — the three things a reader checks mid-turn.
    ///
    /// On a **material**, so the transcript scrolling under it fades rather than disappearing behind a band.
    /// That is the platform's own answer to "a header over scrolling content": the vibrancy is the gradient.
    /// The hairline under it is deliberately the separator at half weight — enough to mark the edge of the
    /// title, not enough to draw a line across the window.
    private var conversationHeader: some View {
        VStack(alignment: .leading, spacing: Wei.Space.tiny) {
            Text(client.currentTitle.isEmpty ? client.currentPath : client.currentTitle)
                .font(Wei.Font.title())
                .lineLimit(1)
                .truncationMode(.middle)
            if !subtitleLine.isEmpty {
                Text(subtitleLine)
                    .font(Wei.Font.caption())
                    .foregroundStyle(Wei.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Wei.Space.section)
        .padding(.top, Wei.Space.loose)
        .padding(.bottom, Wei.Space.cozy)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Wei.Palette.separator)
                .frame(height: Wei.Control.hairline)
                .opacity(0.5)
        }
    }

    /// What the heading's second line says: the model in force, and where the tools run.
    ///
    /// Both are things a reader checks — "is it the model I thought", "is it working in the directory I
    /// thought" — and both were in the window's subtitle before the three-column layout took it.
    private var subtitleLine: String {
        switch client.state {
        case .starting:
            return "starting…"
        case let .ready(_, _, cwd, _):
            return "\(client.catalog.currentLabel) · \(cwd)"
        case .unkeyed:
            return "no API key — open Settings"
        case let .failed(text):
            return text
        }
    }

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
            scroll: scroll
        )
            // The conversation's own title, **inset over the transcript** rather than stacked above it.
            //
            // This is the difference between a heading and a band. `safeAreaInset` keeps the title in the
            // scroll view's safe area: the transcript keeps its full height, rows scroll *under* the title,
            // and the material the title sits on is what they fade into. Stacking it in a `VStack` — which
            // is what this was — shortens the transcript by the header's height and gives the top of the
            // column a hard opaque edge, which is the "gradient went away" that was reported.
            .safeAreaInset(edge: .top, spacing: 0) {
                conversationHeader
            }
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
        // Deliberately no `navigationTitle` here. In a three-column split the *content* column elects the
        // window's title and this one's is ignored — the two facts that used to live here have moved: the
        // model is on the composer's own picker, next to the message it will answer, and the directory is
        // the project the middle column is listing, whose full path is on its row's tooltip.
        .toolbar {
            // A plain button in the toolbar, next to Settings and styled like it — the same floating capsule
            // every toolbar control in macOS 26 is.
            //
            // It went through two other shapes on the way here and both were wrong: a `Menu` (so one click
            // opened a menu that asked which kind of new session you wanted), and then a bare glyph inside the
            // column's own heading row (which is not where a toolbar control goes, and did not look like one).
            // "New session in *this* project" is one action with one answer, and the variant that needs a
            // choice — a session in some other folder — is in the File menu where a reader goes looking for it.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    client.newSession()
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("New session in this project (⌘N)")
            }

            // Only while something is running: a button that opens an empty list is a button that
            // teaches the reader to ignore it. The count is the point — it is the one thing on screen
            // that says work is still going somewhere.
            if !client.jobs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingJobs = true
                    } label: {
                        Label("\(client.jobs.count) running", systemImage: "gearshape.2")
                    }
                    .help("Background jobs")
                    .popover(isPresented: $showingJobs, arrowEdge: .top) {
                        JobsPanel(client: client)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
    }

}

/// The conversation.
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
            transcript
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

/// One block, drawn.
private struct BlockBody: View {
    let block: Block

    var body: some View {
        switch block {
        case let .paragraph(spans):
            Text(Styled.spans(spans))
                .font(Wei.Font.body())
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
        }
    }
}
