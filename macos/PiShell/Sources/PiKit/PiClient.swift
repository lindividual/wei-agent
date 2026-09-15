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
    @Published public private(set) var conversation = Conversation() {
        didSet { revision += 1 }
    }
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

    private func receive(_ line: String) {
        WireLog.line("<-", line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let event = PiEvent.decode(line: line) else { return }
        switch event {
        case let .ready(session, model, cwd, key):
            sawReady = true
            currentPath = session
            state = key == "missing" ? .unkeyed : .ready(session: session, model: model, cwd: cwd, key: key)

        case let .session(path, cwd, model):
            currentPath = path
            // A switch changes which session is open, where its tools run and which model it was last
            // run on. The key does not change with it, so a shell that was ready stays ready.
            if case let .ready(_, _, _, key) = state {
                state = .ready(session: path, model: model, cwd: cwd, key: key)
            }

        case let .sessions(workspaces):
            groups = workspaces

        case let .settings(settings):
            self.settings = settings

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
        conversation.apply(event)
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

    /// Show another session.
    ///
    /// A request rather than a state change: the shell refuses while a turn is running, and the
    /// refusal is the answer the reader needs — the transcript on screen is still being written.
    public func open(_ path: String) {
        guard !path.isEmpty, path != currentPath else { return }
        tell("/open \(path)")
    }

    /// Start a session in the same directory as the current one.
    public func newSession() {
        tell("/new")
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
