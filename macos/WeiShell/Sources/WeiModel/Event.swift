import Foundation

/// What MoonBit says happened.
///
/// Facts, not drawing instructions. The other front end — the web UI — is sent HTML fragments
/// because it does not know what a transcript looks like; this one is sent the events behind them,
/// because it does. `macos/README.md` has the reasoning.
///
/// An event, and which session it is about.
///
/// The routing field is what makes more than one conversation possible at a time. A turn writes its own
/// session and says so on every line it produces, so the host can file an answer under the transcript it
/// belongs to instead of writing it into whichever one happens to be on screen — which is the failure
/// this field exists to prevent, and one that only appears once two turns are moving at once.
///
/// **An empty `session` means "the one on screen."** That is not a shortcut for the shell's benefit: most
/// of what arrives is an answer to something the reader just did to the session they are looking at — a
/// bad path, an unknown model, the settings panel — and those need no name. What does have to say where
/// it belongs is a running turn, because a running turn is the one thing that can be about a
/// conversation nobody is looking at.
public struct Envelope: Equatable {
    public let session: String
    public let event: ShellEvent

    public static func decode(line: String) -> Envelope? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return envelope
    }
}

/// The wire shape, which is the envelope above with the payload flattened into it.
///
/// One object per line rather than a nested one, because that is what the shell writes and what a
/// human reads in `WEI_DEBUG` — and because a nesting level that exists only to be unwrapped is a
/// level nobody asked for.
extension Envelope: Decodable {
    private enum CodingKeys: String, CodingKey {
        case session
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        // Absent is the common case, not an error: see the note above about what an empty session
        // means.
        session = (try fields.decodeIfPresent(String.self, forKey: .session)) ?? ""
        event = try ShellEvent(from: decoder)
    }
}

/// Named cases rather than a flat bag of optionals, so that the view's switch is exhaustive and a
/// new event cannot be silently ignored: adding one here stops the build until it is handled.
public enum ShellEvent: Decodable, Equatable {
    /// The shell is up. Sent once, before anything else, including the bad news, and again when saving
    /// a key changes one of the four facts it carries.
    case ready(model: String, cwd: String, key: String)
    /// A different session is now on screen. Sent on its own, before the history that belongs to it,
    /// so that the host can let go of one transcript before the next arrives.
    ///
    /// `interrupted` says the session holds a turn that was started and never ended — a process that
    /// died inside one, or a stop that was never resumed. It travels with the session rather than as
    /// its own event because it is a fact about the session, and it arrives again after every turn:
    /// continuing the turn is what makes it false.
    case session(cwd: String, model: String, interrupted: Bool, interruptedPrompt: String)
    /// Everything in a session the host did not watch happen, as rows it can draw. Switching sessions
    /// is the only way this is sent: there are no deltas in a conversation that is already over.
    case history(rows: [Row])
    /// The sidebar's list, in full, whenever it changes by more than a turn's worth.
    case sessions(workspaces: [SessionGroup])
    /// A block stopped growing: how to draw it. Sent once per block, when the deltas are over.
    case blocks(id: String, blocks: [Block])
    /// What the settings panel draws. Re-sent whenever one of these facts changes, so the panel never
    /// has to guess about the key in use after saving one.
    case settings(ShellSettings)
    /// The prompt, echoed back so the host does not have to keep its own copy of what it sent.
    ///
    /// `continued` marks the one case where the host has seen the prompt already: a continued turn
    /// carries the question that is already the last user message in the log, so the echoed text is
    /// for the record rather than for the transcript. The host starts a new turn from it and draws
    /// no second question.
    case user(text: String, continued: Bool)
    /// Streaming answer text, under the id of the block it belongs to.
    case reply(id: String, delta: String)
    /// Streaming reasoning, same shape and a different block kind.
    case thinking(id: String, delta: String)
    /// The pictures waiting to go out with the next prompt, whole. Sent on every change rather than
    /// as adds and removes, so the composer draws what the shell holds instead of applying a
    /// difference — the same reason the session list arrives whole.
    case images(items: [Attachment], canSend: Bool)
    /// What the session has used, and what its last turn cost. Sent after every turn, and on the
    /// first breath for a resumed session: a reader opening an hour-old conversation should see what
    /// it cost rather than a line of dashes that fills in on their next question.
    case usage(Usage)
    /// The models this build can call, and which one the session is on. The catalog lives in the
    /// shell, which is the side that refuses an id it does not know, so the picker is drawn from
    /// what the shell said rather than from a list kept here.
    case models(ModelCatalog)
    /// The background jobs that are still running, whole. Sent on every change rather than as adds
    /// and removes, for the same reason the session list is: the shell holds the store, and a host
    /// that patched its own copy would be a second opinion about what is running.
    case jobs(items: [Job])
    /// A tool, running or finished, always under the same id.
    case tool(id: String, name: String, detail: String, done: Bool, output: String, isError: Bool)
    /// What to say while nothing else is happening.
    case status(text: String)
    /// A row that stands in for something the conversation no longer holds in full: a compaction's
    /// summary, or the summary a branch left behind. `label` is what the row is called — without it a
    /// summary is a paragraph a reader takes for an answer.
    case note(text: String, label: String)
    /// The turn is over. `text` is empty when it finished normally.
    case end(text: String, calls: Int, tools: Int, cost: String)
    /// Something went wrong, said plainly.
    case error(text: String)

