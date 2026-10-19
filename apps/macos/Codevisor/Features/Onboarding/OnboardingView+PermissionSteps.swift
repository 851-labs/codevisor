import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

extension OnboardingView {
  var localNetworkStep: some View {
    permissionStep(
      symbol: "network",
      title: "Local Network",
      subtitle: "Connect to your machines directly over the local network when available."
    ) {
      PermissionCard {
        PermissionRow(
          symbol: "network",
          title: "Local Network Access",
          subtitle: "macOS will ask you to confirm",
          grantedLabel: environment.localNetworkAccess == .requested ? "Requested" : nil
        ) {
          PermissionActionButton("Allow…") { environment.setLocalNetworkAccess(.requested) }
        }
      }
    }
  }

  var computerUseStep: some View {
    permissionStep(
      symbol: "cursorarrow.rays",
      title: "Computer Use",
      subtitle: "Let agents see and control your apps."
    ) {
      ComputerUsePermissionRowsView(model: permissions)
    }
  }

  var fullDiskAccessStep: some View {
    permissionStep(
      symbol: "internaldrive",
      title: "Full Disk Access",
      subtitle: "No more file prompts. Agents can reach all your files."
    ) {
      PermissionCard {
        if permissions.isFullDiskAccessGranted {
          PermissionRow(symbol: "internaldrive", title: "Full Disk Access", grantedLabel: "Granted") {
            EmptyView()
          }
        } else {
          PermissionRow(symbol: "gearshape", title: "Open Full Disk Access") {
            PermissionActionButton("Open…") {
              permissions.requestFullDiskAccess()
              FullDiskAccessDragPanel.shared.show()
            }
          }
          Divider()
          PermissionRow(symbol: "hand.draw", title: "Drag Codevisor into the list") {
            AppDragChip()
          }
        }
      }
    }
    .onChange(of: permissions.isFullDiskAccessGranted) { _, granted in
      if granted { FullDiskAccessDragPanel.shared.close() }
    }
    .onDisappear { FullDiskAccessDragPanel.shared.close() }
    .task {
      while !Task.isCancelled {
        permissions.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func permissionStep(
    symbol: String,
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(spacing: 20) {
      stepHeader(symbol: symbol, title: title, subtitle: subtitle)
      content()
    }
    .frame(maxWidth: .infinity)
  }
}
