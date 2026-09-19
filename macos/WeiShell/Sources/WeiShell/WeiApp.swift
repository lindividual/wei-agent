import AppKit
import SwiftUI

import WeiKit

/// The app.
///
/// A window with a session list beside a transcript, and a composer that floats over it: the text, the
/// pictures attached to it, the model that will answer it, and the figures for what the last turn cost
/// — all of it in the place the message is being written, because every one of those changes what the
/// message will be. What it deliberately does not have is a workspace picker, a background-task panel
/// or a skills panel; each of those is a working feature in the web UI, and every one of them would
/// have to be rebuilt here or left behind.
///
/// `macos/README.md` lists what is missing and in what order it should be added.

@main
struct WeiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var client = ShellClient()
    /// What the window is in the middle of: shared with the view tree so this menu can open the
    /// folder chooser that `RootView` draws.
    @StateObject private var actions = WindowActions()

    var body: some Scene {
        WindowGroup("wei Agent") {
            RootView(client: client, actions: actions)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear { client.start() }
        }
        .defaultSize(width: 980, height: 760)
        .commands {
            // The one window: the runtime keeps one session and one thread, so a second window would
            // be a second view of the same conversation — which is what the sidebar is for. "New"
            // therefore means a new session, and it is where a Mac user looks for it.
            CommandGroup(replacing: .newItem) {
                Button("New Session") { client.newSession(in: actions.browsing) }
                    .keyboardShortcut("n", modifiers: .command)
                // The second answer to "new session", where a Mac user looks for it. The shortcut is
                // on this item rather than on the toolbar's copy of it: one shortcut belongs to one
                // command, and the menu bar is the one that owns it.
                Button("New Session in Folder…") { actions.choosingFolder = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                // Here, in the New group, because it makes a session too — that is what the reader is
                // looking for. It is **not** in the Session menu, which holds the commands that move
                // between sessions and stop the work in one; those act on what is open rather than
                // making something new.
                //
                // No shortcut this round: ⌘N and ⇧⌘N are taken, and the house rule is that one command
                // gets one key — the toolbar button and this item are the two ways in, which is already
                // what "New Session" does.
                Button("Fork Session") { client.fork() }
                    .disabled(client.currentPath.isEmpty)
            }
            // A second way to get a picture from the clipboard onto the next prompt. The composer
            // offers ⌘V on the card, but a text field claims ⌘V for itself and the argument about who
            // wins it is not one a reader should have to care about — so the feature is also here,
            // where it is discoverable and where nothing competes for it.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Attach Image from Clipboard") {
                    if let path = PastedImage.write() { client.attachTemporary(path) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!PastedImage.available)
                // The two screenshots, under the same menu as the clipboard because they are the same
                // kind of thing: a picture for the next prompt that was not a file the reader picked.
                //
                // **⌘⇧S, not the system's ⌘⇧4.** The platform's own screenshot still works and still
                // does what it does; these two are the ones that come back *here*, and two commands on
                // one keystroke is the state this app has already been bitten by (see the note in
                // `docs/macos-pitfalls.md` about who owns a key). A reader who wants a picture on their
                // Desktop uses ⌘⇧4, and a reader who wants to ask about one uses these.
                Button("Take Screenshot") { actions.screenshot(hiding: false) }
                    .keyboardShortcut(Screenshot.onScreen)
                Button("Take Screenshot Without This Window") { actions.screenshot(hiding: true) }
                    .keyboardShortcut(Screenshot.withoutWindow)
            }
            // What the reader does *to* the session they are in: move to another one, or stop the work
            // in this one. Both had a way in already — the sidebar row, and the button in the composer
            // — and both ways are things you have to already know are there. A menu is where a Mac
            // user looks when they do not.
            //
            // A menu of its own rather than items under View or Window, because the app's own word for
            // the thing is "session" and there is no menu called that yet: a reader looking for
            // "switch session" finds it by name instead of by guessing which of Apple's categories it
            // was filed under.
            CommandMenu("Session") {
                Button("Next Session") { client.moveSession(by: 1) }
                    .keyboardShortcut("\t", modifiers: [.control])
                    .disabled(!client.canMoveSession)
                Button("Previous Session") { client.moveSession(by: -1) }
                    .keyboardShortcut("\t", modifiers: [.control, .shift])
                    .disabled(!client.canMoveSession)
                Divider()
                // ⌘. is what this key means on this platform — Xcode stops, Terminal interrupts — and
                // it is what a reader will try first when something is running too long.
                //
                // Disabled rather than hidden when nothing is running: a command that appears and
                // disappears is a command nobody learns.
                Button("Stop Turn") { client.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!client.conversation.running)
            }
            // The sidebar collapses on the platform's own keystroke and the toolbar draws its own
            // toggle; this is the menu item that says so. Without it the sidebar can be hidden and
            // only a mouse can bring it back — which for a window whose whole left half is the session
            // list is the one gesture that should not require the pointer.
            SidebarCommands()
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
/// `swift run WeiShell` produces a bare executable, and a bare executable with a window gets no
/// menu bar and no focus — it looks like a hang. Under a real bundle this is a no-op, which is why
/// it is safe to do unconditionally.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Off unless `WEI_TCC_PROBE` is set; it exists to check that a permission survives a rebuild.
        TCCProbe.run()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
