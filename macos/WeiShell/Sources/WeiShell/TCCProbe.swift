import CoreGraphics
import Foundation

/// A probe for the one thing a build cannot answer about itself: whether macOS still recognises this
/// app after it has been rebuilt.
///
/// A permission (TCC) is granted to the app's *designated requirement*. Under ad-hoc signing that
/// requirement contains the build's **cdhash**, so every rebuild is a new app to macOS and every
/// rebuild asks again; with a stable signing identity it contains the **certificate** instead, which
/// does not change. `macos/make-app.sh` signs with one identity for that reason, and this is how the
/// claim is checked rather than assumed.
///
/// Off unless asked for, because the question belongs to a build check and not to a reader's session:
///
///     open --env WEI_TCC_REQUEST=1 --env WEI_TCC_PROBE=/tmp/wei-tcc "macos/dist/wei Agent.app"
///
/// `WEI_TCC_REQUEST` is what makes macOS show its prompt. Without it this only reads the current
/// answer — which is the check that matters *after* a rebuild: the same command with the request left
/// out has to still report `granted=true`, without a prompt.
///
/// Launch it with `open`, not by running the binary inside the bundle. LaunchServices makes the app
/// its own responsible process; a binary started from a shell can have the permission attributed to
/// the shell instead, which would answer a different question.
enum TCCProbe {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["WEI_TCC_PROBE"], !path.isEmpty else { return }

        // Read before asking, so the file says which of the two happened: a grant that was already
        // there, or one this run caused.
        let before = CGPreflightScreenCaptureAccess()
        var requested = false
        if env["WEI_TCC_REQUEST"] == "1" {
            // Shows the system prompt the first time and records this app in the Screen Recording
            // list, unswitched. The answer only takes effect on the next launch, which is why the
            // status after the call is reported separately rather than treated as the outcome.
            requested = CGRequestScreenCaptureAccess()
        }
        let after = CGPreflightScreenCaptureAccess()

        // The bundle identity is written next to the answer on purpose: the claim being checked is
        // about *which app* macOS thinks this is, and these are the two names it goes by.
        let text = """
        granted_before=\(before)
        requested=\(requested)
        granted_after=\(after)
        bundle_id=\(Bundle.main.bundleIdentifier ?? "<none>")
        bundle_path=\(Bundle.main.bundlePath)

        """
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
