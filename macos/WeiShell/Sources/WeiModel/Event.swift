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
    /// A turn ended in a conversation that is **not** on screen.
    ///
    /// Its own kind rather than a flag on `session`, because `session` means "this one is now on screen"
    /// and this side answers it by swapping transcripts. A turn finishing where the reader is not looking
    /// is the opposite kind of fact — something to be told about, not something to be taken to — and
    /// sending it as `session` was a window that jumped away from what the reader was reading.
    ///
    /// `path` is the session it happened in: the string the routing field also carries, and the one the
    /// "show me" click hands to `/open`. `outcome` is `finished`, `failed` or `stopped`, and it is a token
    /// rather than a sentence — the words are this side's, because it is this side that draws them.
    case elsewhere(path: String, outcome: String)
    /// Everything in a session the host did not watch happen, as rows it can draw. Switching sessions
    /// is the only way this is sent: there are no deltas in a conversation that is already over.
    /// The newest rows of a session, and what the host needs to ask for the ones before them.
    ///
    /// A session's transcript arrives in **pages**, newest first: `oldest` is the id of the oldest row
    /// in this page, and `hasMore` says whether anything precedes it. The shell holds the whole session
    /// either way — paging is about what crosses the wire and what the host has to lay out, not about
    /// what the shell can run a turn from.
    case history(rows: [Row], oldest: String, hasMore: Bool)
    /// The page **before** one the host already has.
    ///
    /// Its own event rather than another `history`, because the host treats the two differently: this
    /// one is *prepended* to the transcript it names, while `history` replaces it. Sending `history`
    /// again would throw away live rows the shell has not written down yet.
    case earlier(rows: [Row], oldest: String, hasMore: Bool)
    /// The sidebar's list, in full, whenever it changes by more than a turn's worth.
    case sessions(workspaces: [SessionGroup])
    /// A conversation that was just taken out of the store, so the window can offer it back.
    ///
    /// It comes from the shell rather than from the click, and that is the point: a delete can be
    /// *refused* — a turn is appending to that file right now, or a background job it started is still
    /// running — and a host that put its own notice up would be describing a state the shell never
    /// entered. The shell answers either way, and only the answer knows which of the two happened.
    ///
    /// `restorable` is the same question one step further on. A delete renames the file aside and a
    /// purge removes it, and the two are one checkbox apart in a dialog the *window* drew — so the host
    /// could have remembered the box, but it would have been remembering it about a click that may not
    /// have been carried out. The shell says which one happened, and this is what decides whether there
    /// is anything to put back.
    case deleted(path: String, label: String, restorable: Bool)
    /// A block's rendering: the blocks at `from` onwards, covering the first `parsed` code units of
    /// the row's text.
    ///
    /// `from` is how many leading blocks the host already holds, so the part of the block that has
    /// finished is not sent twice — which is what makes rendering an answer while it arrives
    /// affordable. `0` means "the whole document", and it is what a block that has stopped growing
    /// sends.
    ///
    /// `parsed` is where those blocks stop: the end of the last line that cannot change again. What
    /// follows it in `text` is the one block still being written, and the host draws that itself, from
    /// the deltas it has. The two fields are the two halves of the same fact — where the parse starts
    /// in what the host holds, and how far into the text it reaches (`WeiModel`'s `unparsedTail`).
    case blocks(id: String, blocks: [Block], from: Int, parsed: Int)
    /// What the settings panel draws. Re-sent whenever one of these facts changes, so the panel never
    /// has to guess about the key in use after saving one.
    case settings(ShellSettings)
    /// The prompt, echoed back so the host does not have to keep its own copy of what it sent.
    ///
    /// `continued` marks the one case where the host has seen the prompt already: a continued turn
    /// carries the question that is already the last user message in the log, so the echoed text is
    /// for the record rather than for the transcript. The host starts a new turn from it and draws
    /// no second question.
    ///
    /// `images` is the pictures that went out with it. They travel **with the prompt** rather than as
    /// their own event because they are part of it: the shell takes them off the composer in the same
    /// breath, so an event of their own would be a second thing to keep in step with a question that
    /// may already be drawn.
    case user(text: String, continued: Bool, images: [RowImage], skill: SkillFrame?)
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
    /// The thinking levels this session's model offers, and the one in force.
    ///
    /// A separate event from `models`, and sent alongside it, because the two lists are different
    /// lengths: the levels belong to the model, so a menu drawn from one shared table would offer a
    /// level the model rejects. The shell holds both facts, so the host asks rather than derives.
    case think(ThinkLevels)
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
    ///
    /// `endsTurn` says whether the turn that was running is over because of this — and which errors do that
    /// is the **shell's** answer, not the host's, because the host cannot tell the two apart from the text.
    /// They look the same, and they are not: a turn failing ends the turn, while a `kill` that could not
    /// find its job, a settings save that could not write, or the jobs file that could not be recorded
    /// happen *beside* a turn that is still running.
    ///
    /// This was a real bug, and the shape of it is worth keeping: the host used to treat every error as the
    /// end of a turn, so a message about a jobs file — written on a two-second timer, while a long turn was
    /// going — took the Stop button away. The reader could no longer stop the thing that was running, and
    /// the only way out was to wait for it. Clearing on every error was a guess; this is the fact.
    ///
    /// Absent means false, the same rule every field that arrived after its first reader follows.
    case error(text: String, endsTurn: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind, session, model, cwd, key, text, id, delta
        case name, detail, done, output, calls, tools, cost
        case path, rows, workspaces, env, saved, mode, blocks, from, parsed, items, images
        case label, restorable, outcome
        case oldest
        case has_more
        case isError = "error"
        case endsTurn
        case canSend = "can_send"
        case interrupted, continued
        case interruptedPrompt = "interrupted_prompt"
        case skill
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
                continued: (try fields.decodeIfPresent(Bool.self, forKey: .continued)) ?? false,
                // Absent from a shell that predates the field, and from a prompt that carried no
                // pictures — both of which mean the same thing to the transcript: a question with
                // no images above it.
                images: (try fields.decodeIfPresent([RowImage].self, forKey: .images)) ?? [],
                // Absent unless the prompt was a `/skill:<name>` command, which is the same fact as
                // `nil`: a question the reader typed themselves.
                skill: try fields.decodeIfPresent(SkillFrame.self, forKey: .skill)
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
        case "elsewhere":
            // `outcome` is read leniently for the reason the other later fields are: a shell that grows a
            // fourth outcome should have it shown as an unknown one, not turn the whole notice into a
            // line this side refuses and drops.
            self = .elsewhere(
                path: try fields.decode(String.self, forKey: .path),
                outcome: (try fields.decodeIfPresent(String.self, forKey: .outcome)) ?? ""
            )
        case "history":
            // Hoisted into locals rather than written inline: three `try`s inside one initializer is
            // more than the type checker will work through here, and it says so with "unable to
            // type-check this expression in reasonable time" rather than with anything about the types.
            let rows = try fields.decode([Row].self, forKey: .rows)
            let oldest = try fields.decodeIfPresent(String.self, forKey: .oldest) ?? ""
            // Absent from a shell that predates paging, which sends every row it has: a host that
            // assumed there was more would offer to load a page that does not exist.
            let hasMore = try fields.decodeIfPresent(Bool.self, forKey: .has_more) ?? false
            self = .history(rows: rows, oldest: oldest, hasMore: hasMore)
        case "earlier":
            let rows = try fields.decode([Row].self, forKey: .rows)
            let oldest = try fields.decodeIfPresent(String.self, forKey: .oldest) ?? ""
            let hasMore = try fields.decodeIfPresent(Bool.self, forKey: .has_more) ?? false
            self = .earlier(rows: rows, oldest: oldest, hasMore: hasMore)
        case "sessions":
            self = .sessions(
                workspaces: try fields.decode([SessionGroup].self, forKey: .workspaces)
            )
        case "deleted":
            let deletedPath = try fields.decode(String.self, forKey: .path)
            let deletedLabel = try fields.decode(String.self, forKey: .label)
            // Absent from a shell that predates the checkbox, and those only ever renamed the file
            // aside: true is both the older behaviour and the one that offers a way back.
            let restorable = try fields.decodeIfPresent(Bool.self, forKey: .restorable) ?? true
            self = .deleted(path: deletedPath, label: deletedLabel, restorable: restorable)
        case "settings":
            self = .settings(try ShellSettings(from: decoder))
        case "models":
            self = .models(try ModelCatalog(from: decoder))
        case "think":
            self = .think(try ThinkLevels(from: decoder))
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
            // Hoisted into locals for the reason the `history` case above gives: this decoder is at the
            // edge of what the type checker will work through in one expression, and four `try`s in one
            // initializer crosses it.
            let id = try fields.decode(String.self, forKey: .id)
            let blocks = try fields.decode([Block].self, forKey: .blocks)
            // Absent from any shell older than the field, and those send a block whole.
            let from = try fields.decodeIfPresent(Int.self, forKey: .from) ?? 0
            // And absent for the same reason: a shell that predates it meant that its blocks were the
            // whole row, which is what an omitted boundary has to keep meaning here.
            let parsed = try fields.decodeIfPresent(Int.self, forKey: .parsed)
                ?? Row.blocksCoverEverything
            self = .blocks(id: id, blocks: blocks, from: from, parsed: parsed)
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
            self = .error(
                text: try fields.decode(String.self, forKey: .text),
                endsTurn: try fields.decodeIfPresent(Bool.self, forKey: .endsTurn) ?? false
            )
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
