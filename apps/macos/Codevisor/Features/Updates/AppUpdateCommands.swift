import AppKit
import CodevisorCore
import SwiftUI

/// The app-menu "Check for Updates…" item, placed right below Settings.
/// Opens the update center — the one surface for everything updatable —
/// with a fresh fleet-wide check under way.
struct AppUpdateCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            CheckForUpdatesMenuItem(center: environment.updateCenter)
        }
    }
}

private struct CheckForUpdatesMenuItem: View {
    let center: UpdateCenter

    var body: some View {
        Button("Check for Updates…") {
            center.isPresented = true
        }
    }
}
