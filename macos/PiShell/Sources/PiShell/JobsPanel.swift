import SwiftUI

import PiKit
import PiModel

/// The background jobs, as the workspace column draws them.
///
/// A row drawn in the sidebar rather than a popover from the toolbar, because there is now a *section* for
/// them in that column and a register living in two places is a register that disagrees with itself. The web
/// UI keeps its equivalent ("Background") in the sidebar for the same reason, and the kill control travels
/// with the row — a list that names a runaway process and cannot stop it is a list you then have to search
/// for the way to stop it.
/// One job: what it is, how long it has been going, and the way to stop it.
struct JobRow: View {
    let job: Job
    let onKill: () -> Void

    @State private var confirmingKill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(job.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.label)
                Spacer(minLength: 6)
                Button("Kill") { confirmingKill = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack(spacing: 6) {
                Text(job.status)
                    .foregroundStyle(job.isStopping ? .orange : .secondary)
                Text("·")
                // The age is drawn from the last snapshot rather than counted locally: the shell
                // sends it every couple of seconds, and a second clock ticking here would be a second
                // answer to "how long has this been running".
                Text(job.age())
                    .monospacedDigit()
                if !job.pids.isEmpty {
                    Text("·")
                    Text("pid \(job.pids.map(String.init).joined(separator: ", "))")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Stop “\(job.label)”?",
            isPresented: $confirmingKill,
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) { onKill() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Says what "everything" means, because it is the part a reader would not guess: the kill
            // reaches every pid ever recorded, not just the shell that was visible.
            Text("Every process this job started, not just the one it was launched with.")
        }
    }
}
