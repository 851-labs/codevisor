import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct ClientSettingsScene: Scene {
  let runtime: AppRuntime

  var body: some Scene {
    Settings {
      if let environment = runtime.environment {
        SettingsView()
          .themedRoot()
          .environment(environment)
      } else if let startupError = runtime.startupError {
        ClientDataStartupFailureView(
          message: startupError,
          retry: runtime.retry,
          showDataFolder: {
            NSWorkspace.shared.activateFileViewerSelecting([
              CodevisorAppVariant.applicationSupportURL()
            ])
          }
        )
      } else {
        ClientDataStartupView()
          .task { await runtime.startIfNeeded() }
      }
    }
  }
}
