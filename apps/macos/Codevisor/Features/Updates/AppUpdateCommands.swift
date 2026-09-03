import AppKit
import CodevisorCore
import SwiftUI

/// The app-menu "Check for Updates…" item, placed right below Settings.
/// Opens Settings › Updates — the one surface for everything updatable —
/// which runs a fresh fleet-wide check as it appears.
struct AppUpdateCommands: Commands {
  let environment: AppEnvironment

  var body: some Commands {
    CommandGroup(after: .appSettings) {
      CheckForUpdatesMenuItem()
    }
  }
}

private struct CheckForUpdatesMenuItem: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Check for Updates…") {
      SettingsRouter.shared.showUpdates()
      openSettings()
    }
  }
}
