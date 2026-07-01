import SwiftUI
import AppKit
import HerdManCore

/// The app-menu "Check for Updates…" item, placed right below Settings.
/// The scheduled launch check is silent; this manual check reports its
/// outcome: an alert when already up to date (or when the check fails), and
/// the sidebar update banner when a newer release is found.
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
            Task { await check() }
        }
        .disabled(appUpdate.phase == .checking || appUpdate.isUpdating)
    }

    private func check() async {
        await appUpdate.checkForUpdates()
        switch appUpdate.phase {
        case .upToDate:
            showAlert(
                title: "You're up to date",
                message: "HerdMan \(appUpdate.currentVersion) is the latest version."
            )
        case .idle:
            // checkForUpdates resolves to .idle only when the check threw.
            showAlert(
                title: "Couldn't check for updates",
                message: "The update check failed. Check your internet connection and try again."
            )
        case .available:
            // The sidebar banner presents the release; un-skip it in case this
            // version's banner was dismissed earlier. (Same @AppStorage key as
            // SidebarView's skippedUpdateVersion.)
            UserDefaults.standard.set("", forKey: "update.skippedVersion")
        case .checking, .updating, .failed:
            break
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