    private enum CodingKeys: String, CodingKey {
        case kind, session, model, cwd, key, text, id, delta
        case name, detail, done, output, calls, tools, cost
        case path, rows, workspaces, env, saved, mode, blocks, items
        case isError = "error"
        case canSend = "can_send"
        case interrupted, continued
        case interruptedPrompt = "interrupted_prompt"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try fields.decode(String.self, forKey: .kind)
        switch kind {
        case "ready":
            self = .ready(
                model: try fields.decode(String.self, forKey: .model),
                cwd: try fields.decode(String.self, forKey: .cwd),
                key: try fields.decode(String.self, forKey: .key)
            )
        case "user":
            self = .user(
                text: try fields.decode(String.self, forKey: .text),
                continued: (try fields.decodeIfPresent(Bool.self, forKey: .continued)) ?? false
            )
        case "session":
            self = .session(
                cwd: try fields.decode(String.self, forKey: .cwd),
                model: try fields.decode(String.self, forKey: .model),
                interrupted: (try fields.decodeIfPresent(Bool.self, forKey: .interrupted)) ?? false,
                // The prompt of the turn that was interrupted. Optional on the wire so that an
                // older shell — which has no such field — does not make the whole event undecodable:
                // a rename that only one side knows about is a session that stops switching.
                interruptedPrompt: (try fields.decodeIfPresent(
                    String.self, forKey: .interruptedPrompt
                )) ?? ""
            )
        case "history":
            self = .history(rows: try fields.decode([Row].self, forKey: .rows))
        case "sessions":
            self = .sessions(
                workspaces: try fields.decode([SessionGroup].self, forKey: .workspaces)
            )
        case "settings":
            self = .settings(try ShellSettings(from: decoder))
        case "models":
            self = .models(try ModelCatalog(from: decoder))
        case "jobs":
            self = .jobs(items: try fields.decode([Job].self, forKey: .items))
        case "images":
            self = .images(
                items: try fields.decode([Attachment].self, forKey: .items),
                canSend: try fields.decode(Bool.self, forKey: .canSend)
            )
        case "usage":
            self = .usage(try Usage(from: decoder))
        case "blocks":
            self = .blocks(
                id: try fields.decode(String.self, forKey: .id),
                blocks: try fields.decode([Block].self, forKey: .blocks)
            )
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
        case "note":
            self = .note(
                text: try fields.decode(String.self, forKey: .text),
                // Optional so an older shell's note — which had no label — still decodes, and draws
                // as the unlabelled paragraph it always was.
                label: (try fields.decodeIfPresent(String.self, forKey: .name)) ?? ""
            )
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
    ///
    /// The payload without its routing: for tests that are about a field name, and for nothing else.
    /// Production goes through `Envelope.decode`, because a host that dropped the routing on the floor
    /// would put one conversation's answer into another's transcript.
    public static func decode(line: String) -> ShellEvent? {
        Envelope.decode(line: line)?.event
    }
}
