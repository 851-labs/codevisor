import SwiftUI

struct WorkspaceRowHoverActions: View {
  let lifecycle: WorkspaceRowLifecycle
  let title: String

  var body: some View {
    HStack(spacing: WorkspaceRow.trailingSpacing) {
      switch lifecycle {
      case let .active(actions):
        if let pin = actions.pin {
          button(
            systemImage: pin.systemImage, help: "\(pin.title) \(actions.noun)", label: pin.title, action: pin.toggle)
        }
        button(
          systemImage: "archivebox", help: "Archive \(actions.noun)", label: "Archive", action: actions.archive)
      case .fixed:
        EmptyView()
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
