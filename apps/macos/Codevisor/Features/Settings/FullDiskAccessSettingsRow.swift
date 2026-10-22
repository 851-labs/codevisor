import CodevisorCoreMac
import SwiftUI

struct FullDiskAccessSettingsRow: View {
  let model: ComputerUsePermissionsModel
  let onSetUp: () -> Void

  var body: some View {
    PermissionRow(
      symbol: "internaldrive",
      title: "Full Disk Access",
      subtitle: subtitle,
      grantedLabel: model.isFullDiskAccessGranted ? "Granted" : nil,
      embedded: true
    ) {
      if model.fullDiskAccessNeedsRestart {
        PermissionActionButton("Restart") { AppRelauncher.relaunch() }
      } else {
        PermissionActionButton("Set Up…", action: onSetUp)
      }
    }
  }

  private var subtitle: String {
    if model.fullDiskAccessNeedsRestart {
      "Applies after Codevisor restarts"
    } else {
      "Agents can reach all your files"
    }
  }
}
