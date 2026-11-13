import AppKit
import CodevisorCore

struct LaunchActions {
  let tryAgain: (LaunchFailure) -> Void
  let continueAnyway: (LaunchFailure) -> Void
  let showDataFolder: () -> Void

  static func showDataFolder() {
    NSWorkspace.shared.activateFileViewerSelecting([CodevisorAppVariant.applicationSupportURL()])
  }
}
