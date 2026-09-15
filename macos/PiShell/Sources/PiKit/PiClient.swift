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
        guard let event = PiEvent.decode(line: line) else { return }
        if case let .ready(session, model, cwd, key) = event {
            sawReady = true
            state = key == "missing" ? .unkeyed : .ready(session: session, model: model, cwd: cwd, key: key)
        }
        // The shell says there is no key at startup, and again if a turn cannot be sent. Either way
        // the window should say so rather than looking ready.
        if case let .error(text) = event, !sawReady {
            state = .failed(text)
        }
        conversation.apply(event)
    }

    /// Send a prompt.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pi_shell_send(trimmed)
    }

    /// Ask the running turn to stop. The turn notices between steps, so this is a request rather
    /// than an interruption — which is why the status line says "stopping…" and not "stopped".
    public func stop() {
        pi_shell_send("abort")
    }

    /// Ask which models this build has.
    public func reportModel() {
        pi_shell_send("/model")
    }
}
