import SwiftUI

struct WorkspaceRowAccessibilityActions: View {
  let lifecycle: WorkspaceRowLifecycle

  var body: some View {
    switch lifecycle {
    case let .active(actions):
      Button(actions.isPinned ? "Unpin" : "Pin", action: actions.togglePin)
      Button("Rename", action: actions.rename)
      Button("Archive", action: actions.archive)
    case let .archived(onRestore):
      Button("Restore", action: onRestore)
    }
  }
}
