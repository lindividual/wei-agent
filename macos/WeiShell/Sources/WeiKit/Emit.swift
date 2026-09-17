import Foundation

import WeiShellC

/// The one place a line from MoonBit lands.
///
/// A global because the C callback cannot capture anything: `wei_emit` is a plain function
/// pointer, so the sink has to be reachable without a closure. One per process is also the honest
/// count — there is one MoonBit runtime, and a second sink would be a second reader of a stream
/// that only ever had one.
///
/// The lock is what makes the hop from the agent's thread to whichever thread draws legitimate.
///
/// `install` does two things, and the second is why this type exists at all: it registers the C
/// callback, not only the reader. They used to be separate — a reader here, and a
/// `wei_set_emit` call that only `wei-cli` made — and the app that forgot the second one
/// looked exactly like a MoonBit side that had nothing to say: no error, no output, a window stuck
/// on "starting…". One entry point, so a host cannot have one without the other.
final class Emit: @unchecked Sendable {
    static let shared = Emit()

    private let lock = NSLock()
    private var sink: ((String) -> Void)?
    private var connected = false

    private init() {}

    /// Install the reader: this is the whole of what a host has to do.
    ///
    /// The last reader wins, which is what a reconnecting client wants. The C registration happens
    /// once, because the runtime has one output for the life of the process and pointing it here
    /// twice would say otherwise.
    func install(_ sink: @escaping (String) -> Void) {
        lock.lock()
        self.sink = sink
        let first = !connected
        connected = true
        lock.unlock()
        if first {
            wei_set_emit { bytes, len in
                // A literal closure rather than a reference to a method: only a closure that
                // captures nothing converts to a C function pointer, and writing it here is what
                // lets the compiler check that instead of a comment claiming it. The bytes belong to
                // MoonBit and are copied before the runtime takes them back.
                guard let bytes, len > 0 else { return }
                let text = String(
                    decoding: UnsafeRawBufferPointer(start: bytes, count: Int(len)),
                    as: UTF8.self
                )
                Emit.shared.deliver(text)
            }
        }
    }

    /// Hand one line over. Called on the agent's thread.
    func deliver(_ line: String) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(line)
    }

}
