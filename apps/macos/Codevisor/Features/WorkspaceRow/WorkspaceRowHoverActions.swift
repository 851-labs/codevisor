import SwiftUI

struct WorkspaceRowHoverActions: View {
  let lifecycle: WorkspaceRowLifecycle
  let title: String

  var body: some View {
    HStack(spacing: WorkspaceRow.trailingSpacing) {
      switch lifecycle {
      case let .active(actions):
        button(
          systemImage: actions.isPinned ? "pin.slash" : "pin",
          help: actions.isPinned ? "Unpin workspace" : "Pin workspace",
          label: actions.isPinned ? "Unpin" : "Pin",
          action: actions.togglePin
        )
        button(systemImage: "archivebox", help: "Archive workspace", label: "Archive", action: actions.archive)
      case let .archived(onRestore):
        button(systemImage: "arrow.uturn.backward", help: "Restore workspace", label: "Restore", action: onRestore)
      }
    }
    .contentShape(Rectangle())
  }

  private func button(
    systemImage: String, help: String, label: String, action: @escaping () -> Void
  ) -> some View {
    SidebarRowHoverButton(
      systemImage: systemImage, help: help, accessibilityLabel: "\(label) \(title)", action: action)
  }
}
