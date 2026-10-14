import CodevisorCore
import CodevisorUI
import SwiftUI

/// The one ambient signal that updates exist, pinned to the sidebar's
/// bottom edge. Passive by design — no versions, no per-component detail,
/// and nothing to dismiss; clicking opens Settings › Updates. Hidden
/// entirely when everything is current.
struct SidebarUpdateFooter: View {
  var center: UpdateCenter
  @Environment(\.theme) private var theme
  @Environment(\.openSettings) private var openSettings
  @Environment(\.sidebarOpenSettings) private var sidebarOpenSettings
  @State private var isHovered = false

  var body: some View {
    if center.availableCount > 0 || center.isUpdatingAll {
      VStack(spacing: 0) {
        Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
        Button {
          SettingsRouter.shared.showUpdates()
          if let sidebarOpenSettings { sidebarOpenSettings() } else { openSettings() }
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
        .onHover { isHovered = $0 }
        .accessibilityLabel("Updates available. Opens Settings › Updates.")
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}

extension EnvironmentValues {
  /// Opens Settings from sidebar content hosted outside the scene's view
  /// graph (see `SidebarVibrancyHost`), where `openSettings` can't reach.
  @Entry var sidebarOpenSettings: SidebarOpenSettingsAction? = nil
}

/// Opens Settings on behalf of the scene that hosts the sidebar.
struct SidebarOpenSettingsAction {
  let open: @MainActor () -> Void

  @MainActor func callAsFunction() { open() }
}
