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
      LaunchCover(runtime: runtime) {
        if let environment = runtime.environment {
          FirstLaunchSetupOverlay(setup: runtime.firstLaunchSetup, landing: runtime.firstLaunchLanding) {
            RootView()
              .modifier(DebugMetricsOverlayModifier())
          }
          .modifier(FolderAccessGate(folders: runtime.firstRunFolders))
          .modifier(GitRequirement(machines: environment.machines))
          .appWindowRoot(environment)
          .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
      }
      .frame(minWidth: 480, minHeight: 600)
      .task { await runtime.startIfNeeded() }
    }
    .defaultSize(width: 1280, height: 820)
    .windowResizability(.contentMinSize)
    .windowIdealSize(.maximum)
    .commands {
      if let environment = runtime.environment {
        AppUpdateCommands(environment: environment)
        FileCommands()
        CommandPaletteCommands()
        PanelToggleCommands()
        WorkspaceLayoutCommands()
        BrowserCommands()
        SimulatorCommands()
        DebugOverlayCommands()
      }
    }
  }
}
