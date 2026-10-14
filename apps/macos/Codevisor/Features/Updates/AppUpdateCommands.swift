import AppKit
import CodevisorCore
import SwiftUI

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
