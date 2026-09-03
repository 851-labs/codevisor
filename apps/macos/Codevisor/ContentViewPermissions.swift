import CodevisorCore
import CodevisorCoreMac
import SwiftUI

/// Heals a half-applied "Set Up Later": the skip choice persists locally
/// but the Computer Use disable is a server call that can be lost (the
/// app may quit before it lands). Skipped + permissions missing means
/// Computer Use must be off; skipped + permissions granted means the
/// skip is obsolete.
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
