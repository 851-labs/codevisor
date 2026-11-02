import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ClientDataLaunchView: View {
  let runtime: AppRuntime

  var body: some View {
    Group {
      if let setup = runtime.firstLaunchSetup {
        FirstLaunchPreparationView(
          setup: setup,
          failure: runtime.startupError,
          retry: runtime.retry,
          showDataFolder: Self.showDataFolder
        )
      } else if let startupError = runtime.startupError {
        ClientDataStartupFailureView(message: startupError, retry: runtime.retry, showDataFolder: Self.showDataFolder)
      } else {
        FirstLaunchStartingView()
      }
    }
    .task { await runtime.startIfNeeded() }
  }

  private static func showDataFolder() {
    NSWorkspace.shared.activateFileViewerSelecting([CodevisorAppVariant.applicationSupportURL()])
  }
}
