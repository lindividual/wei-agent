import Foundation

/// The session list, as the `sessions` event describes it.
///
/// A flat description rather than a link to the store: the host draws a sidebar, and a sidebar needs
/// labels, times and two flags — not file paths it would have to interpret. `macos/appffi/sessions.mbt`
/// is the other half of this shape, and the literals in `macos/appffi/app_wbtest.mbt` and
/// `PiModelTests/SidebarTests.swift` are the same ones.
public struct SessionRow: Identifiable, Equatable, Decodable {
    /// The file. The identity of a session, and the only name that survives a rename — which is why
    /// the row carries it rather than an index into a list the shell might have reordered.
    public let path: String
    /// Eight hex characters, as pi names its files. What the web UI shows for a session nobody has
    /// asked anything in yet, and read from the wire's `id`.
    ///
    /// Not the row's identity, which is `path`: two sessions in different workspaces could share
    /// these eight characters, and the list has to be able to tell them apart.
    public let shortID: String
    /// What to call it: the reader's own name, else the first question, else the id.
    public let label: String
    /// Milliseconds since the epoch, so that the host does its own "3 minutes ago" — the age of a row
    /// changes while the list stands still, and only the side drawing it can say so.
    public let modified: Int64
    /// Whether this is the session on screen.
    public let current: Bool
    /// Whether a turn is running in it. Only ever true for `current`, since there is one turn at a
    /// time — but read per row rather than inferred, because that is the shape the shell sends.
    public let running: Bool

    public var id: String { path }

    /// The wire's `id` and this type's identity are different facts, so the decoded field is named
    /// for what it is rather than for what it comes from.
    private enum CodingKeys: String, CodingKey {
        case path, label, modified, current, running
        case shortID = "id"
    }
}

/// One working directory's sessions, most recently used first.
public struct SessionGroup: Identifiable, Equatable, Decodable {
    /// Where the tools run. The identity of a group, and `pi`'s own name for a workspace.
    public let cwd: String
    /// What to call it: the reader's title for the workspace, else the last path component.
    public let label: String
    /// Whether the session on screen lives here.
    public let current: Bool
    public let sessions: [SessionRow]

    public var id: String { cwd }
}
