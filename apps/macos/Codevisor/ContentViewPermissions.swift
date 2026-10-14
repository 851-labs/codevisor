import CodevisorCore
import CodevisorCoreMac
import SwiftUI

@MainActor
func reconcileSkippedPermissions(environment: AppEnvironment) async {
  guard !AppPreview.isRunning, environment.settings.permissionsSetupSkipped else { return }
  let probes = ComputerUsePermissionProbes.live
  if probes.isAccessibilityGranted() && probes.isScreenRecordingGranted() {
    environment.settings.setPermissionsSetupSkipped(false)
    return
  }
  for attempt in 0..<30 {
    if let servers = try? await environment.machines
      .client(for: CodevisorMachine.local.id).listMcpServers(),
      let computer = servers.first(where: { $0.kind == "computerUse" })
    {
      if computer.enabled {
        await McpFleet.disableLocally(
          environment.configSync,
          machines: environment.machines,
          name: computer.name
        )
      }
      return
    }
    if attempt < 29 {
      try? await Task.sleep(for: .seconds(2))
    }
  }
}
