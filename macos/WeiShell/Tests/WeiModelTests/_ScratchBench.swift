import XCTest

@testable import WeiModel

func bench(_ message: String) {
    let path = "/tmp/scratch-bench.txt"
    let handle = FileHandle(forWritingAtPath: path) ?? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)!
    }()
    handle.seekToEndOfFile()
    handle.write(Data((message + "\n").utf8))
    handle.closeFile()
}

final class ScratchBench: XCTestCase {
    func testHistoryDecodeCost() throws {
        let text = try String(contentsOfFile: "/tmp/switch-wire2.log", encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"kind\":\"history\"") })
        else { return XCTFail("no history line") }
        let line0 = String(line)
        bench("history line: \(line0.utf8.count) bytes")

        _ = Envelope.decode(line: line0)
        var t = Date()
        for _ in 0..<10 { _ = Envelope.decode(line: line0) }
        bench(String(format: "Envelope.decode: %.1f ms", Date().timeIntervalSince(t) * 1000 / 10))

        // Just the UTF-8 hop the C callback makes before any parsing.
        let bytes = Array(line0.utf8)
        t = Date()
        for _ in 0..<10 {
            _ = bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
        }
        bench(String(format: "String(decoding:) of the same line: %.1f ms", Date().timeIntervalSince(t) * 1000 / 10))

        guard case let .history(rows)? = Envelope.decode(line: line0)?.event else { return XCTFail("no history") }
        bench("rows: \(rows.count)")

        t = Date()
        var conversation = Conversation()
        for _ in 0..<20 { conversation = Conversation(); conversation.apply(.history(rows: rows)) }
        bench(String(format: "apply(history): %.2f ms", Date().timeIntervalSince(t) * 1000 / 20))

        t = Date()
        var turns: [Turn] = []
        for _ in 0..<50 { turns = WeiModel.turns(of: conversation.rows) }
        bench(String(format: "turns(of:): %.2f ms  (\(turns.count) turns)", Date().timeIntervalSince(t) * 1000 / 50))
    }
}
