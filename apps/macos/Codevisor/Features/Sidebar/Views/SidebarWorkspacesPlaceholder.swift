import CodevisorUI
import SwiftUI

struct SidebarWorkspacesPlaceholder: View {
  let onNewChat: () -> Void

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: WorkspaceListEmptyCopy.systemImage)
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 6)
      Text(WorkspaceListEmptyCopy.title)
        .font(.headline)
      Text(WorkspaceListEmptyCopy.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(ShortcutCatalog.title(for: .newChat), action: onNewChat)
        .buttonStyle(.borderedProminent)
        .padding(.top, 10)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
