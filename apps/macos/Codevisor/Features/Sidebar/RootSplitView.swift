import SwiftUI

struct RootSplitView<Sidebar: View, Detail: View>: View {
  let store: SessionStore?
  let sidebar: Sidebar
  let detail: Detail
  @Environment(AdaptivePanelLayout.self) private var panelLayout

  init(store: SessionStore?, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
    self.store = store
    self.sidebar = sidebar()
    self.detail = detail()
  }

  var body: some View {
    NavigationSplitView(columnVisibility: visibility.columnVisibility) {
      sidebar
    } detail: {
      detail
    }
    .background(
      SidebarToggleHelp(help: PanelToggleShortcut.sidebar.help(isVisible: isVisible)).frame(width: 0, height: 0)
    )
    .focusedSceneValue(
      \.sidebarVisibility, SidebarVisibilityToggle(isVisible: isVisible, setVisible: visibility.setVisible)
    )
    .onChange(of: isVisible, initial: true) { _, visible in
      store?.isSidebarVisible = visible
    }
    .onChange(of: store.map(ObjectIdentifier.init)) { _, _ in
      store?.isSidebarVisible = isVisible
    }
  }

  private var visibility: RootSidebarVisibility {
    RootSidebarVisibility(panelLayout: panelLayout)
  }

  private var isVisible: Bool {
    visibility.isVisible
  }
}
