import SwiftUI

/// Previous and Next Agent, in the View menu under the sidebar's own
/// command: the sidebar's rows, as ⇧⌘[ and ⇧⌘] are the tab bar's.
struct AgentNavigationCommands: Commands {
  @FocusedValue(\.sidebarActions) private var sidebarActions

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      ShortcutButton(.previousAgent) { sidebarActions?.stepAgent(-1) }
        .disabled(sidebarActions == nil)
      ShortcutButton(.nextAgent) { sidebarActions?.stepAgent(1) }
        .disabled(sidebarActions == nil)
    }
  }
}
