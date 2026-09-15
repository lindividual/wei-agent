import Foundation

/// The one place a line from MoonBit lands.
///
/// A global because the C callback cannot capture anything: `pi_shell_emit` is a plain function
/// pointer, so the sink has to be reachable without a closure. One per process is also the honest
/// count — there is one MoonBit runtime, and a second sink would be a second reader of a stream
/// that only ever had one.
///
/// The lock is what makes the hop from the agent's thread to whichever thread draws legitimate.
final class Emit: @unchecked Sendable {
    static let shared = Emit()

    private let lock = NSLock()
    private var sink: ((String) -> Void)?

    private init() {}

    /// Install the reader. The last one wins, which is what a reconnecting client wants.
    func install(_ sink: @escaping (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    /// Hand one line over. Called on the agent's thread.
    func deliver(_ line: String) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(line)
    }
}
