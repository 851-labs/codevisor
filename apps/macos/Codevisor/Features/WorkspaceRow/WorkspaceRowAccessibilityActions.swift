import SwiftUI

struct WorkspaceRowAccessibilityActions: View {
  let lifecycle: WorkspaceRowLifecycle

  var body: some View {
    switch lifecycle {
    case let .active(actions):
      if let pin = actions.pin {
        Button(pin.title, action: pin.toggle)
      }
      Button("Rename", action: actions.rename)
      Button("Archive", action: actions.archive)
    case let .archived(onRestore):
      Button("Restore", action: onRestore)
    }
  }
}
