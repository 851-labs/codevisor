import CodevisorCoreMac
import SwiftUI

struct FullDiskAccessSetupSheet: View {
  let model: ComputerUsePermissionsModel

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SetupSheet(
      symbol: "internaldrive",
      title: "Allow Full Disk Access",
      primaryTitle: "Done",
      canContinue: model.isFullDiskAccessGranted,
      onCancel: { dismiss() },
      onContinue: { dismiss() }
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
        grantedLabel: model.isFullDiskAccessGranted ? "Granted" : nil
      ) {
        AppDragChip()
      }
    }
    .onChange(of: model.isFullDiskAccessGranted) { _, granted in
      if granted { FullDiskAccessDragPanel.shared.close() }
    }
    .onDisappear { FullDiskAccessDragPanel.shared.close() }
    .task {
      while !Task.isCancelled {
        model.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}
