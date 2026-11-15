import CodevisorCore
import CodevisorCoreMac
import Foundation

@MainActor
final class MachineDesktops {
  static let shared = MachineDesktops()

  private var preferences: [String: ScreenSharingPanePreferences] = [:]
  private var panes: [String: NSHashTable<ScreenSharingPane>] = [:]

  func pane(
    on machine: CodevisorMachine, role: ScreenSharingViewerRole, shownInWorkspace workspaceId: UUID
  ) -> ScreenSharingPane {
    let pane = ScreenSharingPane(
      machine: machine, role: role, workspace: ScreenSharingPaneWorkspace(workspaceId),
      preferences: preferences[machine.id] ?? .init())
    pane.onPreferencesChanged = { [weak self, weak pane] in self?.changed($0, on: machine.id, by: pane) }
    panes[machine.id, default: .weakObjects()].add(pane)
    return pane
  }

  private func changed(_ changed: ScreenSharingPanePreferences, on machineId: String, by pane: ScreenSharingPane?) {
    preferences[machineId] = changed
    for other in panes[machineId]?.allObjects ?? [] where other !== pane { other.applyPreferences(changed) }
  }
}
