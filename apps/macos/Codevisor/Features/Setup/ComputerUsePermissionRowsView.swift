import CodevisorCoreMac
import SwiftUI

struct ComputerUsePermissionRowsView: View {
  let model: ComputerUsePermissionsModel

  var body: some View {
    PermissionRow(
      symbol: "accessibility",
      title: "Accessibility",
      subtitle: "Reads on-screen text and controls",
      grantedLabel: model.isAccessibilityGranted ? "Granted" : nil,
      embedded: true
    ) {
      PermissionActionButton("Allow…") { model.requestAccessibility() }
    }
    .modifier(PermissionPolling { model.refresh() })

    PermissionRow(
      symbol: "rectangle.dashed.badge.record",
      title: "Screen Recording",
      subtitle: "Sees app windows",
      grantedLabel: model.isScreenRecordingGranted ? "Granted" : nil,
      embedded: true
    ) {
      PermissionActionButton("Allow…") { model.requestScreenRecording() }
    }

    if model.screenRecordingGrantedThisRun {
      relaunchNudge
    }
  }

  private var relaunchNudge: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.clockwise.circle.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Text("Screen Recording applies after Codevisor restarts")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button("Restart Now") { AppRelauncher.relaunch() }
        .controlSize(.small)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
  }
}
