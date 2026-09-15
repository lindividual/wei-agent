import AppKit
import SwiftUI

import PiKit

/// The app.
///
/// A window with a session list beside a transcript, and a box to type in. What it deliberately does
/// not have is a workspace picker, attachments, a cost meter or a model picker — each of those is a
/// working feature in the web UI, and every one of them would have to be rebuilt here or left
/// behind. What it does have is the two things without which the rest is unreachable: the sidebar,
/// because one session at a time was the MVP's question and this is the answer; and a settings panel,
/// because a machine with no key in its environment has no way in at all.
///
/// `macos/README.md` lists what is missing and in what order it should be added.

@main
struct PiShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var client = PiClient()

    var body: some Scene {
        WindowGroup("pi") {
            RootView(client: client)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear { client.start() }
        }
        .defaultSize(width: 980, height: 760)
        .commands {
            // The one window: the runtime keeps one session and one thread, so a second window would
            // be a second view of the same conversation — which is what the sidebar is for. "New"
            // therefore means a new session, and it is where a Mac user looks for it.
            CommandGroup(replacing: .newItem) {
                Button("New Session") { client.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }

        // The standard Settings item: ⌘, and the menu entry a Mac user looks in. A separate scene
        // rather than a sheet, because that is what this is — a place, not a step in something else.
        // The panel is drawn from the shell's answer, so it can be opened before the shell has said
        // anything: it shows that it is asking rather than fields it made up.
        Settings {
            SettingsView(client: client)
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
