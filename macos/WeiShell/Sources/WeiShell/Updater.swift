import AppKit
import Combine
import Sparkle
import WeiKit

/// Updates.
///
/// Sparkle does the work. This type is the three decisions about *how* it does it, and each one is a
/// decision rather than a setting, because each has an answer that would be wrong here:
///
/// **Checks are automatic, and the reader is never asked whether they should be.** Sparkle's default
/// first launch puts up "Check for updates automatically?" — a question about a preference nobody has
/// an opinion about yet, asked before the reader has used the app once, whose only honest answer is
/// "yes". The keys in `Info.plist` (`SUEnableAutomaticChecks` and `SUFeedURL`, written by
/// `make-app.sh`) and the two property assignments below are what suppress it. The reader who wants
/// the opposite finds the switch in Sparkle's own settings, which is where a Mac user looks for it.
///
/// **Downloads are automatic.** The cost is bandwidth on someone else's connection; the benefit is
/// that by the time a reader is told an update exists, it is already on disk and installing costs them
/// nothing. That ordering — the interruption arrives after the work is done — is the whole reason to
/// download early.
///
/// **Installing happens on quit, not on a click.** Sparkle offers three timings and only one of them
/// is right for this app: it will *not* be told to quit and relaunch the moment a download finishes
/// (the reader would lose a running turn, and the window would blink), and it will not wait for a
/// confirmation dialog. It downloads in the background, and the swap happens when this process is
/// already ending — so an update costs the reader nothing except the restart they were going to make
/// anyway.
///
/// The one thing beyond Sparkle's defaults is `shouldPostponeRelaunchForUpdate:`: a reader *can* still
/// ask for "install and relaunch" from Sparkle's own UI, and doing that mid-turn would kill the turn.
/// The delegate below refuses the relaunch while anything is in flight and continues it once nothing
/// is — see `watchForIdle`.
///
/// Nothing here is on the critical path of the app: a machine with no network, a feed that has moved,
/// or a key that does not match all end in Sparkle saying so in its own window, and the app itself is
/// unaffected. That is deliberate — an updater that can stop the product from working is worse than no
/// updater.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Whether the reader may ask for a check right now, kept here because a menu item has to be
    /// enabled or disabled and SwiftUI needs something published to redraw on. Sparkle documents
    /// `canCheckForUpdates` as KVO-compliant, which is what makes observing it below legitimate rather
    /// than a guess — a property that is not compliant fails silently, leaving a menu item that is
    /// wrong in the one moment the reader is looking at it.
    @Published private(set) var canCheckForUpdates = false

    /// The shell, asked one question — whether anything of the reader's is in flight. Weak, because
    /// the shell outlives this in every direction that matters and the updater does not own it.
    private weak var client: ShellClient?

    /// Started explicitly rather than at construction: Sparkle wants
    /// `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates` set *before* the updater
    /// starts, and constructing it here would mean `self` is not yet available to pass as the delegate.
    /// `lazy` is what lets both be true.
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    /// Sparkle's "carry on with the relaunch", held for as long as a turn is in flight.
    private var pendingRelaunch: (() -> Void)?
    /// The loop that waits for the shell to go quiet. See `watchForIdle`.
    private var idleWatch: Task<Void, Never>?

    /// Start checking for updates. Idempotent, because the caller is a view's `onAppear`.
    func start(client: ShellClient) {
        guard !started else { return }
        started = true
        self.client = client

        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        controller.startUpdater()

        updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
            }
            .store(in: &cancellables)
    }

    /// The menu item. A check already in flight is Sparkle's to deal with, which is why the item is
    /// disabled rather than the call guarded here.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    /// Refuse to relaunch while a turn is running, and continue once it is not.
    ///
    /// This is the one place the update and the work in the window meet, and the window's side of it is
    /// the reason the app has a session model at all: a turn is the reader's, it takes minutes, and it
    /// can be running in a session they are not looking at. Restarting the process to install a new
    /// version is the one action that destroys it, so it waits.
    ///
    /// Cancelling the turn instead is the obvious wrong answer — the update is not worth the work, and
    /// a reader who is asked to choose will rightly resent the interruption. Note that Sparkle
    /// installs on quit regardless of this method, so the deferred relaunch is a *convenience*: a
    /// reader who ignores the notification and quits later still gets the update, and the handler goes
    /// away with the process.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard isWorking else { return false }
        pendingRelaunch = installHandler
        watchForIdle()
        return true
    }

    private var isWorking: Bool { client?.isWorking ?? false }

    /// Wait for the shell to have nothing in flight, then continue the relaunch.
    ///
    /// A one-second loop rather than an observation of the shell's own published state, and that is a
    /// deliberate trade: the shell has no single value that means "idle" — the sidebar's rows (which
    /// know about background sessions) arrive on a two-second tick, and the transcript on screen is
    /// immediate — so anything built out of `objectWillChange` and a re-read would be this loop with
    /// more machinery and less to say. It runs only while a relaunch is pending, and stops the moment
    /// one is not, so its cost is bounded by a few seconds once per update.
    ///
    /// The alternative — returning `true` and never calling the handler — is not a stall that harms
    /// anyone (quitting installs anyway), but it leaves a reader who *did* press "relaunch" waiting on
    /// a promise nothing is keeping.
    private func watchForIdle() {
        guard idleWatch == nil else { return }
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if !self.isWorking { break }
            }
            guard let self else { return }
            self.idleWatch = nil
            let continueRelaunch = self.pendingRelaunch
            self.pendingRelaunch = nil
            continueRelaunch?()
        }
    }
}
