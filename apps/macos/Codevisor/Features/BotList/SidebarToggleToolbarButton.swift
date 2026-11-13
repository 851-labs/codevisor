import SwiftUI

struct SidebarToggleToolbarButton: View {
  let sidebar: SidebarVisibilityToggle

  var body: some View {
    Button(action: sidebar.toggle) {
      Label(PanelToggleShortcut.sidebar.title(isVisible: sidebar.isVisible), systemImage: "sidebar.leading")
    }
    .help(PanelToggleShortcut.sidebar.help(isVisible: sidebar.isVisible))
  }
}
