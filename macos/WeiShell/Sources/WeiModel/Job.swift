import Foundation

/// One background process the agent started.
///
/// A job is work that outlived the tool call that started it: a `sleep`, a dev server, anything
/// `bash` left running behind. The panel exists for the second half of that sentence — the process is
/// still there after the reader stopped waiting, and this is the only place that says so.
public struct Job: Equatable, Decodable, Identifiable {
    /// `<kind>-N`, as dsh issues them, and what a kill names.
    public let id: String
    public let kind: String
    /// One line for the reader: the command, as it was asked.
    public let label: String
    /// `running`, `stopping`, `killed`, `completed`, `failed`. Only live ones reach the panel, but
    /// stopping and running are worth telling apart: the first means the kill has been sent.
    public let status: String
    /// How long it has been running, in milliseconds. The host turns this into "2m 10s" and keeps it
    /// counting: a duration is the one thing that changes on its own, and sending a frame a second to
    /// say so would be the wire doing arithmetic the host can do.
    public let ageMS: Int64
    /// The processes still alive, and what a kill would reach. Empty while a command is still being
    /// identified, which is a real state rather than a missing value.
    public let pids: [Int]
    /// The session that started it, so the reader can see whose it is.
    public let session: String

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, status, pids, session
        case ageMS = "age_ms"
    }

    public var isStopping: Bool { status == "stopping" }

    /// The age as a reader reads it: the two units that matter.
    public func age(now: Date = Date()) -> String {
        let seconds = Int(ageMS / 1000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
