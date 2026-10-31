import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct MainWindowScene: Scene {
  static let id = "main"

  let runtime: AppRuntime

  var body: some Scene {
    WindowGroup(id: Self.id) {
      if let environment = runtime.environment {
        RootView()
          .frame(minWidth: 480, minHeight: 600)
          .modifier(DebugMetricsOverlayModifier())
          .overlay {
            if let setup = runtime.firstLaunchSetup, let landing = runtime.firstLaunchLanding {
              FirstLaunchSetupOverlay(setup: setup, landing: landing)
            }
          }
          .appWindowRoot(environment)
          .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
        .frame(minWidth: 480, minHeight: 600)
      } else {
        ClientDataStartupView()
          .frame(minWidth: 480, minHeight: 600)
          .task { await runtime.startIfNeeded() }
      }
    }
    .defaultSize(width: 1280, height: 820)
    .windowResizability(.contentMinSize)
    .windowIdealSize(.maximum)
    .commands {
      if let environment = runtime.environment {
        AppUpdateCommands(environment: environment)
        FileCommands()
        CommandPaletteCommands()
        WorkspaceLayoutCommands()
        BrowserCommands()
        SimulatorCommands()
        DebugOverlayCommands()
      }
    }
  }
}
