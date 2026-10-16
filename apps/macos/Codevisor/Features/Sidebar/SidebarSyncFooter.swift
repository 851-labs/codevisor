import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarSyncFooter: View {
  var indicator: NavigationPresentation.SyncIndicator

  var body: some View {
    if let label = indicator.label {
      VStack(spacing: 0) {
        Hairline(color: .separatorColor)
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
