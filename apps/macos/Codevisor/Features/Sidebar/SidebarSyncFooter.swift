import CodevisorCore
import CodevisorUI
import SwiftUI

/// A quiet line at the sidebar's foot while machines catch up, or naming the
/// ones that can't be reached. The sidebar keeps showing what the Mac already
/// knows either way; this only says it may be out of date.
struct SidebarSyncFooter: View {
  var indicator: NavigationPresentation.SyncIndicator
  @Environment(\.theme) private var theme

  var body: some View {
    if let label = indicator.label {
      VStack(spacing: 0) {
        Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
        HStack(spacing: 6) {
          if indicator.unreachableMachineNames.isEmpty {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "exclamationmark.icloud")
          }
          Text(label)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}
