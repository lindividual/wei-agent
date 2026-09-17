import Foundation

/// The wire, on disk, when somebody asks for it.
///
/// A GUI app prints nothing, which is exactly how the bug this was written for survived: the settings
/// panel sat on "asking the shell…" and there was no way to tell whether the request went out, whether
/// the answer came back, or whether the answer was there and the view ignored it. `wei-cli` can
/// show the wire, but only for the things a terminal can do — and the thing that was broken was a
/// window.
///
///     WEI_DEBUG=/tmp/wei-wire.log open "macos/dist/wei Agent.app"
///
/// Both directions, one line each, `→` for what the host sends and `←` for what the shell emits.
/// Deliberately off unless asked for: a log file beside the app that fills up unasked is a surprise,
/// and this one would hold the reader's prompts.
enum WireLog {
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["WEI_DEBUG"], !path.isEmpty else {
            return nil
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        return handle
    }()

    static var isOn: Bool { handle != nil }

    /// One line, from `receive` (which is already off the main thread, and already holds everything
    /// needed) or from a send.
    static func line(_ direction: String, _ text: String) {
        guard let handle else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        handle.write(Data("\(stamp) \(direction) \(text)\n".utf8))
    }

    /// A command with anything secret taken out.
    ///
    /// The key is the one thing on this wire that must not land in a file a reader might later paste
    /// into a bug report. The length is kept, because "the field was empty when it should not have
    /// been" is the kind of thing a wire log is read to find out.
    static func redacted(_ command: String) -> String {
        let prefix = "/key "
        guard command.hasPrefix(prefix) else { return command }
        let value = command.dropFirst(prefix.count)
        return "\(prefix)<\(value.count) characters>"
    }

    /// An event with the pictures taken out of it.
    ///
    /// The attachment bytes are base64 in the `data` field, and an image is megabytes of it: a log
    /// that was meant to hold prompts and field names becomes unreadable — and unopenable — the moment
    /// a reader attaches one screenshot. The value is replaced by its length, for the same reason the
    /// key's length is kept: "there were bytes here and how many" is the question a log is read to
    /// answer, and the bytes themselves never are.
    ///
    /// Base64 has no quote in it, so the field is found by scanning to the next `"` — no JSON parsing
    /// on a path that must not slow the wire down.
    static func elided(_ line: String) -> String {
        let marker = "\"data\":\""
        guard let start = line.range(of: marker) else { return line }
        let valueStart = start.upperBound
        guard let end = line[valueStart...].firstIndex(of: "\"") else { return line }
        let count = line.distance(from: valueStart, to: end)
        // Nothing to hide, and nothing worth rewriting: a short value is a test fixture or a thumbnail,
        // not something that makes the log unreadable.
        guard count > 256 else { return line }
        return line.replacingCharacters(
            in: valueStart..<end,
            with: "<\(count) bytes of base64>"
        )
    }
}
