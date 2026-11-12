import CodevisorCoreMac
import SwiftUI

struct LocalNetworkSettingsRow: View {
  let model: ComputerUsePermissionsModel

  var body: some View {
    PermissionRow(
      symbol: "network",
      title: "Local Network",
      subtitle: subtitle,
      embedded: true
    ) {
      PermissionActionButton("Open System Settings") { model.openSettings(.privacyAndSecurity) }
    }
  }

  private var subtitle: String {
    "Direct connections to your machines on the same network. macOS doesn't share this status; "
      + "it's under Privacy & Security › Local Network."
  }
}
