import AppKit
import SwiftUI

import PiKit

/// The app.
///
/// A window, a transcript, and a box to type in. What it deliberately does not have is a session
/// list, a settings panel, a workspace picker, attachments or a cost meter — each of those is a
/// working feature in the web UI, and every one of them would have to be rebuilt here or left
/// behind. The MVP's question is whether the same agent can be driven through a native view at
/// all, and one session answers it.
///
/// `macos/README.md` lists what is missing and in what order it should be added.

@main
struct PiShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var client = PiClient()

    var body: some Scene {
        WindowGroup("pi") {
            RootView(client: client)
                .frame(minWidth: 520, minHeight: 360)
                .onAppear { client.start() }
        }
        .defaultSize(width: 780, height: 720)
        .commands {
            // The runtime keeps one session and one thread; a second window would be a second
            // transcript of the same conversation, which is a lie about how many there are.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Needed for one thing: telling macOS that this process is an app.
///
/// `swift run PiShell` produces a bare executable, and a bare executable with a window gets no
/// menu bar and no focus — it looks like a hang. Under a real bundle this is a no-op, which is why
/// it is safe to do unconditionally.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
