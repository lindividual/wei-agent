import Foundation
import WeiModel
import WeiShellC

/// Whether the shell is up, and if not, why not.
public enum ShellState: Equatable {
    case starting
    case ready(session: String, model: String, cwd: String, key: String)
    /// The shell is running but has no key to send. Not a failure: the window stays, the composer
    /// stays usable, and the message says the one thing that would change.
    case unkeyed
    case failed(String)

    public var modelName: String {
        if case let .ready(_, model, _, _) = self { return model }
        return ""
    }

    public var workspace: String {
        if case let .ready(_, _, cwd, _) = self { return cwd }
        return ""
    }
}

/// A pane of the settings window, by the name on its tab.
///
/// A second vocabulary for the same five panes, and deliberately so: this one exists so that a request
/// made from the *window* ("the reader pressed a button about the key") can be answered by the
/// settings *scene*, which is a different part of the view tree and shares nothing else with it. The
/// two lists are joined in exactly one place — `SettingsView`'s mapping to its own `Pane` — so a pane
/// renamed there has one switch to update rather than a string somewhere that quietly stops matching.
public enum SettingsPane: String, Equatable, Sendable {
    case key, tools, skills, instructions, limits
}

/// A conversation that just left the store.
///
/// `restorable` is the checkbox in the delete dialog, and it is the shell's answer rather than the
/// window's memory of the box it drew: a delete with a turn running in it is *refused*, so the box the
/// reader ticked may describe a click that was never carried out. What decides whether an Undo button
/// has anything to offer is this field.
public struct DeletedSession: Equatable, Sendable {
    public let path: String
    public let label: String
    /// False after a purge: the file was removed, not renamed aside, and `/restore` would find nothing.
    public let restorable: Bool

    public init(path: String, label: String, restorable: Bool) {
        self.path = path
        self.label = label
        self.restorable = restorable
    }
}

