import SwiftUI

import PiKit
import PiModel

/// What is still running: the work that outlived the tool call that started it.
///
/// The register opens from the transcript's toolbar rather than sitting in the window, because it is
/// an exception report. Most of the time nothing is running and the panel would be an empty box; when
/// something *is* running — a dev server, a `sleep` from an hour ago — it is the only place that says
/// so, and the moment a reader wants it is the moment they notice the machine is busy.
///
/// Not a separate window: a job belongs to a session, and this is a list the reader checks and closes.
struct JobsPanel: View {
    @ObservedObject var client: PiClient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if client.jobs.isEmpty {
                empty
            } else {
                List(client.jobs) { job in
                    JobRow(job: job, onKill: { client.killJob(job.id) })
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 380, height: 260)
        .onAppear { client.refreshJobs() }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Nothing running")
                .fontWeight(.medium)
            // Said rather than implied, because "nothing running" is ambiguous: it could mean the
            // list is broken. What would appear here is a process the agent left behind — a server,
            // a long command — after the call that started it returned.
            Text("Background jobs started by the agent appear here while their process is alive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One job: what it is, how long it has been going, and the way to stop it.
private struct JobRow: View {
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
