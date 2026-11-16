import CodevisorCore
import CodevisorCoreMac
import Foundation

@MainActor
final class MachineDesktops {
  static let shared = MachineDesktops()

  func pane(on machine: CodevisorMachine, role: ScreenSharingViewerRole) -> ScreenSharingPane {
    ScreenSharingPane(machine: machine, role: role, preferences: .init())
  }
}
