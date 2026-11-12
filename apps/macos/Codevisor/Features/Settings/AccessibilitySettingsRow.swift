import CodevisorCoreMac
import SwiftUI

struct AccessibilitySettingsRow: View {
  let model: ComputerUsePermissionsModel

  var body: some View {
    PermissionRow(
      symbol: "accessibility",
      title: "Accessibility",
      subtitle: "Computer Use clicks and typing, and remote control when someone shares this Mac's screen",
      grantedLabel: model.isAccessibilityGranted ? "Granted" : nil,
      embedded: true
    ) {
      PermissionActionButton("Grant") { model.requestAccessibility() }
    }
  }
}