/// The app's whole connection to the agent.
///
/// Thin on purpose: the decisions are `Conversation` (what the transcript becomes) and MoonBit
/// (what happened). What is left for this class is the thread, the socket that is not a socket,
/// and being the thing SwiftUI watches.
@MainActor
public final class ShellClient: ObservableObject {
    @Published public private(set) var state: ShellState = .starting
    /// The store, as the sidebar draws it. Replaced whole by each `sessions` event rather than
    /// merged: the shell is the one that read the disk, and a list this side patched up from its own
    /// guesses would be a second opinion about what is on it.
    @Published public private(set) var groups: [SessionGroup] = []
    /// The conversation that was taken out of the store last, and whether there is a way back.
    ///
    /// Set by the shell's `deleted` event rather than by the click that asked for it, because a delete
    /// can be refused — a turn is appending to that file, or a job it started is still running — and
    /// only the shell's answer knows whether the file actually moved. A window that put its own notice
    /// up would show an Undo button for a conversation that is still in the list.
    ///
    /// How long the offer stands is *not* here: that is a fact about a window, and the list that draws
    /// the line owns the clock. What is here is the offer itself, because it is what the Undo button
    /// sends back.
    @Published public private(set) var deleted: DeletedSession?
    /// The session on screen, by path. What the sidebar's selection *is*, rather than something the
    /// selection agrees with: a click asks the shell to switch, and the row highlights when the shell
    /// says it did. A refused switch — a turn is running — therefore leaves the row the reader
    /// actually has.
    @Published public private(set) var currentPath = ""
    /// The settings in force, as the shell last described them. `nil` until the first `settings`
    /// event, which is why the panel shows a spinner rather than fields with guessed values.
    @Published public private(set) var settings: ShellSettings?
    /// Whether the session on screen has a turn that was interrupted — started and never ended. The
    /// transcript carries a notice while it is true, and the notice is the only way out of it.
    @Published public private(set) var interrupted = false
    /// The question that interrupted turn was asked, so the notice can show what it would resume.
    @Published public private(set) var interruptedPrompt = ""
    /// A turn that ended in another conversation, to be said without leaving this one. `nil` when there
    /// is nothing to say.
    ///
    /// **This is what replaced a switch.** A turn ending in a background session used to arrive as a
    /// `session` event, and the line that handled it moved the window — so an answer finishing in
    /// session 2 pulled a reader out of session 1. The event has a kind of its own now (`elsewhere`),
    /// and this is where it lands.
    ///
    /// It lives on the client rather than on a transcript because it is about a conversation that is
    /// not the one being drawn: the transcript of the session that ended already has its own record of
    /// the turn (`Conversation`'s `end` note), and this is the part the reader has not been told.
    @Published public private(set) var notice: SessionNotice?
    /// Bumped each time a *new* notice arrives — the chime's trigger, and deliberately not `notice`.
    ///
    /// A sound has to ring once per event, and `notice` is a value that can change for reasons that are
    /// not events: its label is refreshed when the sidebar renames a session, and a chime keyed on the
    /// value would ring again for a rename. This counts notifications; `notice` says what the last one
    /// was.
    @Published public private(set) var noticeBeat = 0
    /// The models this build can call, and which one the session is on. Sent by the shell rather than
    /// kept here: the catalog is compiled into the side that will refuse an unknown id, and a list
    /// the host maintained of its own would be a second place for the two to disagree.
    @Published public private(set) var catalog = ModelCatalog.empty
    /// The thinking levels this session's model offers, and the one in force. Sent by the shell for
    /// the catalog's reason: the levels are per model, and the side that would refuse a level it does
    /// not know is the side that has to say which ones it has.
    ///
    /// Per session in principle — a level is a fact about a model, and two sessions may be on two
    /// models — and one value here because the menu is drawn under one composer: the shell says this
    /// for the session that is on screen, and switching says it again. A background session's own
    /// level is not lost, because the shell holds it; it is only not on screen, which is the same
    /// thing `catalog` does.
    @Published public private(set) var thinking = ThinkLevels.empty
    /// The background jobs that are still running, as the shell last saw the process table. A
    /// snapshot, not a running total: a job whose process has exited stops being listed within a
    /// couple of seconds, from the shell's own tick.
    @Published public private(set) var jobs: [Job] = []
    /// The session on screen, as the transcript to draw. Replaced when the reader switches, which is
    /// why the view observes `revision` rather than this: a switch and a delta are both "the transcript
    /// changed", and SwiftUI should not have to compare a whole conversation to find that out.
    @Published public private(set) var conversation = Conversation() {
        didSet { revision += 1 }
    }
    /// Every session this process has a transcript for, including the one on screen.
    ///
    /// Not one transcript for the window. More than one conversation can be running, and their answers
    /// arrive interleaved on one wire — so each has to have somewhere of its own to accumulate. A
    /// reader who switches away from a turn in flight and back finds it there, part-drawn, rather than
    /// an empty window that fills in again from the start.
    ///
    /// Keyed by path because that is what the shell routes on. A session with no entry has never been
    /// seen by this process, which is exactly when the shell sends `history`.
    private var transcripts: [String: Conversation] = [:]
    /// Bumped on every change to `conversation`. `conversation` is a struct, so SwiftUI would
    /// otherwise compare the whole transcript on every delta to decide whether to redraw — and a
    /// transcript grows all afternoon. This is the thing a view should observe.
    @Published public private(set) var revision = 0

    private var started = false
    private var sawReady = false

    public init() {}

