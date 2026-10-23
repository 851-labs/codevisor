import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct ComputerUseSetupSheet: View {
  let request: TranscriptSetupRequest
  let controller: SessionController

  @Environment(\.dismiss) private var dismiss
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var model = ComputerUsePermissionsModel(
    probes: AppPreview.isRunning ? .granted : .live
  )

  var body: some View {
    SetupSheet(
      symbol: "macwindow.and.cursorarrow",
      title: "Allow Computer Use",
      primaryTitle: "Continue",
      canContinue: model.isAccessibilityGranted,
      onCancel: decline,
      onContinue: complete
    ) {
      PermissionRow(
        symbol: "accessibility",
        title: "Accessibility",
        subtitle: "Reads on-screen text and controls",
        grantedLabel: model.isAccessibilityGranted ? "Granted" : nil
      ) {
        PermissionActionButton("Allow…") { model.requestAccessibility() }
      }
      Divider()
      PermissionRow(
        symbol: "rectangle.dashed.badge.record",
        title: "Screen Recording",
        subtitle: "Sees app windows",
        grantedLabel: model.isScreenRecordingGranted ? "Granted" : nil
      ) {
        PermissionActionButton("Allow…") { model.requestScreenRecording() }
      }
      if model.screenRecordingGrantedThisRun {
        Divider()
        PermissionRow(symbol: "arrow.clockwise", title: "Restart to finish Screen Recording") {
          PermissionActionButton("Restart") { AppRelauncher.relaunch() }
        }
      }
    }
    .task {
      while !Task.isCancelled {
        model.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onChange(of: controlActiveState) { _, _ in model.refresh() }
    .onChange(of: controller.setupRequest(id: request.id)?.state) { _, state in
      if state != .pending { dismiss() }
    }
  }

  private func complete() {
    Task { await controller.completeSetupRequest(request.id) }
    dismiss()
  }

  private func decline() {
    Task { await controller.declineSetupRequest(request.id) }
    dismiss()
  }
}
