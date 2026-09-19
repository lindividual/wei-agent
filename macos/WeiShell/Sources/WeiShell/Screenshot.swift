import AppKit
import SwiftUI

import WeiModel

/// The screenshot that just came back, waiting to be marked up.
///
/// A picture and an identity, and the identity is a fresh one per capture: the sheet holds its own
/// state (the marks, the tool in hand, what Undo would take back), so a second capture while a sheet
/// is open has to be a *different* sheet rather than the same one with a new picture in it.
struct Markup: Identifiable {
    let id = UUID()
    let image: NSImage
}

/// Which picture the window is making, if it is making one.
///
/// One enumeration rather than two flags, because these two are one thing on screen: the same sheet,
/// with the same five tools, on different paper. And because two flags would let both be true at once
/// — the blank sheet the pencil opens and the capture one — where the second one to be set would
/// silently replace the first one's drawing.
enum PictureSheet: Identifiable {
    /// A blank sheet: somewhere to draw the picture that is not on the screen.
    case blank
    /// A capture, to be marked up before it goes on the prompt.
    case marking(Markup)

    var id: String {
        switch self {
        case .blank: return "blank"
        case let .marking(markup): return markup.id.uuidString
        }
    }
}

/// The system's screenshot tool, as this app runs it.
///
/// **The capture is not this app's own.** `/usr/sbin/screencapture` is the tool the platform ships and
/// the one the reader already knows from ⌘⇧4 and ⌘⇧5, and going through it is what makes a *region* or
/// a *window* possible at all: the crosshair, the selection, the window highlight and the space bar
/// that toggles between the two are drawn by the system, and none of them has to be rebuilt here. What
/// this app adds is the part the tool does not do — the picture comes back into the composer, where it
/// can be marked up before it goes on the prompt.
///
/// It is the tool rather than ScreenCaptureKit for the same reason: the same command the reader knows,
/// no second overlay to write, and one permission either way. Reading the screen is a TCC grant, and
/// this app is not special about it — `docs/macos-pitfalls.md` has the half that matters, which is
/// that the grant can be refused and can be lost.
enum Screenshot {
    /// Capture a region the reader selects, with the window still on screen.
    ///
    /// `⌘⇧S` rather than the system's `⌘⇧4`, which is taken: the reader who wants the system's own
    /// screenshot still has it, and this one is about where the picture goes afterwards.
    static let onScreen = KeyboardShortcut("s", modifiers: [.command, .shift])

    /// The same capture with this window out of the way first — for the screenshot that would
    /// otherwise have the app in it.
    ///
    /// `⌃` rather than a second letter, because it is the same command with one thing changed, and the
    /// shortcut says so. It is also **what the menu item is for**: the reader who wants the window in
    /// the picture uses the item above it, which is why that is the one with the plain shortcut.
    static let withoutWindow = KeyboardShortcut("s", modifiers: [.command, .shift, .control])

    /// Where the platform keeps it. Absolute rather than by name: this process is launched by Finder
    /// and inherits `launchd`'s `PATH`, which is not the reader's — a lookup that fails here would be a
    /// menu item that does nothing.
    private static let executable = "/usr/sbin/screencapture"