    /// Starts the agent, once. Idempotent because a view can be rebuilt and a runtime cannot.
    public func start() {
        guard !started else { return }
        started = true
        Emit.shared.install { [weak self] line in
            // On the agent's thread. The transcript is main-actor state, so every line crosses —
            // which is affordable at these rates and keeps one rule: nothing touches the
            // conversation off the main thread.
            Task { @MainActor [weak self] in
                self?.receive(line)
            }
        }
        // Not the main thread: the runtime wants a thread to drive its event loop, and the main
        // thread is not available to it. See `macos/README.md`.
        let thread = Thread { wei_boot(0, nil) ; wei_start() }
        thread.name = "wei-agent"
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// One line from the shell, filed under the session it names.
    ///
    /// Internal rather than private so that the routing can be tested against wire literals without
    /// booting a runtime — the same arrangement `WeiModel` has, one layer up. The routing is the part
    /// that fails *silently*: an answer written into the wrong transcript looks exactly like an answer,
    /// and only two conversations at once make it visible at all.
    func receive(_ line: String) {
        // **Both halves of this are inside the guard, and `WireLog.line`'s own guard is not enough.**
        // `trimmingCharacters` copies the line and `elided` scans it (and rewrites it, when it finds
        // an attachment), so for the one event that carries a whole conversation they were measured at
        // **101ms of main-thread work for a log that was not being written** — `WEI_DEBUG` unset,
        // which is every ordinary run. A disabled feature that costs a tenth of a second on the
        // biggest event on the wire is the most expensive kind of disabled feature.
        if WireLog.isOn {
            WireLog.line("<-", WireLog.elided(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let envelope = Envelope.decode(line: line) else { return }
        let event = envelope.event
        switch event {
        case let .ready(model, cwd, key):
            sawReady = true
            state =
                key == "missing"
                ? .unkeyed
                : .ready(session: envelope.session, model: model, cwd: cwd, key: key)
            if currentPath.isEmpty { showSession(envelope.session) }

        case let .session(cwd, model, interrupted, interruptedPrompt):
            // The switch itself: what is drawn from here on is this session's transcript, and the one
            // being left keeps accumulating in `transcripts` if it is still running.
            showSession(envelope.session)
            self.interrupted = interrupted
            self.interruptedPrompt = interruptedPrompt
            // A switch changes which session is open, where its tools run and which model it was last
            // run on. The key does not change with it, so a shell that was ready stays ready.
            if case let .ready(_, _, _, key) = state {
                state = .ready(session: envelope.session, model: model, cwd: cwd, key: key)
            }
            // **And a notice about the session that is now on screen has been answered.** The reader
            // is looking at the conversation it was about, which is the only thing the line offered;
            // leaving it up would be a banner saying "you have not seen this" over the thing itself.
            // Clearing it here rather than in `open(_:)` is what makes it true for every way in: the
            // click, the sidebar row, `⌃⇥`, and the banner's own Open.
            if notice?.path == envelope.session { notice = nil }

        case let .sessions(workspaces):
            // **Not the wire's order, the reader's.** The shell sends "most recently written first", and
            // a turn writes continuously — see `stableSidebarOrder` for what that cost when it was drawn
            // as it arrived (the rows swapped every couple of seconds while two turns ran).
            groups = stableSidebarOrder(incoming: workspaces, previous: groups)
            // The list is where a session's name lives, so a notice that is up is renamed with it — a
            // turn that just gave its session its first question would otherwise be announced by the
            // eight hex characters that were all the list had when the turn ended.
            if let up = notice {
                notice = SessionNotice(
                    path: up.path, outcome: up.outcome, label: sessionName(of: up.path, in: groups)
                )
            }

        case let .elsewhere(path, outcome):
            // A turn ended where the reader is not looking. Said, not shown: the window does not move.
            notice = SessionNotice(
                path: path,
                outcome: SessionNotice.Outcome(wire: outcome),
                label: sessionName(of: path, in: groups)
            )
            noticeBeat += 1
            // **Not routed to a transcript, and returning rather than falling through.** Every other
            // line below files the event under the session it names, and this one names a session the
            // reader is not looking at — so falling through would leave an empty `Conversation` behind
            // for it, and a later switch to that session would draw the empty one instead of waiting
            // for the `history` that is already on its way.
            return

        case let .deleted(path, label, restorable):
            // The outcome of a delete, said once. It replaces whatever offer was up: two lines would be
            // two conversations to choose between, and the second delete is the one the reader just did.
            deleted = DeletedSession(path: path, label: label, restorable: restorable)

        case let .settings(settings):
            self.settings = settings

        case let .models(catalog):
            // Only when it is about the session on screen. The shell says this for whichever session it
            // just showed, and a switch sends it *after* the `session` event that moved `currentPath` —
            // so this is the shown session's list, and a line about a background one is one the window
            // must not adopt: the picker would be offering another conversation's model.
            if envelope.session.isEmpty || envelope.session == currentPath {
                self.catalog = catalog
            }

        case let .think(levels):
            // The same rule as the catalog's, for the same reason, and the cost of getting it wrong is
            // the same shape: a menu whose tick is another session's level.
            if envelope.session.isEmpty || envelope.session == currentPath {
                thinking = levels
            }

        case let .jobs(items):
            jobs = items

        case let .error(text):
            // The shell says there is no key at startup, and again if a turn cannot be sent. Either
            // way the window should say so rather than looking ready. Later errors belong to the
            // conversation, which is where they are shown.
            if !sawReady {
                state = .failed(text)
            }

        default:
            break
        }
        // Everything else is the transcript's, and it goes to the transcript it names. An event with
        // no session is about the one on screen by definition.
        let target = envelope.session.isEmpty ? currentPath : envelope.session
        if target.isEmpty || target == currentPath {
            conversation.apply(event)
        } else {
            // A conversation the reader is not looking at. Kept, not dropped: this is the answer to a
            // question they asked and will come back to.
            var other = transcripts[target] ?? Conversation()
            other.apply(event)
            transcripts[target] = other
        }
    }

    /// Draw another session's transcript, keeping the one being left.
    ///
    /// A session this process has never seen arrives with no rows, and the `history` the shell sends
    /// right after fills it — which is the only case that needs history at all. A session it has seen
    /// before is already complete, live rows and all, so re-showing it is a swap and nothing else.
    private func showSession(_ path: String) {
        guard path != currentPath else { return }
        if !currentPath.isEmpty {
            transcripts[currentPath] = conversation
        }
        currentPath = path
        conversation = transcripts[path] ?? Conversation()
    }

    /// Why nothing can be sent right now, or `nil` when something can.
    ///
    /// One sentence, and it names the fix rather than the symptom: "no API key" is a diagnosis a reader
    /// can act on, and "unavailable" is not. Two states, because they are the two the shell reports — a
    /// shell that failed to start at all, and one that is up with no credential to send.
    ///
    /// **The key half is a fact and not an instruction**, because the view draws the instruction as a
    /// button (`StatusLine` in `Composer.swift`): "no API key — open Settings" beside a button reading
    /// "Open Settings" is the same sentence twice, and the arm of it that a reader can act on is the
    /// one that should look like a control. Everywhere else the sentence has to stand alone, which is
    /// why the shell's own wording (for a terminal) still says what to do.
    public var blocked: String? {
        switch state {
        case .starting:
            return "starting…"
        case .unkeyed:
            return "No API key"
        case let .failed(text):
            // The shell's own sentence, not a prefix added here: it already says "could not start: …" and
            // wrapping it produced "could not start: could not start: Failure(no HOME)" the first time.
            return text
        case .ready:
            return nil
        }
    }

    /// Whether the thing blocking a send is a key the reader can add, and the door is Settings.
    ///
    /// Read by the view to decide whether the wall gets a button. A shell that failed to start has no
    /// such door — nothing in Settings would fix a missing `HOME` — and offering one would be a control
    /// that leads nowhere.
    public var missingKeyIsFixableHere: Bool {
        if case .unkeyed = state { return true }
        return false
    }

    /// The project the open session belongs to, or empty when the store has not listed it yet.
    ///
    /// The three-column window needs this to answer "which project's list should be showing": the middle
    /// column lists a project, and the conversation that is open has to be reachable from wherever the
    /// reader is. A session created in this process and not yet written is not in any group yet, so this is
    /// empty for a moment and the window falls back to the reader's own choice.
    public var currentWorkspace: String {
        for group in groups where group.sessions.contains(where: { $0.path == currentPath }) {
            return group.cwd
        }
        return ""
    }

    /// The row the window is showing, from the list the shell sent.
    public var currentSession: SessionRow? {
        for group in groups {
            if let row = group.sessions.first(where: { $0.current }) { return row }
        }
        return nil
    }

    /// What to call the session on screen, for the window's title. Empty when there is nothing to
    /// call it yet, which leaves the app's own name in the title bar rather than a blank one.
    public var currentTitle: String {
        currentSession?.label ?? ""
    }

    /// Everything the host says to the shell, through one door.
    ///
    /// One door because the wire log has to see all of it and the redaction has to be impossible to
    /// forget: a second `wei_send` somewhere else is a secret that gets written to disk.
    private func tell(_ command: String) {
        WireLog.line("->", WireLog.redacted(command))
        wei_send(command)
    }

    /// Send a prompt.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tell(trimmed)
    }

    /// Carry on the turn that is open in the log.
    ///
    /// No prompt travels: the interrupted turn's question is already the last user message in the
    /// session, and the shell reads it back out of the log. Retyping it here would be a second copy
    /// of the question, and the one that got it wrong would be the one sent.
    public func continueTurn() {
        tell("continue")
    }

    /// Close that turn without resuming it.
    ///
    /// Recorded rather than merely hidden: a turn left open in the log is announced again by every
    /// later reader, so deciding not to continue it has to be written down to be a decision.
    public func dismissTurn() {
        tell("dismiss")
    }

    /// Ask the running turn to stop. The turn notices between steps, so this is a request rather
    /// than an interruption — which is why the status line says "stopping…" and not "stopped".
    public func stop() {
        tell("abort")
    }

    /// Ask which models this build has.
    public func reportModel() {
        tell("/model")
    }

    // ── the sidebar ───────────────────────────────────────────────────────

    /// Every session the store has, in the order the sidebar draws them.
    ///
    /// Flat because the two commands that move between sessions care about adjacency, not about which
    /// working directory a session belongs to — the grouping is a way of reading the list, not a
    /// second list.
    public var sessions: [SessionRow] { groups.flatMap(\.sessions) }

    /// Show another session.
    ///
    /// A request rather than a state change: what the shell does with it is its business, and what it
    /// does is open it — now if nothing is running, and at the end of the turn if one is. Either way
    /// the row highlights when the shell says it moved, and never because a click was seen here.
    public func open(_ path: String) {
        guard !path.isEmpty, path != currentPath else { return }
        tell("/open \(path)")
    }

    /// Whether `⌃⇥` has anywhere to go.
    ///
    /// The same question the move itself answers, asked once so that the menu item's enabled state
    /// and the command cannot disagree about it.
    public var canMoveSession: Bool {
        neighbourSession(rows: sessions, from: currentPath, step: 1) != nil
    }

    /// The next (`step` of 1) or previous (−1) session, for the two commands that move between
    /// conversations without the pointer.
    public func moveSession(by step: Int) {
        guard let row = neighbourSession(rows: sessions, from: currentPath, step: step) else { return }
        open(row.path)
    }

    // ── the composer ──────────────────────────────────────────────────────

    /// Switch the model the next turn runs on.
    ///
    /// The session's model, not the process's, which is why this is a command and not a setting: a
    /// resumed conversation keeps the model it recorded, and this is how the reader changes it.
    public func setModel(_ id: String) {
        guard !id.isEmpty, id != catalog.current else { return }
        tell("/model \(id)")
    }

    /// Ask for a different amount of thinking on the next turn.
    ///
    /// A request rather than a state change, for the reason `setModel` is one: whether the level is
    /// one this model has is the shell's answer, and it says so by sending `think` back with whatever
    /// it settled on. A level the model does not have is answered with the level in force, which is
    /// why the menu re-reads rather than assuming the click took.
    public func setThinkLevel(_ id: String) {
        guard !id.isEmpty, id != thinking.current else { return }
        tell("/think \(id)")
    }

    /// Put a picture on the next prompt.
    ///
    /// The path crosses as a path rather than as bytes, because the shell is the side that reads it:
    /// it is the same reader the `read` tool uses, with the same idea of what an image is and the
    /// same size cap, so a file this accepts is a file the model can be shown.
    public func attach(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/attach \(path)")
    }

    /// Put a picture on the next prompt from a file this side made.
    ///
    /// The pasted-image case: the clipboard has bytes and no path, so the host writes them somewhere
    /// and says the file is disposable. The shell reads it and deletes it — deleting from here would
    /// race the read, which happens on the agent's thread a moment later.
    public func attachTemporary(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/attach-temp \(path)")
    }

    /// Take one back off.
    ///
    /// By the path it was attached with, which is the identity the composer drew.
    public func detach(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/detach \(path)")
    }

    /// Ask for the figures again. Sent when the popover opens, because the totals move while a turn
    /// runs and the last one a window saw may be a turn old.
    public func refreshUsage() {
        tell("/usage")
    }

    // ── the sidebar ───────────────────────────────────────────────────────

    /// Name the session on screen. An empty name clears it.
    ///
    /// Only the session on screen: naming another one would mean reading a file this process is not
    /// holding, appending to it and writing it back, and the log is the one file here that must
    /// never be forked.
    public func rename(_ path: String, to name: String) {
        tell("/rename \(path) \(name)")
    }

    /// Keep a session at the top of the list, or stop keeping it there.
    ///
    /// **`to:` rather than a toggle**, and that is the same rule the rename above follows by being
    /// absolute: the menu item and the toolbar button both know which state they are offering, and a
    /// command that flipped the bit would let a stale window unpin what a second window just pinned.
    /// The word is `on`/`off` rather than a bare flag so the wire log reads as a sentence.
    ///
    /// Any session, not just the one on screen — unlike a rename, which appends to a log. A pin is a
    /// line in a list of its own (`core/pins.mbt`), so it cannot fork anything, and the reader can
    /// pin a conversation they are not reading.
    public func setPinned(_ path: String, to pinned: Bool) {
        guard !path.isEmpty else { return }
        tell("/pin \(path) \(pinned ? "on" : "off")")
    }

    // ── background jobs ───────────────────────────────────────────────────

    /// Stop a job and everything it started.
    public func killJob(_ id: String) {
        guard !id.isEmpty else { return }
        tell("/job-kill \(id)")
    }

    /// Ask what is running. Sent when the panel opens, because the shell's tick is every two seconds
    /// and a reader who opened the panel is asking now.
    public func refreshJobs() {
        tell("/jobs")
    }

    // ── the settings ──────────────────────────────────────────────────────

    /// Turn one skill on or off. Honoured on the next turn, like the tool mode.
    public func toggleSkill(_ name: String) {
        guard !name.isEmpty else { return }
        tell("/skill \(name)")
    }

    /// Save the fallback instructions, or clear them with an empty string.
    ///
    /// Sent as one message, newlines and all: the inbox hands over whatever it is given, so a set of
    /// instructions keeps its shape rather than becoming one long line.
    public func saveInstructions(_ text: String) {
        tell("/instructions \(text)")
    }

    /// Save the three turn limits. An empty field means "no opinion" — the built-in default comes
    /// back — which is a different thing from `0`, which switches the bound off.
    public func saveLimits(rounds: String, cost: String, seconds: String) {
        tell("/limits \(rounds) \(cost) \(seconds)")
    }

    /// Start a session in the project the session on screen is in.
    ///
    /// The fallback, not the rule: a host with no project to name sends this. See `newSession(in:)`,
    /// which is what the window uses because the window is the side that knows which project the reader
    /// is looking at.
    public func newSession() {
        newSession(in: "")
    }

    /// Start a session in the project the reader is looking at.
    ///
    /// The project crosses with the command, which is the fix for a bug the window had: the shell knew
    /// only the project of the session *on screen*, so "New Session" under another project created the
    /// session in the old one — and the window, following `currentPath`, moved its own selection back
    /// there. Browsing a project is a window fact (`RootView.browsing`), so the window is the side that
    /// has to hand it over; the web UI's row carries `data-new="<cwd>"` for exactly this reason.
    ///
    /// Empty asks the same question `newSession()` does, rather than being refused: an empty project is
    /// not a folder nobody picked, it is a window with nothing to name — an empty store, where no list
    /// holds the open session yet — and the shell's answer to that is "the project on screen".
    public func newSession(in project: String) {
        tell(project.isEmpty ? "/new" : "/new \(project)")
    }

    /// Fork the session on screen: a copy, in a file of its own.
    ///
    /// **A snapshot, not a mirror.** Nothing connects the two files afterwards — a later turn in either
    /// one will never appear in the other — which is why the word is "fork" and not "duplicate" (a
    /// duplicate promises a copy that keeps up), and why the shell answers with a line saying so.
    ///
    /// No arguments, unlike every command around it: what it acts on is the session that is already
    /// open, and a fork of a session this process is not holding would mean reading a file, copying it and
    /// writing it back — the same hazard `rename(_:to:)` refuses.
    public func fork() {
        tell("/fork")
    }

    /// Add a project: open a session in a folder the reader picked, **and record the folder as a
    /// workspace**.
    ///
    /// **Not the same command as `newSession(in:)`**, though both name a directory. This one writes the
    /// marker file — which is what puts a project in the sidebar — and says `workspace added: …`; that one
    /// only opens a session in a project the store already holds. A reader who picked a folder meant both;
    /// a reader clicking the plus under a project meant only the second, and a second copy of the marker
    /// file is a second copy of a fact the store already has.
    ///
    /// The path crosses as a path and the shell is the side that checks it: whether it is a directory,
    /// and what its *resolved* form is. Resolution has to happen there rather than here — `getcwd`
    /// hands back `/private/tmp/...` while a chooser hands back `/tmp/...`, and a store keyed on both
    /// would list one folder twice. See `Shell::new_in`.
    public func addWorkspace(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/new-in \(path)")
    }

    /// Take a project out of the sidebar.
    ///
    /// **Two commands rather than one with a flag**, for the same reason `/delete` and `/purge` are two: the
    /// answer to "and the conversations?" is the whole of the difference, and a wire log should say which
    /// one was asked for without a reader having to decode a boolean.
    ///
    /// The checkbox in the dialog is *not* remembered here: what the shell carries out is what the shell
    /// reports, and a client that kept its own copy would have a second opinion about a project it can no
    /// longer see. With `deletingSessions` false the store directory is renamed aside, so every conversation
    /// is still on disk; with it true the directory is emptied, and that is the only act in this program
    /// that cannot be undone.
    ///
    /// Addressed by the working directory, which is what a project *is* here — the store's directory name
    /// for it cannot be decoded back into a path (see `platform/session.mbt`).
    public func removeWorkspace(_ cwd: String, deletingSessions: Bool) {
        guard !cwd.isEmpty else { return }
        tell(deletingSessions ? "/workspace-delete \(cwd)" : "/workspace-remove \(cwd)")
    }

    /// Take a session out of the store. The file is renamed aside rather than removed, so a mis-click is
    /// recoverable by hand — and the shell answers with a `deleted` event, which is what puts the offer
    /// to undo it on screen.
    ///
    /// **Not refused for the session on screen**, which it used to be. The shell replaces the open
    /// session with another one in the same project, so clicking Delete on the row you are reading is
    /// allowed and does what it says. What is still refused is deleting one with work going on in it:
    /// a turn appending to that file, or a background job it started. Those come back as an error
    /// rather than as an offer, which is the correct pair of outcomes for a click on a row.
    public func delete(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/delete \(path)")
    }

    /// The same, **and the file too**: the one irreversible command here.
    ///
    /// A separate word rather than a flag inside the other one, because the two are two intentions and
    /// a reader of a wire log should be able to see which was asked for without reading a boolean. What
    /// the reader actually did was tick a box in a dialog: the dialog is where the friction belongs — a
    /// second confirmation after the first would be two questions for one decision — and this is what
    /// the tick turns into.
    public func purge(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/purge \(path)")
    }

    /// Put the deleted session back, and take the offer down with it.
    ///
    /// The offer is cleared here rather than waiting for the shell to say the restore happened: the
    /// click has been answered, and an Undo line that outlived its own click would be offering to undo
    /// something that is no longer undone.
    public func restore(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/restore \(path)")
        deleted = nil
    }

    /// The offer has been on screen as long as it is worth being: forget it.
    ///
    /// Called by the list that drew it, on its own clock. "How long an offer stands" is a decision
    /// about a window — the web UI's five seconds and this one's twelve are the same rule applied to
    /// two different things to read — and the side that draws the line is the side that knows when it
    /// has stopped being useful. What it must not do is *be* the offer: a window that kept its own copy
    /// could restore from it after the shell had moved on.
    public func undoOfferExpired() {
        deleted = nil
    }

    /// Take the "a turn ended elsewhere" line down, because the reader said so.
    ///
    /// No command goes to the shell, and that is the point: the notice is not a fact about any
    /// conversation — the turn is over in its own transcript whatever this window draws — so there is
    /// nothing on the other side to correct. What the reader is doing is declining to be told again.
    public func dismissNotice() {
        notice = nil
    }

    // ── settings ──────────────────────────────────────────────────────────

    /// A request for the settings window, and which pane to open on.
    ///
    /// **A request rather than a call, because the window it is about is a scene.** The settings panel
    /// is not a view in this window's tree: `SettingsView` lives in `WeiApp`'s `Settings` scene, which
    /// shares nothing with `RootView` but this object. So the control under the composer (which *can*
    /// open the window, via `@Environment(\.openSettings)`) leaves the pane here, and the panel reads
    /// it.
    ///
    /// A counter rather than a flag: two requests are two events, and a flag that was already true
    /// would swallow the second — a second press while the panel is open on the wrong pane has to
    /// still move it.
    @Published public private(set) var settingsAsk = 0
    @Published public private(set) var settingsPane = SettingsPane.key

    /// Ask for settings, on the pane where the reader can act on whatever they were just told.
    public func askForSettings(_ pane: SettingsPane) {
        settingsPane = pane
        settingsAsk += 1
    }

    /// Ask what is in force. Sent when the panel opens as well as at startup, because the settings
    /// file can be edited by hand while this app is running.
    public func refreshSettings() {
        tell("/settings")
    }

    /// Save a key for the next turn.
    ///
    /// Not trimmed or validated here: the shell writes what it is given, and a key with a space in
    /// it is the credential's business. An empty string is a request to clear, which is why the
    /// panel only sends one from its own Clear button.
    public func saveKey(_ key: String) {
        guard !key.isEmpty else { return }
        tell("/key \(key)")
    }

    /// Forget the saved key. A key from the environment is not touched: this process cannot change
    /// another process's environment, and pretending otherwise would describe a state it cannot
    /// reach.
    public func clearSavedKey() {
        tell("/key-clear")
    }

    /// Ask the shell for the page of rows before one the transcript already has.
    ///
    /// The cursor is the id of the oldest row on screen: the shell answers with the page that ends just
    /// before it, so the host never has to know how the shell pages, and a page that is answered late —
    /// after a turn appended rows — still lands in the right place.
    public func loadEarlier(_ before: String) {
        guard !before.isEmpty else { return }
        tell("/earlier \(before)")
    }

    /// Switch which tools a turn gets. Honoured on the next turn, not the one running.
    public func setMode(_ mode: String) {
        tell("/mode \(mode)")
    }
}
