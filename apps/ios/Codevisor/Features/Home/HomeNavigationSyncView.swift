import SwiftUI

/// Native iOS catch-up and unavailable presentations for the selected
/// machine's navigation projection. Both replace cached rows so the screen
/// never presents stale data as current.
struct HomeNavigationSyncView: View {
    enum State {
        case loading(machineName: String)
        case failed(machineName: String)
    }

    let state: State
    var retry: (() -> Void)? = nil

    var body: some View {
        switch state {
        case let .loading(machineName):
            DelayedNavigationSyncProgressView(machineName: machineName)
        case let .failed(machineName):
            ContentUnavailableView {
                Label("Unable to Sync", systemImage: "exclamationmark.triangle")
            } description: {
                Text(
                    "Codevisor couldn’t sync with \(machineName). "
                        + "Make sure the machine is online, then try again.")
            } actions: {
                if let retry {
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Fast reconciliations remain visually quiet. SwiftUI cancels the task when
/// catch-up finishes, so a spinner can never flash after this view disappears.
private struct DelayedNavigationSyncProgressView: View {
    let machineName: String

    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            Color.clear

            if showsSpinner {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Syncing with \(machineName)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: machineName) {
            showsSpinner = false
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            showsSpinner = true
        }
    }
}
