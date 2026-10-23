import CodevisorCoreMac
import SwiftUI

struct ComputerUsePermissionRowsView: View {
  let model: ComputerUsePermissionsModel
  var embedded = false
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    VStack(alignment: .leading, spacing: embedded ? 0 : 12) {
      PermissionCard(embedded: embedded) {
        PermissionRow(
          symbol: "accessibility",
          title: "Accessibility",
          subtitle: "Reads on-screen text and controls",
          grantedLabel: model.isAccessibilityGranted ? "Granted" : nil,
          embedded: embedded
        ) {
          PermissionActionButton("Allow…") { model.requestAccessibility() }
        }
        Divider()
        PermissionRow(
          symbol: "rectangle.dashed.badge.record",
          title: "Screen Recording",
          subtitle: "Sees app windows",
          grantedLabel: model.isScreenRecordingGranted ? "Granted" : nil,
          embedded: embedded
        ) {
          PermissionActionButton("Allow…") { model.requestScreenRecording() }
        }
      }

      if model.screenRecordingGrantedThisRun {
        relaunchNudge
          .padding(.top, embedded ? 8 : 0)
      }
    }
    .task {
      while !Task.isCancelled {
        model.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onChange(of: controlActiveState) { _, _ in
      model.refresh()
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
