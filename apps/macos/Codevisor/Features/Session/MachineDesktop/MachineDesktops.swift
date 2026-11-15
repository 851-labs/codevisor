import CodevisorCore
import CodevisorCoreMac
import Foundation

@MainActor
final class MachineDesktops {
  static let shared = MachineDesktops()

  func pane(
    on machine: CodevisorMachine, role: ScreenSharingViewerRole, shownInWorkspace workspaceId: UUID
  ) -> ScreenSharingPane {
    ScreenSharingPane(
      machine: machine, role: role, workspace: ScreenSharingPaneWorkspace(workspaceId), preferences: .init())
  }
}
