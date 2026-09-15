import Foundation

/// What MoonBit says happened.
///
/// Facts, not drawing instructions. The other front end — the web UI — is sent HTML fragments
/// because it does not know what a transcript looks like; this one is sent the events behind them,
/// because it does. `macos/README.md` has the reasoning.
///
/// Named cases rather than a flat bag of optionals, so that the view's switch is exhaustive and a
/// new event cannot be silently ignored: adding one here stops the build until it is handled.
public enum PiEvent: Decodable, Equatable {
    /// The shell is up. Sent once, before anything else, including the bad news.
    case ready(session: String, model: String, cwd: String, key: String)
    /// A different session is now on screen. Sent on its own, before the history that belongs to it,
    /// so that the host can let go of one transcript before the next arrives.
    case session(path: String, cwd: String, model: String)
    /// Everything in a session the host did not watch happen, as rows it can draw. Switching sessions
    /// is the only way this is sent: there are no deltas in a conversation that is already over.
    case history(rows: [Row])
    /// The sidebar's list, in full, whenever it changes by more than a turn's worth.
    case sessions(workspaces: [SessionGroup])
    /// What the settings panel draws. Re-sent whenever one of these facts changes, so the panel never
    /// has to guess about the key in use after saving one.
    case settings(ShellSettings)
    /// The prompt, echoed back so the host does not have to keep its own copy of what it sent.
    case user(text: String)
    /// Streaming answer text, under the id of the block it belongs to.
    case reply(id: String, delta: String)
    /// Streaming reasoning, same shape and a different block kind.
    case thinking(id: String, delta: String)
    /// A tool, running or finished, always under the same id.
    case tool(id: String, name: String, detail: String, done: Bool, output: String, isError: Bool)
    /// What to say while nothing else is happening.
    case status(text: String)
    /// The turn is over. `text` is empty when it finished normally.
    case end(text: String, calls: Int, tools: Int, cost: String)
    /// Something went wrong, said plainly.
    case error(text: String)

    private enum CodingKeys: String, CodingKey {
        case kind, session, model, cwd, key, text, id, delta
        case name, detail, done, output, calls, tools, cost
        case path, rows, workspaces, env, saved, mode
        case isError = "error"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try fields.decode(String.self, forKey: .kind)
        switch kind {
        case "ready":
            self = .ready(
                session: try fields.decode(String.self, forKey: .session),
                model: try fields.decode(String.self, forKey: .model),
                cwd: try fields.decode(String.self, forKey: .cwd),
                key: try fields.decode(String.self, forKey: .key)
            )
        case "user":
            self = .user(text: try fields.decode(String.self, forKey: .text))
        case "session":
            self = .session(
                path: try fields.decode(String.self, forKey: .path),
                cwd: try fields.decode(String.self, forKey: .cwd),
                model: try fields.decode(String.self, forKey: .model)
            )
        case "history":
            self = .history(rows: try fields.decode([Row].self, forKey: .rows))
        case "sessions":
            self = .sessions(
                workspaces: try fields.decode([SessionGroup].self, forKey: .workspaces)
            )
        case "settings":
            self = .settings(try ShellSettings(from: decoder))
        case "reply":
            self = .reply(
                id: try fields.decode(String.self, forKey: .id),
                delta: try fields.decode(String.self, forKey: .delta)
            )
        case "thinking":
            self = .thinking(
                id: try fields.decode(String.self, forKey: .id),
                delta: try fields.decode(String.self, forKey: .delta)
            )
        case "tool":
            self = .tool(
                id: try fields.decode(String.self, forKey: .id),
                name: try fields.decode(String.self, forKey: .name),
                detail: try fields.decode(String.self, forKey: .detail),
                done: try fields.decode(Bool.self, forKey: .done),
                output: try fields.decode(String.self, forKey: .output),
                isError: try fields.decode(Bool.self, forKey: .isError)
            )
        case "status":
            self = .status(text: try fields.decode(String.self, forKey: .text))
        case "end":
            self = .end(
                text: try fields.decode(String.self, forKey: .text),
                calls: try fields.decode(Int.self, forKey: .calls),
                tools: try fields.decode(Int.self, forKey: .tools),
                cost: try fields.decode(String.self, forKey: .cost)
            )
        case "error":
            self = .error(text: try fields.decode(String.self, forKey: .text))
        default:
            // A newer MoonBit side, an older app. Refused rather than guessed at: an event the
            // host cannot name is one whose effect it cannot predict, and drawing half of it would
            // be worse than saying so.
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: fields,
                debugDescription: "unknown event kind '\(kind)'"
            )
        }
    }

    /// One line of the stream, if it is valid JSON for an event.
    public static func decode(line: String) -> PiEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PiEvent.self, from: data)
    }
}
