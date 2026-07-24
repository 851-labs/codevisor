import SwiftUI
import AppKit
import CodevisorCore

/// The app-menu "Check for Updates…" item, placed right below Settings.
/// Sparkle owns the progress, release-notes, no-update, and error UI.
struct AppUpdateCommands: Commands {
    let appUpdate: AppUpdateModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            CheckForUpdatesMenuItem(appUpdate: appUpdate)
        }
    }
}

private struct CheckForUpdatesMenuItem: View {
    let appUpdate: AppUpdateModel

    var body: some View {
        Button("Check for Updates…") {
            Task { await appUpdate.checkForUpdates() }
        }
        .disabled(appUpdate.phase == .checking || appUpdate.isUpdating)
    }
}
