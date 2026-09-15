import Foundation
import PiModel
import PiShellC

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

/// The app's whole connection to the agent.
///
/// Thin on purpose: the decisions are `Conversation` (what the transcript becomes) and MoonBit
/// (what happened). What is left for this class is the thread, the socket that is not a socket,
/// and being the thing SwiftUI watches.
@MainActor
public final class PiClient: ObservableObject {
    @Published public private(set) var state: ShellState = .starting
    /// The store, as the sidebar draws it. Replaced whole by each `sessions` event rather than
    /// merged: the shell is the one that read the disk, and a list this side patched up from its own
    /// guesses would be a second opinion about what is on it.
    @Published public private(set) var groups: [SessionGroup] = []
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
    /// The models this build can call, and which one the session is on. Sent by the shell rather than
    /// kept here: the catalog is compiled into the side that will refuse an unknown id, and a list
    /// the host maintained of its own would be a second place for the two to disagree.
    @Published public private(set) var catalog = ModelCatalog.empty
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
        let thread = Thread { pi_shell_boot(0, nil) ; pi_shell_start() }
        thread.name = "pi-agent"
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// One line from the shell, filed under the session it names.
    ///
    /// Internal rather than private so that the routing can be tested against wire literals without
    /// booting a runtime — the same arrangement `PiModel` has, one layer up. The routing is the part
    /// that fails *silently*: an answer written into the wrong transcript looks exactly like an answer,
    /// and only two conversations at once make it visible at all.
    func receive(_ line: String) {
        WireLog.line("<-", WireLog.elided(line.trimmingCharacters(in: .whitespacesAndNewlines)))
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

        case let .sessions(workspaces):
            groups = workspaces

        case let .settings(settings):
            self.settings = settings

        case let .models(catalog):
            self.catalog = catalog

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
    public var blocked: String? {
        switch state {
        case .starting:
            return "starting…"
        case .unkeyed:
            return "no API key — open Settings"
        case let .failed(text):
            // The shell's own sentence, not a prefix added here: it already says "could not start: …" and
            // wrapping it produced "could not start: could not start: Failure(no HOME)" the first time.
            return text
        case .ready:
            return nil
        }
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
    /// forget: a second `pi_shell_send` somewhere else is a secret that gets written to disk.
    private func tell(_ command: String) {
        WireLog.line("->", WireLog.redacted(command))
        pi_shell_send(command)
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

    /// Put a deleted session back.
    public func restore(_ path: String) {
        guard !path.isEmpty else { return }
        tell("/restore \(path)")
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

    /// Start a session in the same directory as the current one.
    public func newSession() {
        tell("/new")
    }

    /// Start a session in a directory the reader picked.
    ///
    /// The path crosses as a path and the shell is the side that checks it: whether it is a directory,
    /// and what its *resolved* form is. Resolution has to happen there rather than here — `getcwd`
    /// hands back `/private/tmp/...` while a chooser hands back `/tmp/...`, and a store keyed on both
    /// would list one folder twice. See `Shell::new_in`.
    public func newSession(in path: String) {
        guard !path.isEmpty else { return }
        tell("/new-in \(path)")
    }

    /// Take a session out of the store. The shell refuses the one on screen, and the file is renamed
    /// aside rather than removed, so a mis-click is recoverable by hand.
    public func delete(_ path: String) {
        guard path != currentPath else { return }
        tell("/delete \(path)")
    }

    // ── settings ──────────────────────────────────────────────────────────

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

    /// Switch which tools a turn gets. Honoured on the next turn, not the one running.
    public func setMode(_ mode: String) {
        tell("/mode \(mode)")
    }
}
