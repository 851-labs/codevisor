import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ChromeExtensionSetupSheet: View {
  let request: TranscriptSetupRequest
  let controller: SessionController

  @Environment(\.dismiss) private var dismiss
  @State private var didOpenExtensions = false

  private var state: TranscriptSetupRequest.State {
    controller.setupRequest(id: request.id)?.state ?? request.state
  }

  var body: some View {
    SetupSheet(
      symbol: "puzzlepiece.extension",
      title: "Connect Chrome",
      primaryTitle: "Done",
      canContinue: state == .setUp,
      onCancel: decline,
      onContinue: { dismiss() }
    ) {
      PermissionRow(
        symbol: "globe",
        title: "Open Chrome’s Extensions page",
        grantedLabel: didOpenExtensions || state == .setUp ? "Opened" : nil
      ) {
        PermissionActionButton("Open…") {
          didOpenExtensions = true
          Task { await controller.performBrowserExtensionSetupAction("Open Extensions") }
        }
      }
      Divider()
      PermissionRow(
        symbol: "hand.draw",
        title: "Drag the extension into Chrome",
        grantedLabel: state == .setUp ? "Connected" : nil
      ) {
        ChromeExtensionFileChip(controller: controller)
      }
    }
    .onChange(of: state) { _, state in
      if state == .declined { dismiss() }
    }
  }

  private func decline() {
    Task { await controller.declineSetupRequest(request.id) }
    dismiss()
  }
}