    /// Take one, and say what came back.
    ///
    /// `hiding` is the second command and the whole of the difference between the two: the app hides,
    /// the reader picks out what they want with the app out of the way, and the picture arrives with
    /// the window back where it was. It hides the **whole app** (`NSApp.hide`) rather than ordering
    /// this window out: the window is the frontmost thing on screen, and ordering out one window
    /// leaves the menu bar and the Dock announcing an app that is meant to be out of the shot.
    ///
    /// Nothing here judges the picture. Whether it is a kind the shell will attach, and whether the
    /// model on screen can be shown it, are the shell's answers on the bytes — the same answers a
    /// dropped file gets, and the reason this side only has to know that bytes arrived.
    ///
    /// On the main actor because it hides and unhides *this app* (`NSApp`), and because it is called
    /// from one — the awaiting on the subprocess is what keeps the window alive in between, and an
    /// `await` inside a main-actor function suspends rather than blocks.
    @MainActor
    static func take(hiding: Bool) async -> ScreenshotOutcome {
        // Read *before* the capture, so what is reported afterwards is the permission this attempt had
        // and not one the reader may have granted while looking at a dialog.
        let access = CGPreflightScreenCaptureAccess()
        // A file rather than `-c` (the clipboard): the clipboard is the reader's, and a screenshot that
        // eats what was on it is a feature you have to think about before using. `-i` is the
        // interactive capture — region by pointer, window by pointer after a space — and `-x` is
        // left off with it: that flag silences the shutter, and the shutter is the platform's answer to
        // a screenshot being taken rather than this app's to remove.
        guard let file = TemporaryImage.path(named: "shot") else {
            // Nothing to say about a temporary directory that cannot be written, and no sentence this
            // side could add would help. A refused *answer* rather than a crash, so the caller has one
            // shape to handle.
            return .refused(.other(""))
        }
        if hiding { NSApp.hide(nil) }
        defer {
            // Always back, including the cancel: the reader is looking at a screen with no window on
            // it, and the app that took itself away is the app that has to come back.
            if hiding {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let answer = await run(["-i", "-t", "png", file.path])
        // The bytes, and then the file taken away. This side is the only one that knows the path, so
        // there is nobody to race — the shell reads a *second* file, written from the marked-up
        // picture, through `/attach-temp`, which is the one path in this app where the shell is the
        // reader and deletes what it read.
        let bytes = try? Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
        return ScreenshotOutcome.of(
            bytes: bytes,
            said: answer.words,
            status: answer.status,
            screenAccess: access
        )
    }

    /// What the tool said, and how it exited.
    ///
    /// Two things because the rule needs both: a cancel is *silent* and exits `0`, a refusal speaks and
    /// exits non-zero (see `ScreenshotOutcome` for the measured table). A helper that returned only the
    /// text would leave the caller unable to tell "nothing happened" from "nothing was said".
    private struct Answer {
        let words: String
        let status: Int32
    }

    /// Run the tool and wait for it, off the main actor.
    ///
    /// The interaction — the crosshair, the drag, the reader changing their mind — lasts as long as the
    /// reader wants it to, and it happens in the system's own overlay. Suspending rather than blocking
    /// is what keeps this app's window alive underneath it; a `Process.waitUntilExit()` on the main
    /// thread would be a window that cannot be told from a hung one for the whole of that time.
    ///
    /// What comes back is what the tool said and its status, never the picture: the picture is in the
    /// file, and a success needs no words to go with it — so the sentence is read to explain a failure
    /// and for nothing else.
    private static func run(_ arguments: [String]) async -> Answer {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tool = Process()
                tool.executableURL = URL(fileURLWithPath: executable)
                tool.arguments = arguments
                let pipe = Pipe()
                // Collected rather than inherited: this process was launched by Finder and its standard
                // error is not a terminal, so a sentence written into it goes nowhere at all — and the
                // sentence is the whole of what a failure that is not a cancel has to say.
                tool.standardError = pipe
                tool.standardOutput = pipe
                do {
                    try tool.run()
                } catch {
                    // The tool is missing or not executable. There is nothing to read from it, and the
                    // caller has a shape for "we have no idea what happened".
                    continuation.resume(returning: Answer(words: "", status: -1))
                    return
                }
                // Read to the end *before* waiting: a child that fills the pipe buffer while its parent
                // waits for it to exit is a deadlock, and a capture error message is long enough to
                // make that reachable in principle.
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                tool.waitUntilExit()
                continuation.resume(
                    returning: Answer(
                        words: String(decoding: data, as: UTF8.self),
                        status: tool.terminationStatus
                    )
                )
            }
        }
    }
}

/// A picture, in the sheet that makes one.
///
/// The window's half of it: the two facts that say *which* sheet is open, and the command that starts a
/// capture. It is here rather than in the composer because **both places the command is written** — the
/// card's `+` menu and the Edit menu, which is where the keystroke lives — have to end up in the same
/// one, and a command written twice is a command that can come to mean two things.
extension WindowActions {
    /// Take a screenshot, and put it on the paper.
    ///
    /// The answer is one of three things and each gets its own ending: the reader cancelled, so nothing
    /// happened and nothing is said about it; the capture was refused, so the window says what the
    /// trouble is; or there is a picture, which is presented as a sheet. There is no fourth ending
    /// where a picture arrives and nothing is shown.
    func screenshot(hiding: Bool) {
        Task {
            switch await Screenshot.take(hiding: hiding) {
            case .cancelled:
                // Deliberately silent. Escape is the reader saying "not this one", and a dialog
                // explaining that they pressed Escape is the dialog the rule in `ScreenshotOutcome`
                // exists to avoid.
                break
            case let .refused(trouble):
                // A refusal is the one moment the permission is *known* to be the explanation, so it is
                // asked for here rather than before the gesture. `CGRequestScreenCaptureAccess()` is the
                // step that puts this app in the Screen Recording list — a reader sent to that pane
                // without it finds no row for wei to switch on, and the bundle is not in /Applications
                // where the pane's own `+` would find it either (see `TCCProbe` for the same call used
                // as a build check).
                if trouble == .permission { CGRequestScreenCaptureAccess() }
                shotTrouble = trouble
            case let .taken(png):
                guard let image = NSImage(data: png) else {
                    // The tool wrote bytes and this side cannot read them. Should not be reachable —
                    // the tool writes a PNG and the format is asked for by name — and if it is, the one
                    // thing that can be said is that there is no picture, which is better than a
                    // gesture that quietly does nothing.
                    shotTrouble = .other("The screenshot could not be read.")
                    return
                }
                picture = .marking(Markup(image: image))
            }
        }
    }
}
