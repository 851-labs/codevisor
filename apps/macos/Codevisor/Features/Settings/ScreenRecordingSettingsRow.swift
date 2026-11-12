import CodevisorCoreMac
import SwiftUI

struct ScreenRecordingSettingsRow: View {
  let model: ComputerUsePermissionsModel

  var body: some View {
    PermissionRow(
      symbol: "rectangle.dashed.badge.record",
      title: "Screen Recording",
      subtitle: subtitle,
      grantedLabel: isReady ? "Granted" : nil,
      embedded: true
    ) {
      if model.screenRecordingGrantedThisRun {
        PermissionActionButton("Restart") { AppRelauncher.relaunch() }
      } else {
        PermissionActionButton("Grant") { model.requestScreenRecording() }
      }
    }
  }

  private var isReady: Bool {
    model.isScreenRecordingGranted && !model.screenRecordingGrantedThisRun
  }

  private var subtitle: String {
    if model.screenRecordingGrantedThisRun {
      "Applies after Codevisor restarts"
    } else {
      "Computer Use, live previews, and screen sharing into this Mac"
    }
  }
}
