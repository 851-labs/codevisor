import SwiftUI

struct PanelToggleCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .sidebar) {
      PanelToggleMenuItems()
    }
  }
}

private struct PanelToggleMenuItems: View {
  @FocusedValue(\.sidebarVisibility) private var sidebar
  @FocusedValue(\.workspaceInspector) private var inspector

  var body: some View {
    ShortcutButton(.toggleSidebar, title: PanelToggleShortcut.sidebar.title(isVisible: sidebar?.isVisible ?? true)) {
      sidebar?.toggle()
    }
    .disabled(sidebar == nil)
    ShortcutButton(
      .toggleInspector, title: PanelToggleShortcut.inspector.title(isVisible: inspector?.isVisible ?? false)
    ) {
      inspector?.toggle()
    }
    .disabled(inspector == nil)
  }
}
