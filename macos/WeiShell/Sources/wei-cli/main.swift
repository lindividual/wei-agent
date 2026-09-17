import Foundation
import WeiShellC

// The boundary, on a terminal.
//
// This prints the wire — one JSON object per line, exactly as MoonBit emits it — rather than the
// conversation. That is the point: when a helper's text does not appear, the question is whether
// the event was never sent or was sent and dropped, and only the wire answers it. The app has the
// other half.
//
// It is also the check that the MoonBit archive is sound on a machine where nothing else can run:
//
//     macos/build-moonbit.sh && cd macos/WeiShell && swift run wei-cli
//
// Lines typed on stdin are sent as commands: a prompt, `abort`, `/model`, `quit`.

// Straight to stderr, with nothing in between: the point is to see what arrived, and a sink
// that reformatted it would be one more thing between this and the answer.
wei_set_emit { bytes, len in
    guard let bytes, len > 0 else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(len)), as: UTF8.self)
    FileHandle.standardError.write(Data(text.utf8))
}

wei_boot(0, nil)

let agent = Thread {
    wei_start()
}
agent.name = "wei-agent"
agent.start()

// stdin is read on its own queue so that a pipe which ends — a script, or a `printf |` — does not
// take the agent down with it. The process lives until the agent says it is done.
DispatchQueue.global().async {
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        wei_send(line)
    }
}

// Wait for the agent rather than for stdin. `quit` is what ends it, and so is the window closing
// in the app.
while !agent.isFinished {
    Thread.sleep(forTimeInterval: 0.1)
}
