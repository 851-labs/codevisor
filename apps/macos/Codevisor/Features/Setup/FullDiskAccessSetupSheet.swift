import CodevisorCoreMac
import SwiftUI

struct FullDiskAccessSetupSheet: View {
  let model: ComputerUsePermissionsModel

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SetupSheet(
      symbol: "internaldrive",
      title: "Allow Full Disk Access",
      primaryTitle: model.fullDiskAccessNeedsRestart ? "Restart" : "Done",
      canContinue: model.isFullDiskAccessAllowed,
      onCancel: { dismiss() },
      onContinue: finish
    ) {
      PermissionRow(symbol: "gearshape", title: "Open Full Disk Access") {
        PermissionActionButton("Open…") {
          model.requestFullDiskAccess()
          FullDiskAccessDragPanel.shared.show()
        }
      }
      Divider()
      PermissionRow(
        symbol: "hand.draw",
        title: "Drag Codevisor into the list",
        grantedLabel: model.isFullDiskAccessAllowed ? "Granted" : nil
      ) {
        AppDragChip()
      }
    }
    .onChange(of: model.isFullDiskAccessAllowed) { _, allowed in
      if allowed { FullDiskAccessDragPanel.shared.close() }
    }
    .onDisappear { FullDiskAccessDragPanel.shared.close() }
    .task {
      while !Task.isCancelled {
        model.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func finish() {
    guard model.fullDiskAccessNeedsRestart else { return dismiss() }
    AppRelauncher.relaunch()
  }
}
