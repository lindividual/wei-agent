import SwiftUI

import WeiKit
import WeiModel

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
    @ObservedObject var client: ShellClient
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

    /// The session being renamed, and what the dialog's field holds. Owned by the window because two
    /// columns start the same dialog: the list's row menu, and the pencil beside the conversation's name.
    @State private var renaming: SessionRow?
    @State private var renameDraft = ""

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
                onBrowse: { browsing = $0 },
                onRename: { startRenaming($0) }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 460)
            // **This column owns the window's title, and the detail column does not.** That is not a
            // preference, it is what a three-column `NavigationSplitView` does: with three columns the
            // *content* column elects the title and any `navigationTitle` on the detail is ignored. Found
            // by asking the window what it thought it was called (`NSWindow.title`, from inside, because
            // no permission is needed for that) — it said `upstream`, the scene's own name, because the title it
            // was actually given computed to empty. The reader saw a titlebar reading "upstream" forever.
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
                actions: actions,
                // The project the toolbar's plus creates in — the same resolved value the session list
                // is listing, so the button and the list can never disagree about "this project".
                browsing: browsed,
                onRename: {
                    // The same dialog as the row's own context menu, started from this column because the
                    // name is written *here*: a reader who wants it different is looking at it.
                    if let row = currentSessionRow { startRenaming(row) }
                }
            )
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
        // **Handed to the app, because `⌘N` is defined there.** The command and the two buttons that
        // carry it out are one command, so they have to name one project — `browsed` rather than
        // `browsing`, because that is the value those buttons pass and the fallback is part of the answer
        // (a project the store has not listed yet still has an open session in it). Recomputing it in the
        // menu bar instead would be a second definition of "the project this window is browsing", which is
        // how the two drifted apart in the first place.
        //
        // No `onAppear` to seed it, deliberately: the initial `""` is not a missing value. A window that
        // has not chosen a project and a window whose reader chose none are the same state, and the shell
        // answers both with the project on screen — which is what `browsed` computes to when there is
        // nothing chosen yet.
        .onChange(of: browsed) { _, project in actions.browsing = project }
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
            client.addWorkspace(url.path)
        }
        // **One rename dialog for both columns.** It used to live in the session list, which was right
        // while the list was the only place a session could be named. The pencil is now in the conversation
        // column's toolbar — next to the name it changes — and two copies of a dialog is two places for the
        // wording, the button order and the "what does this write" sentence to drift apart.
        .alert("Rename Session", isPresented: renamePresented) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { client.rename(renaming.path, to: renameDraft) }
                renaming = nil
            }
        } message: {
            Text("The name is written into the session's own file, so it travels with it.")
        }
    }

    /// The row for the session on screen, from the list the shell sent. `nil` for a session created a
    /// moment ago, which the store has not listed yet.
    private var currentSessionRow: SessionRow? {
        client.sessions.first(where: { $0.path == client.currentPath })
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private func startRenaming(_ row: SessionRow) {
        renameDraft = row.label
        renaming = row
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
    @ObservedObject var client: ShellClient
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
            identity
            searchField
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
                addWorkspace
                ForEach(client.groups) { group in
                    WorkspaceRow(group: group, onRemove: { remove(group) })
                        .tag(group.cwd)
                }
            }
            .listStyle(.sidebar)
            // Air between the search field and the first heading, so the heading reads as a heading rather
            // than as another row of the field. It used to be load-bearing: while the platform placed the
            // field in this column's accessory band the list's content was inset *under* it, so the first row
            // laid out above the list's own top edge and was clipped — measured, the "Running tool calls" title
            // came out at ay 154 with the list's frame starting at 169. (Found by dumping the accessibility
            // tree, which is the only way this shows up — the row is in the tree, with a real size, and simply
            // not drawn.) The field is a row above the list now, so this is only room.
            .contentMargins(.top, Wei.Space.loose, for: .scrollContent)
        }
        // **Settings, one glyph at the leading end of this column's own band.**
        //
        // It was the last row of this column, at the bottom of the list, and that is where the mark used to
        // be: the two swapped places, because the mark is the app's *identity* and identity reads first — it
        // is what the column is, above everything the column lists — while preferences are the app's own
        // control and belong where a control belongs, in the band the platform gives this column for
        // controls. A reader looking for them looks in the app menu first anyway (`⌘,` is still wired).
        //
        // `.automatic` is the placement that lands in *this* column's band: declared here it occupies the
        // leading end of the sidebar, ahead of the platform's own sidebar toggle (measured: gear
        // `x=117…157`, toggle `161…204`). The same item declared `.navigation` lands in the *content* column
        // instead, and `.primaryAction` is the window's trailing edge, which is where the session buttons
        // are.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
        }
        // The register was refreshed when the popover opened; now that the rows are always on screen it is
        // refreshed when the column appears, and on every revision the shell sends (see `ShellClient.jobs`).
        .onAppear { client.refreshJobs() }
    }

    /// **Who this column is, at the head of it: the app's mark and name, with the search field under them.**
    ///
    /// Both were in the toolbar band — the mark as a toolbar item, the search field as `.searchable`'s
    /// sidebar accessory — and they are rows of this column now, in this order, because of what the band is:
    /// a strip 52 points tall that the whole window shares and one line deep. Two things stacked in it do not
    /// stack: the item's own height does not grow the band (measured — a 31-point item and an ordinary one
    /// occupy the same strip), and the wider item instead squeezes its neighbour. The mark and the platform's
    /// own sidebar toggle wanted 61 of this column's 208 points together, and the toggle came out 38 wide
    /// instead of 47. Anything placed *above* an accessory band fares no better — that is the titlebar's drag
    /// region, and there is no room between the two for a row of this column's own.
    ///
    /// Drawn rather than imported, from the same `Wei.Mark` geometry the icon is drawn from, so the two cannot
    /// drift. Its leading edge is `loose` (16) past the column's edge — the same 16 the rows' own content starts
    /// at (their 10 of row inset plus 6 of cell inset) — so the mark, the magnifier under it and the folders
    /// below that line up: measured, the mark and the magnifier both at `x=24` of a column starting at `x=8`,
    /// and the folder glyphs at 26 because theirs is centred in an 18-wide slot. The name follows at the mark's
    /// own width plus `tight`, which is what puts it over the rows' labels rather than a few points off them.
    private var identity: some View {
        HStack(spacing: Wei.Space.tight) {
            Wei.MarkView(height: 18)
            Text("wei Agent")
                .font(Wei.Font.control(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Wei.Space.loose)
        .padding(.trailing, Wei.Space.regular)
        .padding(.top, Wei.Space.cozy)
        .padding(.bottom, Wei.Space.tight)
        .accessibilityElement()
        .accessibilityLabel("wei Agent")
    }

    /// **The search field, placed by this column rather than by `.searchable`.**
    ///
    /// The control is the platform's own `NSSearchField` — the same one `.searchable(placement: .sidebar)`
    /// put in this column's accessory band — so the field renders the way the platform renders one over a
    /// sidebar, in every appearance. What changed is who places it.
    ///
    /// `.searchable`'s band sits *below* the titlebar and *above* this column's content: the sidebar's safe
    /// area starts under it (measured: the field at `y=61…89`, this column's content only from `y=98`), so
    /// nothing drawn in this column can ever be above the field — it would have to be drawn over the list
    /// and under a blur that belongs to the list's scroll view. Placing the control here is what makes the
    /// order the reader asked for expressible: identity, then search, then the list.
    ///
    /// **The field keeps the size and the insets the platform gave it**, so it is the same control in the same
    /// shape: 28 points tall, 10 in from this column's edge (the old accessory's `x=18` of a column starting at
    /// `x=8`), 9 above and below — which is why those three numbers are written as what they are rather than as
    /// the nearest token. What the reader asked for is the order around it, not a different field.
    private var searchField: some View {
        SessionSearchField(text: $search, placeholder: "Search all sessions")
            .frame(height: 28)
            .padding(.horizontal, Wei.Space.cozy + Wei.Space.tiny)
            .padding(.vertical, Wei.Space.cozy + 1)
    }

    /// Which project a running session belongs to, for the row that has room for one word of it.
    private func label(for row: SessionRow) -> String {
        workspaceLabel(of: row, in: client.groups)
    }

    /// Adding one, as the *first* row of the list it adds to.
    ///
    /// It was the last row, which put it below every project: at four projects it is below the fold, and a
    /// control the reader has to scroll to find is a control that is not there. Adding is a workspace action,
    /// so it stays in this list rather than in the File menu alone — the menu item stays, because a Mac
    /// reader looks for "New …" in File.
    ///
    /// The glyph is given a workspace row's own slot (`WorkspaceRow.glyphSlot`), so the plus sits over the
    /// folders and every label in the list starts at the same place.
    private var addWorkspace: some View {
        Button {
            actions.choosingFolder = true
        } label: {
            HStack(spacing: Wei.Space.tight) {
                Image(systemName: "plus")
                    .font(Wei.Font.control())
                    .frame(width: WorkspaceRow.glyphSlot, alignment: .center)
                Text("Add Workspace…")
                Spacer(minLength: 0)
            }
            .foregroundStyle(Wei.Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Ask, then remove: the dialog is the whole of what this decides.
    ///
    /// **Nothing is changed here**, the same rule the session list follows: the row stays until the shell
    /// says the store changed, because the shell is the side that reads the disk and the side that can
    /// refuse — a turn is running in that project, or a job it started is still alive. A list that removed
    /// the row from the click would have to put it back when the answer came, and a row that flickers is
    /// worse than one that leaves a moment late.
    ///
    /// The count is the row's own, which is the number the reader can see under that project in the middle
    /// column — the two must not be able to disagree (see `DeleteConfirmation.askAboutProject`).
    private func remove(_ group: SessionGroup) {
        DeleteConfirmation.askAboutProject(
            label: group.label,
            sessions: group.sessions.count
        ) { answer in
            switch answer {
            case .cancel:
                break
            case .keepFile:
                client.removeWorkspace(group.cwd, deletingSessions: false)
            case .removeFile:
                client.removeWorkspace(group.cwd, deletingSessions: true)
            }
        }
    }

}

/// The platform's search field, placed by the view that owns the query.
///
/// `NSViewRepresentable` rather than a hand-drawn capsule, and that is the whole point of it: this column
/// once drew its own field, and the version that replaced it with `.searchable` was right that a hand-rolled
/// `.glassEffect` pill over the sidebar's vibrant material renders *dark* (measured: fill 124–138 against the
/// sidebar's 220–247). What is reverted is only the *placement* — the control is the platform's, so the
/// bezel, the magnifier, the clear button, the appearance, and the focus behaviour are the platform's too.
///
/// The binding is followed in both directions: typing goes out on every keystroke (`sendsSearchStringImmediately`
/// is what makes this the live filter the list expects rather than one that waits for Return), and a value
/// set from outside — the clear button, or a future menu item — is written back into the field.
private struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        // The sidebar band's own height: `.regular` draws a 24-point bezel, and the field this replaced was
        // 28 (measured in that band), which is the size the platform gives a search field in a sidebar.
        field.controlSize = .large
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

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

/// One project: a folder, its name, how many sessions, and whether the open conversation is inside it.
///
/// The dot is kept from the two-column version and means more here than it did: the middle column shows
/// whichever project the reader is *browsing*, which is not necessarily the one holding the open
/// conversation — so without a mark, browsing away from a running session hides where it is.
private struct WorkspaceRow: View {
    let group: SessionGroup
    /// Called when this row's menu asks for the project to go. The dialog belongs to the column, for the
    /// same reason a session row's does: it is one question about one row, and the row is the thing that
    /// cannot draw a sheet on the window.
    let onRemove: () -> Void

    /// The width of a row's leading glyph slot — the same slot in the add row above, so every label in this
    /// list starts at the same place whatever its glyph measures. 18 is `folder`'s advance at the control
    /// size (measured: an 18×14 box for a 14-point glyph), and it is the widest of the two.
    static let glyphSlot: CGFloat = Wei.Icon.control + Wei.Space.tight

    var body: some View {
        HStack(spacing: Wei.Space.tight) {
            Image(systemName: "folder")
                .font(Wei.Font.control())
                .frame(width: Self.glyphSlot, alignment: .center)
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
        // **The only way out of this list, and it is one item.** A project can be removed and cannot be
        // renamed (`write_workspace`'s title has never been set — `macos/README.md` has it as future work),
        // so a menu with one entry is the honest size of it. It is reachable at all because a list with no
        // way to take a row out again is a list that only grows, and the only other way out is a shell and
        // an `rm -rf` of a directory the reader has to know the name of.
        .contextMenu {
            // No `role: .destructive` here, unlike the session row: what is destroyed is decided by the
            // checkbox in the dialog this opens, so red would promise a deletion that may not happen.
            Button("Remove Project…", action: onRemove)
        }
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
    @ObservedObject var client: ShellClient
    /// The project being browsed.
    let browsing: String
    /// What to draw, from the rules in `WeiModel` — computed one level up, where the titlebar can see the
    /// count too.
    let sections: [SessionSection]
    /// Whether what is drawn is a *result set* rather than this project's sessions. A fact about the query,
    /// and the query belongs to the window now (the field is in the workspace column), so this column is
    /// told it rather than deriving it from a binding it no longer holds.
    let searching: Bool
    /// Called when a search result is clicked, so the first column can follow the reader into the project
    /// they just reached into — otherwise the two columns would disagree about where they are.
    let onBrowse: (String) -> Void
    /// Called when a row's menu asks to rename it. The dialog itself belongs to the window: the same one is
    /// started from beside the conversation's own name.
    let onRename: (SessionRow) -> Void
    @State private var undoTimer: Task<Void, Never>?

    /// How long the offer to undo a delete stands. The same window the web UI uses, and for the same
    /// reason: an offer that stays until it is used is a row that never leaves.
    private static let undoWindow: Duration = .seconds(12)

    private var groups: [SessionGroup] {
        client.groups
    }

    /// Which project a session belongs to, and what to call it.
    ///
    /// The same answer the first column's rows give a project, which is what makes the subtitle under a
    /// session readable as a *name* rather than as a path. Qualified, because this type has a method of the
    /// same name: unqualified, the lookup would call itself.
    private func workspaceLabel(of row: SessionRow) -> String {
        WeiModel.workspaceLabel(of: row, in: groups)
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
        // **And no toolbar of its own any more.** Renaming the session on screen is at the window's trailing
        // edge, in `ConversationView`'s toolbar: `.primaryAction` is the window's trailing edge *whatever
        // column declares it* (measured: `x=872…917` of 921), so declaring it here never put it over this
        // column — and declaring it at this column's leading position (`.navigation`) displaced the window's
        // own title out of the column (`x=230…864` → `x=397…557`).
        //
        // Starting a session is declared there too and *also* drawn here, as this list's first row. The two
        // are one action for two moments: the toolbar item is what a reader reaches for with the pointer
        // already at the window's top, and the row is the control where they are looking when the list is
        // what told them the session they wanted is not there. The workspace column pairs its "Add
        // Workspace…" row with a File menu item the same way.
    }

    private var list: some View {
        List(selection: selection) {
            // Hidden while searching, because this column is then a *result set* spanning every project and
            // "New Session" would have no project to name — the row would promise an addition to the list
            // the reader is looking at, which is not the list it would add to.
            if !searching {
                newSession
            }
            ForEach(sections) { section in
                SwiftUI.Section {
                    ForEach(section.rows) { row in
                        SessionRowView(
                            row: row,
                            // The project is named on the row **only while searching**, and that is the one
                            // case where it is not a repetition: a result set spans every project, so a row
                            // that did not say which one it came from would be a row the reader had to check
                            // the first column for. Everywhere else this list is one project's sessions and
                            // the column's own heading already names it, so the line was a second copy of a
                            // fact one line above it — removed for that reason (it was added for the search
                            // case, which now asks for it rather than always paying for it).
                            workspace: searching ? workspaceLabel(of: row) : nil,
                            onRename: { onRename(row) },
                            onDelete: { delete(row) }
                        )
                        .tag(row.path)
                    }
                } header: {
                    // These are *time* headings — Today, Yesterday, Previous 7 Days — and they carry the same job
                    // Notes' month headings do: they are how a reader finds a session by when it was
                    // rather than by what it was called. Notes sets its own at the control size and
                    // semibold; the list style's default here is a caption, which measured 10 points of
                    // ink against Notes' 13.5 and read as a caption rather than as a heading.
                    Text(section.title)
                        .font(Wei.Font.control(.semibold))
                }
            }
            // **Only when there is something to put back.** A purge removes the file, and an Undo button
            // on a file that is not there is a button that lies — so the shell says which of the two
            // happened (`restorable`) and this draws nothing for the other. The row vanishing is the
            // report a purge gets; a line saying so would be a second sentence about a fact the reader
            // just watched happen.
            if let deleted = client.deleted, deleted.restorable {
                SwiftUI.Section {
                    UndoRow(label: deleted.label) {
                        client.restore(deleted.path)
                        undoTimer?.cancel()
                    }
                }
            }
        }
        .listStyle(.inset)
        // **No `.listRowInsets` here, and that is a finding rather than an omission.** On macOS those insets
        // do not move an `.inset` list's rows: measured (own-process accessibility tree, four ways — none, set,
        // `contentMargins(.horizontal,)`, both), the row, its cell and its text came out at exactly the same
        // frames every time. What *does* move the text is padding inside the row's own content
        // (`SessionRowView`), which is where the extra room the reader asked for lives. The highlight keeps the
        // inset the list style gives it (10 points), and the text under it starts one step in from that. The
        // vertical room is the same lever, and the row's own `padding(.vertical,.tiny)` is what makes its
        // highlight taller than its three lines.
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
        // The offer to undo a delete is the shell's — it is what the shell saw happen to the store — and
        // the *clock* on it is this side's: how long a line is worth drawing is a fact about a window.
        // Keyed on the path rather than on the tuple, which is not `Equatable`; two deletes of two
        // conversations are two clocks, and the second replaces the first.
        .onChange(of: client.deleted?.path) { _, path in
            guard let path else { return }
            offerShown(path)
        }
    }

    /// Adding one, as the *first* row of the list it adds to.
    ///
    /// The shape is `WorkspaceList.addWorkspace`'s, deliberately: the two columns are read as one window,
    /// and the single row in a list that *acts* rather than names should not be the one row drawn a
    /// different way. The glyph takes a workspace row's own slot (`WorkspaceRow.glyphSlot`) for the same
    /// reason — the two pluses land at the same x down the window.
    ///
    /// **No ellipsis in the label**, which is the one place this departs from "Add Workspace…": that one
    /// opens a chooser and asks for more, and this one starts a session where the reader already is. An
    /// ellipsis is a promise that a dialog follows.
    ///
    /// The eight points of padding are `SessionRowView`'s own, so this row's plus starts on the same edge as
    /// the session names below it. The label therefore sits one glyph-slot in from those names, and that is
    /// the intent rather than a mistake: this list has no glyph column, so the indent is what marks the row
    /// as a button among rows that are documents.
    private var newSession: some View {
        Button {
            client.newSession(in: browsing)
        } label: {
            HStack(spacing: Wei.Space.tight) {
                Image(systemName: "plus")
                    .font(Wei.Font.control())
                    .frame(width: WorkspaceRow.glyphSlot, alignment: .center)
                Text("New Session")
                Spacer(minLength: 0)
            }
            .foregroundStyle(Wei.Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Wei.Space.cozy)
        .help("New session in this project (⌘N)")
    }

    private var emptyMessage: String {
        if searching {
            return "No sessions match."
        }
        // Said without pointing at a control: the button that starts one is the first row of this list
        // (and the toolbar item at the window's trailing edge), and the sentence that used to be here
        // ("Type below to start one") pointed at a composer that lives in the next column over.
        return groups.contains(where: { $0.cwd == browsing })
            ? "No sessions in this project."
            : "No project selected."
    }

    /// Ask, then delete: the dialog is the whole of what this decides.
    ///
    /// **Nothing is changed here.** The row stays until the shell says the file moved — the list that
    /// arrives right after a delete is the shell's own account of what is in the store, and one that
    /// guessed at it would have to take the guess back when the delete was refused. The offer to undo
    /// comes back the same way, as a `deleted` event, rather than being drawn from the click.
    private func delete(_ row: SessionRow) {
        DeleteConfirmation.ask(label: row.label) { answer in
            switch answer {
            case .cancel:
                break
            case .keepFile:
                client.delete(row.path)
            case .removeFile:
                // The one act in this program that cannot be undone. It is the checkbox, in the dialog
                // the reader is still looking at when they tick it.
                client.purge(row.path)
            }
        }
    }

    /// The offer has arrived: give it the window it stands for, and then take it down.
    ///
    /// A button that waits forever is a button that is still there tomorrow, and by then it is not an undo
    /// any more — it is a piece of the interface nobody can account for. The clock is this side's because
    /// how long a line is worth drawing is a fact about a window; the offer itself is the shell's, and this
    /// only asks for it to expire.
    private func offerShown(_ path: String) {
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            // Only when this is still the offer that was up: a second delete replaces the first, and its
            // own clock must not be cut short by the one it replaced.
            if client.deleted?.path == path { client.undoOfferExpired() }
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
/// Drawn only for a delete that can be undone (`DeletedSession.restorable`): the file is renamed rather
/// than removed, so this is a convenience on top of a recovery that was already possible — but a reader
/// who deleted the wrong row should not have to open Finder to find out.
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
/// **Two lines, and each is a question the reader is asking**: *which* conversation (the label) and *when* it
/// was last used. A third line appears only when it has something to say that the two do not: *where* the row
/// lives, which is a fact the row has to carry **only as a search result** — these rows are one project's
/// sessions and the window's title names that project, so the line was a second copy of a fact one line above
/// it — and *that a turn is in flight* in it, which nothing else on screen says.
///
/// The name is weighted rather than coloured to make it the top line. It was 15 semibold for a while, and
/// that read as a *heading*: three quarters of the way to the window's own section headings (13 semibold) and
/// over them on the second look. Control weight at control size over caption is the hierarchy the first
/// column already uses for a project and its count, which is what makes the two lists read as one system.
private struct SessionRowView: View {
    let row: SessionRow
    /// The project this session lives in, as the first column names it — `nil` unless the list is a result
    /// set, where which project a row came from is a fact the row has to carry itself.
    let workspace: String?
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Wei.Space.tiny) {
            Text(row.label)
                .font(Wei.Font.control(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            // **The second line always exists and always holds the same kinds of things**, which is a
            // requirement rather than a style: a `List` row measures itself when it is *built*, and a row whose
            // height changes in place is never measured again. Measured, twice — a turn starting added a line
            // and the time was clipped by the row's own bottom edge (`y=168…183` inside a row ending at `y=175`),
            // and a search result did the same thing (`y=166…181`). Same identity, same view, stale height.
            //
            // So everything after the name goes on one line: the project (a search result only — this list
            // spans projects then, and the window's title names it otherwise), then the time, then the status.
            // A fixed height tall enough for a third line would have worked too and would have spent those
            // points on every quiet row to pay for the rare busy one.
            HStack(spacing: Wei.Space.tight) {
                if let workspace {
                    Text(workspace)
                        .font(Wei.Font.caption())
                        .foregroundStyle(Wei.Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                        .font(Wei.Font.caption())
                        .foregroundStyle(Wei.Palette.tertiary)
                }
                Text(sessionAgeText(modified: row.modified, now: Date(), calendar: .current))
                    .font(Wei.Font.caption())
                    .foregroundStyle(Wei.Palette.tertiary)
                if row.running {
                    // A turn in flight *in this session*. With more than one conversation able to run at once
                    // this is a per-row fact rather than a statement about the window, which is exactly what the
                    // shell sends it as — and it is the only state the wire carries per row, so it is the only
                    // one drawn.
                    StatusChip(text: "Running")
                        .font(Wei.Font.caption())
                }
            }
        }
        // A control's height, so the shortest row — a name and a time — is not a tight box drawn around two
        // lines of type. **The height does not depend on what is in the row**, which is a requirement rather
        // than a preference here: see the note on the last line — a row that grows in place is a row the list
        // does not re-measure.
        .frame(minHeight: Wei.Control.row, alignment: .leading)
        // Room inside the row, since the platform's list will not take it on the outside: see the note on the
        // list in `SessionList`. Eight a side is what puts this column's text on the **same left edge as the
        // transcript's own** — the transcript's content is padded by `Wei.Space.section` (24) from its column,
        // and a row here is already 16 in (10 of highlight inset, 6 of cell inset), so 8 more makes the two
        // columns' text line up down the window. The vertical step keeps the highlight from looking like a box
        // drawn tight around the type.
        .padding(.horizontal, Wei.Space.cozy)
        .padding(.vertical, Wei.Space.tiny)
        .help(row.path)
        .contextMenu {
            // Renaming is offered on every row and refused by the shell for a session that is not open:
            // the log of a session this process is not holding must not be rewritten from here, and a menu
            // item that vanishes with the selection is a menu item nobody finds.
            Button("Rename…", action: onRename)
            Divider()
            // The question — including the one about the file — is `DeleteConfirmation`'s: an `NSAlert`,
            // because it is the one dialog on this system that takes a checkbox beside its buttons.
            Button("Delete Session", role: .destructive, action: onDelete)
        }
    }
}

/// Ask before deleting a session, with the one extra question a delete can have.
///
/// **An `NSAlert` rather than `.confirmationDialog`, and only because of the checkbox.** That checkbox is
/// the reader's answer to "and the file?" — unticked, the conversation leaves the list and its log is
/// renamed aside, which is the recoverable thing this app has always done; ticked, the log is removed,
/// which is the only act in this program that cannot be undone. The question belongs in the dialog that
/// asks whether to delete at all: a second dialog after it would be two questions for one decision, and a
/// second *button* ("Delete and Remove") makes the reader compare two labels to find the difference.
///
/// The same dialog, and the same checkbox, asks about a whole project (`askAboutProject`): the row and the
/// conversations under it are two sizes of one act, and the thing that made a checkbox necessary — an
/// irreversible outcome that a plain confirmation cannot express — is the same in both.
///
/// SwiftUI has no equivalent to offer. `confirmationDialog`'s builders take views, but the dialog is a
/// list of buttons — nothing else in it arrives — and `dialogSuppressionToggle` is a different question
/// ("do not ask me again"). So this is AppKit, and it is the platform *dialog* rather than a platform
/// view: the same category as the menu bar and the pasteboard in ADR-0008, and SwiftUI's own alerts are
/// NSAlerts underneath. The tokens are not involved — the platform draws this whole thing, title bar
/// included — which is the same reason the system's own "Delete Note?" needs no design system.
@MainActor
enum DeleteConfirmation {
    /// What the reader chose.
    ///
    /// Named for the *file*, which is the thing at stake: a session's log is one file and a project's is a
    /// directory of them, and "keep the file" covers both.
    enum Answer {
        case cancel
        /// Out of the list; what was there is renamed aside and can be put back.
        case keepFile
        /// Out of the list and off the disk. Nothing can put it back.
        case removeFile
    }

    /// What one of these dialogs says, as data.
    ///
    /// Split out of `present` so the sentences can be checked without a window, which is the same split
    /// `Sketch` makes for the sketchpad and for the same reason: a dialog that is drawn wrong and a dialog
    /// that *says* the wrong thing are different mistakes, and only the first one needs a screen. These
    /// words are the whole of what tells a reader whether their code is at risk, so they are worth a test
    /// rather than an eyeball.
    struct Prompt: Equatable {
        let title: String
        let body: String
        /// The first button, which is Return. The second is always Cancel, and is not stored because it is
        /// never the difference between two dialogs.
        let confirm: String
        /// The checkbox beside the buttons, or `nil` when there is nothing for one to decide.
        let checkbox: String?
    }

    /// What the question about one conversation says. Every delete has this checkbox — the file is always
    /// there to be removed.
    static func prompt(label: String) -> Prompt {
        Prompt(
            title: "Delete “\(label)”?",
            body: "The conversation leaves the list.",
            confirm: "Delete",
            checkbox: "Also delete the file on disk (cannot be undone)"
        )
    }

    /// The same about one project.
    ///
    /// The count goes in both sentences, and the caller passes `SessionGroup.sessions.count` — the number
    /// of rows the reader can see under that project — so the dialog cannot disagree with the sidebar it
    /// just came from.
    ///
    /// **The body says the folder is not touched**, and that is the sentence this dialog exists for: the
    /// row is named after a directory and the button says "Remove", so without it a reader is entitled to
    /// think their source tree is about to go. It is said first, before the part about the conversations.
    ///
    /// **No checkbox for a project with nothing in it.** The checkbox in the session dialog was added
    /// because a loss the dialog would otherwise announce can be turned into a bigger one; with no
    /// conversations there is no such loss, and "Also delete its 0 conversations" would be a control that
    /// cannot do anything. `nil` is what the caller draws no accessory view for.
    static func projectPrompt(label: String, sessions: Int) -> Prompt {
        let conversations = sessions == 1 ? "conversation" : "conversations"
        return Prompt(
            title: "Remove “\(label)”?",
            body: sessions == 0
                ? "The project is a folder on disk and is not touched."
                : "The project is a folder on disk and is not touched. Its \(sessions) \(conversations)"
                    + " leave the list.",
            confirm: "Remove",
            checkbox: sessions == 0
                ? nil
                : "Also delete its \(sessions) \(conversations) (cannot be undone)"
        )
    }

    /// The question about one conversation.
    static func ask(label: String, then answer: @escaping (Answer) -> Void) {
        present(prompt(label: label), then: answer)
    }

    /// The question about one project, whose checkbox is about every conversation in it.
    static func askAboutProject(
        label: String,
        sessions: Int,
        then answer: @escaping (Answer) -> Void
    ) {
        present(projectPrompt(label: label, sessions: sessions), then: answer)
    }

    /// Put the question up, and answer on the way back.
    ///
    /// A sheet on the window the reader is looking at, and a free-standing alert only when there is no
    /// window to hang it on (a test, or a launch before the window exists) — an app-modal panel that
    /// covers every window for a question about one row would be worse than the fallback is cheap.
    private static func present(_ prompt: Prompt, then answer: @escaping (Answer) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.alertStyle = .warning
        alert.informativeText = prompt.body
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: "Cancel")

        var remove: NSButton?
        if let checkbox = prompt.checkbox {
            let box = NSButton(checkboxWithTitle: checkbox, target: nil, action: nil)
            // **Off**, which is the default this dialog exists to preserve: the recoverable removal is what
            // the app has always done, and a reader who does not read the checkbox still gets that.
            box.state = .off
            alert.accessoryView = box
            remove = box
        }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            // The first button is the action, and the checkbox only *modifies* it: a ticked box with a
            // cancelled dialog removes nothing, which is what "Cancel" has to mean.
            guard response == .alertFirstButtonReturn else {
                answer(.cancel)
                return
            }
            answer(remove?.state == .on ? .removeFile : .keepFile)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// What the shell is, what it has said, and a box to answer it in.
///
/// **The name of the conversation is the only heading, and it is a toolbar item rather than a band.** This
/// column once opened with an opaque band — the name, the model, and the working directory on a material with
/// a hairline under it, running edge to edge — and that is what was removed: a band is the mark of a *panel*,
/// which is why the window read as a sidebar and an everything-else that happened to be split rather than as
/// three columns. A line of type in the toolbar's own row is not that: no background, no rule, and the
/// conversation goes soft behind it as it scrolls under the row.
///
/// The other two facts the band carried are still gone, and deliberately: the model is on the composer's
/// own picker, next to the message it will answer; the directory is the project the middle column is
/// listing. Every state the band reported — starting, no key, a turn that failed — is the composer's
/// status line, which says it under the field where a reader is looking anyway (`ShellClient.blocked`).
private struct ConversationView: View {
    @ObservedObject var client: ShellClient
    /// What the window is in the middle of: the composer's `+` menu and the Edit menu both write the
    /// picture sheet through this, so both have to be looking at the same one.
    @ObservedObject var actions: WindowActions
    /// The project the toolbar's plus starts a session in: the one this window is browsing, resolved
    /// (`RootView.browsed`), so it is the same value the session list beside it is listing.
    ///
    /// Passed in rather than read from `client.currentWorkspace`, and that is the whole fix: the two
    /// disagree exactly while the reader is browsing a project they have not opened a session in, which
    /// is when "New Session" was landing in the wrong one.
    let browsing: String
    /// Starts the window's rename dialog for the session on screen. Beside the name, because that is the
    /// thing it changes.
    let onRename: () -> Void
    /// Shared with the transcript, which decides when it keeps up, and with the send button, which is
    /// the one thing that overrides that decision.
    @StateObject private var scroll = TranscriptScroll()

    /// How tall the bar over the transcript is, as laid out. See `ConversationTitleHeightKey` for why the
    /// margin below the toolbar has to be told about it rather than recomputing it.
    @State private var titleHeight: CGFloat = 0

    /// How far the title block is lifted, so that it is centred on the toolbar's centre line rather than
    /// sitting on the line below it.
    ///
    /// A safe-area bar is drawn *below* the toolbar, and the platform centres its own items at 26 of the
    /// toolbar's 52 points (`Wei.Control.toolbar`). So the lift is the centring itself — the block's centre
    /// moved onto that line, `toolbar / 2 + height / 2` — and it is applied as an `offset`, so the bar keeps
    /// the height the transcript has to clear.
    ///
    /// **It was the constant 41, measured on a running window** (by reading the AX frames of the toolbar's
    /// button and of this text, which is how "the same row" was checked). This formula gives that same 41
    /// back for the one-line block it was measured on, and it is the *reason* for 41 rather than a copy of
    /// it: the copy stayed 41 when the project was added under the name, which left the name on the toolbar's
    /// line and dropped the project 18 points below it, out over the transcript.
    private var titleLift: CGFloat { Wei.Control.toolbar / 2 + titleHeight / 2 }

    /// Room at the trailing end for the toolbar's own controls — measured, one session button occupies 49
    /// points of the window's trailing edge, and *both* of them are on this row once the bar is lifted (the
    /// new-session plus and the rename pencil, which together measured 835…917 of 921). This is also where a
    /// long name gets its ellipsis, so the two never touch.
    private static let titleClearance: CGFloat = 104

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
            onLoadEarlier: { client.loadEarlier(client.conversation.oldestRowID) },
            scroll: scroll,
            // The first row has to clear the toolbar *and* this column's own bar.
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
                    actions: actions,
                    enabled: client.state != .starting,
                    // A prompt went out, so the reader is asking rather than reading back: the transcript
                    // follows again from here, whatever it had been told before.
                    onSent: { scroll.promptSent() },
                    onStop: { client.stop() }
                )
            }
            // **What this conversation is called, and the pencil that renames it, on one line.**
            ///
            /// The name says something the window's title does not: that one names the *list* the middle
            /// column is showing (which project, how many sessions), because a window has one title and the
            /// list is what it is about. A reader who has scrolled into an answer is looking at one
            /// conversation, and the name of it — with the way to change it — belongs at the head of it.
            ///
            /// The repetition is deliberate: one is the name of a thing in a list of things, this one is the
            /// name of the thing on screen. (What *was* a mistake, written down at the top of this column's
            /// history, is the version that made the window's title and this heading say the same words.)
            ///
            /// **A bar, not a toolbar item.** Both were tried and measured. A `ToolbarItem` holds one thing
            /// cleanly — a title *or* a button — and a second item in this column's region makes the platform
            /// re-flow the row: the title left the column and landed over the *list* (`x=230…397`), and the
            /// window's own title was pushed from `x=230…864` to `x=397…557`. A bar is drawn by this view, so
            /// the two controls are laid out by `HStack` and nothing else moves.
            ///
            /// **And it is lifted onto the toolbar's centre line** (`titleLift`), so the name and the pencil
            /// share the row the window's own controls are on rather than sitting a line below them.
            ///
            /// What is kept either way: the blur. `safeAreaBar` insets the safe area, and
            /// `scrollEdgeEffectStyle(.soft, for: .top)` fades what passes beneath — so the conversation goes
            /// soft behind the name as it scrolls under it.
            .safeAreaBar(edge: .top, alignment: .leading) {
                if let name = sessionName {
                    VStack(alignment: .leading, spacing: Wei.Space.tiny) {
                        Text(name)
                            .font(Wei.Font.title())
                            // One line, and the end of it if it does not fit: a question can be long, and a
                            // title that wraps to four lines is a title that has become the first paragraph.
                            // The tail rather than the middle, so what the reader sees is how the question
                            // *begins* — which is how they would recognize it in the list — and so the
                            // ellipsis is where they expect one. The width has to be flexible for that:
                            // truncation happens when there is a limit to truncate against.
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // The whole question on hover, since the row may be showing a third of it.
                            .help(name)
                        // **Which project this conversation is in, in small type under its name.**
                        //
                        // The middle column says it too, and the window's title says it for the *list*; the
                        // reason to say it a third time is the reader this column is for. The middle column is
                        // a list of what to read next, and it scrolls away — a reader who has been reading one
                        // answer for minutes has the name of the thing they are reading in front of them and
                        // nothing else. Same shape as the settings panes: the window's title names the list,
                        // the second line names the thing.
                        //
                        // Empty for a session the store has not listed yet (one created a moment ago), in
                        // which case the name simply stands alone as it did before.
                        if let workspace = sessionWorkspace {
                            Text(workspace)
                                .font(Wei.Font.caption())
                                .foregroundStyle(Wei.Palette.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(workspacePath)
                        }
                    }
                        // **Air above the name — and the number here is twice what it moves.**
                        //
                        // The block is centred on the toolbar's centre line (`titleLift`), so padding inside
                        // it is paid for twice over: half of it pushes the type down, and the other half makes
                        // the block taller, which pulls it back up by as much as it pushed down. Eight points
                        // therefore reads as four. Measured: the name's line box moves from `y=5` — level with
                        // the top of the traffic lights, which is what "touching the window's top edge" was —
                        // to `y=9`, and the project line below it stays inside the band, at `y=35…50`.
                        .padding(.top, Wei.Space.cozy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Wei.Space.section)
                        // Room at the trailing end for the toolbar's own buttons, which are on this row once the
                        // bar is lifted: measured, one is 49 points of the window's trailing edge and there are
                        // two of them.
                        .padding(.trailing, Wei.Space.section + Self.titleClearance)
                        .padding(.vertical, Wei.Space.tiny)
                        // `offset` rather than padding: this moves what is *drawn* without changing the bar's
                        // height, and that height is what the first row of the conversation has to clear.
                        .offset(y: -titleLift)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ConversationTitleHeightKey.self,
                                    value: geometry.size.height
                                )
                            }
                        )
                }
            }
            .onPreferenceChange(ConversationTitleHeightKey.self) { height in
                titleHeight = height
            }
        // **Both session actions live here, as ordinary toolbar items**: rename the one on screen, and start a
        // new one. `.primaryAction` is the window's trailing edge *whatever column declares it* — measured, a
        // button declared over the session list still lands at `x=872…917` of 921 — so this is where they go;
        // and declaring them together keeps one row's arrangement in one place. Hand-drawn buttons in the bar
        // above were tried for the pencil and reverted: a toolbar item is the platform's own control, with its
        // own style, spacing and behaviour, and a second one does not squeeze the title out of its column any
        // more now that the title is a drawn bar rather than a toolbar item.
        //
        // What used to be here instead — the running-jobs register and Settings — is in the workspace column,
        // which is where the web UI keeps both and where they describe something that spans the window rather
        // than this column: jobs run in *any* session, and settings belong to the app.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    client.newSession(in: browsing)
                } label: {
                    // A plus rather than `square.and.pencil`. The pencil-square is the *document* metaphor
                    // (Notes' "new note"), and in this window it reads as "write", next to a pencil that
                    // already means "rename". A plus is the one glyph that says one thing here: this adds a
                    // session to the list. Renaming keeps the pencil, which is now unambiguous.
                    Label("New Session", systemImage: "plus")
                }
                .help("New session in this project (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRename) {
                    Label("Rename Session", systemImage: "pencil")
                }
                .help("Rename this session")
                // Nothing to rename until the store has listed the session: a session created a moment ago has
                // no name yet, and a pencil that opened a dialog on nothing would be a lie.
                .disabled(sessionName == nil)
            }
        }
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

    /// Which project the conversation on screen is in, as the first column names it. `nil` while the store
    /// has not listed the session, which is why the name can stand alone.
    private var sessionWorkspace: String? {
        guard let session = client.currentSession else { return nil }
        let label = workspaceLabel(of: session, in: client.groups)
        return label.isEmpty ? nil : label
    }

    /// The path behind that name, for the tooltip: two projects can share a name and the name is all the row
    /// has room for — the same reason the first column's rows are helped by their own paths.
    private var workspacePath: String { client.currentWorkspace }
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

    /// Which project this window is browsing, mirrored from `RootView.browsing` so that the menu bar's
    /// "New Session" (⌘N) names the same project the toolbar's plus and the list's own row do.
    ///
    /// The only thing here that travels *the other way* — the view tree telling the app — and that is
    /// the point of it: which project the reader is looking at is a window fact (see `RootView.browsing`
    /// for why the shell must not own it), so a command defined beside the app has no other way to know
    /// it. The alternative, `client.currentWorkspace`, is the project of the session *on screen*, and
    /// that is precisely the answer this bug came from: ⌘N under project B would create in project A,
    /// while the tooltip on the button it shares a command with promises "New session in this project".
    ///
    /// Empty is a real value, not a missing one: it is a window with nothing to name yet, and the shell
    /// answers it with the project on screen — which is the right answer when the reader has not chosen
    /// one either.
    @Published var browsing = ""

    /// The picture sheet, if one is open: blank paper, or a screenshot to mark up.
    ///
    /// Owned here for the same reason as the folder chooser, and it is the same argument twice: the
    /// composer's `+` menu and the Edit menu both open it, and the two must be answering one question
    /// rather than each remembering their own. The screenshot commands are on `WindowActions` too
    /// (see `Screenshot.swift`), because a command written twice is a command that can come to mean
    /// two things.
    @Published var picture: PictureSheet?
    /// A screenshot that did not happen. `nil` when there is nothing to say — which includes the
    /// reader having cancelled one, deliberately: see `ScreenshotOutcome`.
    @Published var shotTrouble: ScreenshotTrouble?
}

/// Where the transcript is scrolled to, and whether it should keep up with what arrives.
///
/// A reference type because two views that do not own each other have to agree about it: the
/// transcript measures and decides, and the composer's send is the one thing that overrides.
///
/// The decision itself is `ScrollFollow` in `WeiModel` — this holds the geometry and the reader's
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

    // ── paging ─────────────────────────────────────────────────────────────
    //
    // The transcript arrives a page at a time (newest first), and scrolling to the top asks for the
    // page before it. Two things make that not jump under the reader, and both are here rather than in
    // the view body because they are decisions with numbers in them:
    //
    // - **when to ask**: near the top, but not *at* it — a request that only fires once the reader is
    //   already staring at the first row arrives a beat too late to hide;
    // - **where to keep the eye**: the height the transcript gains when the page lands, added back to
    //   the offset. The view does the arithmetic (it is the only side that knows the geometry); this
    //   holds the intent.

    /// Whether a page has been asked for and not yet arrived.
    ///
    /// One request in flight at a time. A scroll view reports the top on every frame it stays there, and
    /// each of those would otherwise be another request — for a page the shell would answer by sending
    /// the same rows again.
    var awaitingPage = false

    /// How close to the top counts as "ask for more". A screen's worth, so the page is in flight while
    /// the reader still has something to read.
    private let pageTrigger: CGFloat = 600

    /// Whether the top of the transcript is close enough to ask for the page before it.
    ///
    /// Three conditions, and the second one is the one a measurement put there:
    ///
    /// - `hasEarlier` is the shell's own answer about whether such a page exists, which is why a session
    ///   that fits in one page never arms this — nothing asks for rows that are not there;
    /// - **the reader is not following** — they have scrolled up, which is the transcript's existing
    ///   notion of "they are reading something above". Starting a page from "the offset happens to be
    ///   near the top" instead was measured loading **three pages in a row on a switch**: the old
    ///   session's offset is near zero when the new one's rows arrive, so the trigger fired before the
    ///   landing at the end, and each page it added kept the offset near the top for the next one. The
    ///   follow rule and this one were also fighting over the same revision — one trying to put the
    ///   reader at the end, the other adding rows above them;
    /// - one request in flight at a time, because a scroll view reports the same offset on every frame
    ///   it stays there and each report would otherwise be another request.
    func shouldLoadEarlier(offset: CGFloat, hasEarlier: Bool) -> Bool {
        guard hasEarlier, !awaitingPage, !follow.following else { return false }
        return offset < pageTrigger
    }

    /// A page was asked for.
    func pageRequested() {
        awaitingPage = true
    }

    /// A page arrived (or the shell answered with nothing, which is also an answer).
    func pageArrived() {
        awaitingPage = false
    }
}

/// The two numbers the transcript's paging is decided from: where it is scrolled to, and how tall it is.
///
/// A named pair rather than a tuple because `onScrollGeometryChange` needs an `Equatable` carrier and
/// because the two travel together — the follow rule reads the bottom, the paging rules read the top and
/// the height, and all three are the same geometry.
private struct Geometry: Equatable {
    var offset: CGFloat
    var height: CGFloat
}

/// Where the bottom of the transcript is, reported to the view that decides whether to follow.
private struct TranscriptBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// How tall the bar over the transcript is, including its own padding.
///
/// Needed because two mechanisms each know half of it: the bar insets the *safe area*, while what keeps the
/// transcript's first row from being hidden for good is a content margin measured from the window's top
/// edge. Adding one without the other put the title on top of the first line, which a screenshot caught.
private struct ConversationTitleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// And how tall the window onto it is.
private struct TranscriptViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// How tall three lines of the reasoning font are, as the text view lays them out.
///
/// The live peek in `ThinkingRow` is a fixed-height box anchored to its end, so something has to say
/// how tall three lines are — and the answer has to be the text system's, not a font's: `NSFont`'s
/// ascender and descender are the same numbers only by accident, and the one number that matters is
/// how far apart the platform puts two baselines. It is measured from a hidden probe rather than
/// computed, which is what `ConversationTitleHeightKey` does one column over and for the same reason.
private struct PeekHeightKey: PreferenceKey {
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
    /// The transcript as turns — the grouping rule lives in `WeiModel`, where it is tested.
    private var turns: [Turn] { WeiModel.turns(of: conversation.rows) }

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
    /// Ask the shell for the page of rows before the oldest one on screen. Called when the reader
    /// scrolls near the top and the shell says there is more (`Conversation.hasEarlier`).
    let onLoadEarlier: () -> Void
    @ObservedObject var scroll: TranscriptScroll

    /// How far below the window's top edge the first row must start — the toolbar, plus whatever bar this
    /// column draws over the top of the scroll view. The view above this one knows its own bar and passes
    /// the sum; `Wei.Control.toolbar` is the answer for a column that draws none.
    var topMargin: CGFloat = Wei.Control.toolbar

    /// The app-wide scroll monitor, installed while the transcript is on screen. See `onAppear`.
    @State private var monitor: Any?

    /// Where the transcript is scrolled to, and how tall it is — as state, because the paging decision
    /// is made from them and a decision cannot be made from a callback.
    ///
    /// `ScrollGeometry` rather than the preference pass the follow rule uses: this wants the offset and
    /// the content size *as they change*, which is what `onScrollGeometryChange` reports, and it wants
    /// them before the reader reaches the very top.
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    /// What the content height was when the last page was asked for, so the height it gains when the
    /// page lands can be told from a re-layout of the same rows.
    @State private var heightAtRequest: CGFloat = 0
    /// The scroll position, held so a page can be landed on without moving the reader's eye.
    @State private var scrollTarget = ScrollPosition(idType: String.self)

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
                    if !conversation.loaded {
                        // **An empty column is indistinguishable from a broken one.** The reader has
                        // switched conversations and the shell is still reading the log — the rows are
                        // on their way, but nothing on screen says so, and the same blank frame is what
                        // a failed load would look like. One line costs nothing and answers the only
                        // question the reader has at that moment.
                        //
                        // Not a spinner: the wait is measured in milliseconds (see
                        // `Conversation.loaded`), and a spinner that appears and vanishes inside one
                        // run-loop turn reads as a flicker. The sentence is what the reader needs; the
                        // motion would only be the second thing to look at.
                        OpeningNotice()
                    }
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
                // **Rows belong to their conversation, and the ids alone do not say so.** The shell counts
                // history ids per session (`h-1`, `h-2`, … in `macos/appffi/sessions.mbt`), so two
                // conversations hand this list the *same* identities — and SwiftUI keeps `@State` for an
                // identity it considers unchanged, which is how a reasoning block the reader opened in one
                // conversation comes back open in another. Keying the stack by the session makes each
                // conversation's rows their own views, so nothing carries across. It costs a rebuild on a
                // switch, which is what a switch is.
                //
                // On the stack rather than on the `ScrollView` above it, deliberately: the scroll view and
                // its offset are the *column's* state, and the landing at the end of a newly-opened
                // conversation is driven from here (`onChange(of: session)` below). Giving the scroll view
                // a new identity too would take that mechanism with it.
                .id(session)
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
            // The geometry, as state. `onScrollGeometryChange` reports offset *and* content size, which
            // are exactly the two numbers both paging decisions are made from.
            .onScrollGeometryChange(for: Geometry.self) { geometry in
                Geometry(offset: geometry.contentOffset.y, height: geometry.contentSize.height)
            } action: { _, now in
                offset = now.offset
                contentHeight = now.height
                if scroll.shouldLoadEarlier(offset: now.offset, hasEarlier: conversation.hasEarlier) {
                    heightAtRequest = now.height
                    scroll.pageRequested()
                    onLoadEarlier()
                }
            }
            // **A page lands without the reader's eye moving.** Prepending rows above the viewport makes
            // the content taller, and a scroll view keeps its offset — so the text the reader was reading
            // slides down by exactly the height that was added. The fix is arithmetic rather than a
            // `scrollTo`: add the delta back to the offset, in a scroll position, which is the only way to
            // write an offset directly (`ScrollViewReader` can only jump to an id).
            //
            // Guarded on "the rows grew while a page was in flight" — a revision with no page outstanding
            // is a live turn appending at the *bottom*, where moving the offset would fight the follow
            // rule instead of helping it.
            .scrollPosition($scrollTarget)
            .onChange(of: conversation.rows.count) { old, new in
                guard scroll.awaitingPage, new > old else { return }
                let delta = contentHeight - heightAtRequest
                scroll.pageArrived()
                guard delta > 0 else { return }
                // The new offset, in the same coordinate space `contentOffset.y` is read in.
                scrollTarget.scrollTo(y: offset + delta)
            }
            .onChange(of: revision) { _, _ in
                guard scroll.following, let end = WeiModel.endOf(conversation.rows) else { return }
                // Deferred by one turn of the run loop, for the same reason the switch below is: a row that
                // has just arrived has not been built yet, and scrolling to a row that is not there does
                // nothing. `LazyVStack` is what makes this matter — it builds what is near the viewport.
                DispatchQueue.main.async { proxy.scrollTo(end, anchor: .bottom) }
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
                // **The end is a *turn*, not the last row**, and that distinction is the whole of a bug: the
                // view registers turn ids, `scrollTo` does nothing at all for an id nothing answers to, and
                // after any answer the last row is a piece of that answer. So the switch landed at the top
                // of the new conversation and stayed there. `endOf` is the rule, tested in `WeiModel`.
                //
                // **The rows have to be here by now, and that is the shell's half of this.** This runs on
                // the frame that changes which session is on screen, and it returns immediately for an
                // empty transcript — so a shell that says "this session is on screen" before it says what
                // is *in* the session hands this one shot at a transcript with nothing in it, and the
                // reader lands at the top of a conversation they have not read (which is what happened:
                // it is half of "it goes white and I have to scroll"). `say_open` sends the rows first for
                // exactly this reason; the pairing is asserted in `TranscriptRoutingTests`.
                guard let end = WeiModel.endOf(conversation.rows) else { return }
                // After the rows are laid out: scrolling to a row the view has not built yet does nothing.
                DispatchQueue.main.async { proxy.scrollTo(end, anchor: .bottom) }
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
///
/// **A turn that is still running is the exception**, and it is the one the transcript's readability
/// turns on: its work is drawn open (a fold a reader has to open to watch the agent work would be
/// opened on every turn), and *open* is not the same as *everything*. A live turn shows the call it is
/// on and one line for the calls behind it — see `WeiModel.liveWork` for the rule and `LiveWorkTests`
/// for the cases.
private struct TurnView: View {
    let turn: Turn
    /// Whether this turn is still arriving. A live turn draws its work open, one call at a time.
    let live: Bool

    @State private var workOpen = false
    /// Whether the live fold — the calls this turn has already finished — is open.
    @State private var earlierOpen = false

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
                    work
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

    /// The work, drawn differently while the turn is running.
    ///
    /// A finished turn shows every row where it stands: a reader who opened this fold has decided to
    /// read the working out, and the order it happened in is the record. A live one shows the newest
    /// call and a fold over the finished ones, because the reader is watching rather than reading.
    @ViewBuilder
    private var work: some View {
        let plan = liveWork(turn.work)
        VStack(alignment: .leading, spacing: Wei.Space.regular) {
            if live {
                ForEach(plan.items) { item in
                    switch item {
                    case let .row(row):
                        RowView(row: row)
                    case .fold:
                        earlierCalls(plan)
                    }
                }
            } else {
                ForEach(turn.work) { row in
                    RowView(row: row).id(row.id)
                }
            }
        }
    }

    /// The calls a live turn has already finished, behind one line.
    ///
    /// It opens onto the rows themselves rather than a summary of them — the point of opening a fold
    /// over tool calls is reading what the tools said, and a second summary of what is already a
    /// summary is a click that buys nothing.
    private func earlierCalls(_ plan: LiveWork) -> some View {
        VStack(alignment: .leading, spacing: Wei.Space.regular) {
            Button {
                earlierOpen.toggle()
                // Opening these is asking to read the working out, so the turn's own fold stays open
                // when the turn ends — otherwise the thing they just opened is taken away from them
                // the moment the answer arrives.
                if earlierOpen { workOpen = true }
            } label: {
                HStack(spacing: Wei.Space.tight) {
                    Image(systemName: earlierOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: Wei.Icon.inline - 2, weight: .semibold))
                    Text(plan.label)
                        .font(Wei.Font.caption())
                }
                .foregroundStyle(Wei.Palette.secondary)
            }
            .buttonStyle(.plain)
            .help(earlierOpen ? "Hide these calls" : "Show these calls")
            if earlierOpen {
                VStack(alignment: .leading, spacing: Wei.Space.regular) {
                    ForEach(plan.folded) { row in
                        RowView(row: row).id(row.id)
                    }
                }
                // Indented, so the fold reads as holding them rather than as another row beside them.
                .padding(.leading, Wei.Space.regular)
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

/// What the transcript says while the shell is still reading a session's log.
///
/// The state it exists for is short — measured, about 150ms for a 30MB conversation — and that is
/// exactly why it matters: it is long enough to see, and what the reader sees without this is the same
/// empty column a broken load would leave. A blank column is indistinguishable from a list that has not
/// loaded, which is the rule the sidebar's own empty state is written to (`WeiModel/Sessions.swift`).
///
/// The wording follows the same advice: name what is happening, not that something *is* happening.
/// "Opening…" is the reader's own act (`docs/design-system.md`'s plain-language rule); "Loading…"
/// would describe the machine. No ellipsis-abuse and no exclamation — it is a sentence about the
/// conversation, in the place the conversation will be.
///
/// Deliberately not a `ProgressView`: the wait is one run-loop turn, so a spinner would appear and
/// vanish inside a frame, which reads as a flicker rather than as progress.
private struct OpeningNotice: View {
    var body: some View {
        Text("Opening…")
            .font(Wei.Font.control())
            .foregroundStyle(Wei.Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Wei.Space.regular)
            // Named for a reader who cannot see the layout: a bare "Opening…" in a transcript reads as
            // the conversation's own words.
            .accessibilityLabel("Opening the conversation")
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

/// The reasoning of a turn: dimmed, indented, and three lines of it at a time.
///
/// Two shapes, one per state of the block, and the shape is the answer to "how much of it does the
/// reader want on screen":
///
/// - **still arriving**: the last `peekLines` lines, at a **fixed height**, with a click that opens
///   all of it. The end of it is what the model is thinking *now*, which is the only part worth
///   watching — and a fixed height is what keeps the rest of the turn on screen while they watch. A
///   reasoning model produces tens of kilobytes in a minute; drawn open, that is a column of text the
///   answer is below, and the live tool call that says what is happening scrolls off the bottom.
/// - **finished**: one line saying there was some, and the whole of it behind a click. What was
///   interesting about a finished thought is that it happened at all.
///
/// The box is anchored to its **end**, which is the reason it is a fixed-height frame rather than a
/// `lineLimit`: a `lineLimit` keeps the *first* lines of what it is given, so a long paragraph that
/// has not yet wrapped past three lines would look frozen — the reader would be shown the beginning
/// of the thought while the model was fifty lines further on. Clipping the bottom of the box instead
/// means the newest line is always the one at the bottom edge.
///
/// Two costs, both paid deliberately:
///
/// - an `NSFont` metric would have to be trusted to size the frame, so the height is **measured** from
///   a hidden three-line probe of the same font. Same lesson as `ConversationTitleHeightKey`: the
///   number that matters is the text view's idea of a line, not a font's;
/// - only a **slice** of the text is handed to the view, so what is laid out while a block streams is
///   a few lines rather than everything arrived so far. The slice is longer than the box on purpose —
///   the top of it is clipped away — so that the bottom edge is always the live edge.
private struct ThinkingRow: View {
    let row: Row
    @State private var expanded = false

    /// How tall the box is, as reported by the probe below. Zero only for the frame before the probe
    /// has answered.
    @State private var peekHeight: CGFloat = 0

    /// The lines a block still arriving shows.
    private static let peekLines = 3

    /// Whether any text is drawn: a block still arriving always shows its tail, a finished one only
    /// when the reader has asked.
    private var showsText: Bool { expanded || !row.complete }

    /// Whether the text is being *peeked at* — tail, clipped to three lines — rather than read.
    private var peeking: Bool { !expanded && !row.complete }

    var body: some View {
        VStack(alignment: .leading, spacing: Wei.Space.tight) {
            if showsText {
                text
            }
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: Wei.Space.tight) {
                    Image(systemName: "brain")
                        .font(.system(size: Wei.Icon.inline - 1))
                    Text(label)
                }
                .font(Wei.Font.caption())
            }
            .buttonStyle(.link)
            .foregroundStyle(Wei.Palette.secondary)
        }
        .padding(.leading, Wei.Space.regular)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 2)
        }
        .onPreferenceChange(PeekHeightKey.self) { measured in peekHeight = measured }
    }

    @ViewBuilder
    private var text: some View {
        let output = Text(peeking ? reasoningPeek(row.text) : row.text)
            .font(Wei.Font.code())
            .foregroundStyle(Wei.Palette.secondary)
            .textSelection(.enabled)
            // The natural height of the whole slice, so that the frame below has something taller
            // than itself to align to the bottom and clip.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if peeking {
            output
                .frame(maxHeight: peekHeight, alignment: .bottom)
                .clipped()
                .background(probe)
        } else {
            output
        }
    }

    /// Three lines of the font this text is drawn in, invisible, and asked only for its height.
    private var probe: some View {
        Text(Array(repeating: "A", count: Self.peekLines).joined(separator: "\n"))
            .font(Wei.Font.code())
            .hidden()
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: PeekHeightKey.self, value: geometry.size.height)
                }
            )
    }

    /// What the button says, which is one word per state of the reader's attention rather than one
    /// word for the row: the activity while it is happening, the content once they have opened it.
    private var label: String {
        if expanded { return "Hide reasoning" }
        return row.complete ? "Reasoning" : "Thinking…"
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
            // **A question is its pictures and its words, in that order, right-aligned with the
            // bubble.** The pictures come first because that is the order they were attached in and
            // the order the model is shown them in (an image block with the prompt), and because a
            // message that read picture-then-words on screen and words-then-picture in the log would
            // be one thing described two ways.
            //
            // One `SentPictures` for the whole list rather than a loop here, because a row of them is
            // one thing with its own question — how many fit on a line, and which one the reader has
            // opened — and a `ForEach` in this view would be that question asked in the wrong place.
            VStack(alignment: .trailing, spacing: SentPictures.gap) {
                SentPictures(images: row.images)
                if !row.text.isEmpty {
                    Text(row.text)
                        .font(Wei.Font.body())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Wei.Palette.highlightWash,
                            in: RoundedRectangle(cornerRadius: Wei.Radius.control)
                        )
                        // **Selectable, like every other row of the transcript.** It was not — alone
                        // among the rows — which is the one place a reader is most likely to want to
                        // copy from: the message is their own words, and it is what they re-send, edit
                        // or quote. An image-only question has no text to select, and that is why the
                        // empty case is skipped rather than drawn as an empty bubble.
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .reply:
            // The parse if the shell has sent one, the raw text if it has not. Either way the words are
            // the same; what the parse adds is what markdown *means* — a table, a heading, a fence's
            // language — which is the part `AttributedString(markdown:)` gets wrong and the reason the
            // shell parses at all.
            BlockView(blocks: row.blocks, plain: row.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking:
            // Reasoning, never all of it: it is worth being able to read and not worth competing with
            // the answer. It arrives before the answer and is often the longest thing in a turn, so
            // drawing it whole — finished or still arriving — puts a page of working-out between the
            // reader's question and the answer.
            //
            // What changes with the state is *which* few lines, and that is `ThinkingRow`'s own
            // rule: the tail while it is arriving (what it is thinking now), a summary line once it
            // has stopped.
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

    /// The size a cell is drawn at, which is also the size it is **measured** at.
    ///
    /// One number rather than two that happen to agree today: the measurement used to ask for 12 while
    /// the cell was drawn at 13 (`Wei.Size.control`), so every column was sized for text about 8% narrower
    /// than the text in it — which is how a wide header ends up clipped in the column it was supposed to
    /// set the width of. The comment on `width` claimed the two fonts agreed; this is the line that makes
    /// it true.
    private static let cellSize = Wei.Size.control

    /// The layout, kept across redraws. A table is re-laid out whenever anything in the transcript
    /// changes, and a frame of a block that is still arriving is such a change — see `TableMemo`.
    @State private var memo = TableMemo()

    private var layout: TableLayout {
        memo.layout(
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
                    .font(.system(size: Self.cellSize, weight: isHeader ? .semibold : .regular))
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
    ///
    /// Measured with the **semibold** face, which is the header's: a column is as wide as its widest
    /// cell and the header is measured alongside the data, so measuring prose with the lighter face would
    /// under-measure prose that sits in a column whose header is long. The difference is a couple of
    /// percent of a column's width, and the direction of it is the safe one.
    private static func width(_ spans: [Block.Span]) -> CGFloat {
        let attributed = NSMutableAttributedString(
            attributedString: NSAttributedString(Styled.spans(spans))
        )
        guard attributed.length > 0 else { return 0 }
        attributed.addAttribute(
            NSAttributedString.Key.font,
            value: NSFont.systemFont(ofSize: cellSize, weight: .semibold),
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
