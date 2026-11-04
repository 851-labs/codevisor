import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarUpdateFooter: View {
  var center: UpdateCenter
  @Environment(\.openSettings) private var openSettings
  @Environment(SidebarHostBridge.self) private var hostBridge: SidebarHostBridge?
  @State private var isHovered = false

  var body: some View {
    if center.availableCount > 0 || center.isUpdatingAll {
      VStack(spacing: 0) {
        Hairline(color: .separatorColor)
        Button {
          SettingsRouter.shared.showUpdates()
          if let hostOpenSettings = hostBridge?.openSettings { hostOpenSettings() } else { openSettings() }
        } label: {
          HStack(spacing: 6) {
            if center.isUpdatingAll {
              ProgressView()
                .controlSize(.mini)
              Text("Updating…")
            } else {
              Image(systemName: "arrow.down.circle")
              Text(
                center.availableCount == 1
                  ? "1 update available"
                  : "\(center.availableCount) updates available"
              )
            }
            Spacer(minLength: 0)
          }
          .font(.callout)
          .foregroundStyle(isHovered ? .primary : .secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHover($isHovered)
        .accessibilityLabel("Updates available. Opens Settings › Updates.")
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}
