import SwiftUI

struct RootSplitView<Sidebar: View, Detail: View>: View {
  let store: SessionStore?
  let windowControl: ClientWindowControl
  let sidebar: Sidebar
  let detail: Detail
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @Environment(\.firstLaunchCoversApp) private var firstLaunchCoversApp

  init(
    store: SessionStore?, windowControl: ClientWindowControl, @ViewBuilder sidebar: () -> Sidebar,
    @ViewBuilder detail: () -> Detail
  ) {
    self.store = store
    self.windowControl = windowControl
    self.sidebar = sidebar()
    self.detail = detail()
  }

  var body: some View {
    NavigationSplitView(columnVisibility: visibility.columnVisibility) {
      sidebar
        .toolbar(removing: removesSystemToggle ? .sidebarToggle : nil)
        .toolbar {
          if showsLeadingItems {
            SidebarLeadingToolbarItems(sidebar: toggle)
          }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 270, max: 360)
    } detail: {
      detail
    }
    .background(
      SidebarToggleHelp(help: PanelToggleShortcut.sidebar.help(isVisible: isVisible)).frame(width: 0, height: 0)
    )
    .focusedSceneValue(\.sidebarVisibility, toggle)
    .onChange(of: isVisible, initial: true) { _, visible in
      store?.isSidebarVisible = visible
    }
    .onChange(of: store.map(ObjectIdentifier.init)) { _, _ in
      store?.isSidebarVisible = isVisible
    }
  }

  private var visibility: RootSidebarVisibility {
    RootSidebarVisibility(panelLayout: panelLayout, windowControl: windowControl)
  }

  private var isVisible: Bool {
    visibility.isVisible
  }

  private var toggle: SidebarVisibilityToggle {
    SidebarVisibilityToggle(isVisible: isVisible, setVisible: visibility.setVisible)
  }

  private var removesSystemToggle: Bool {
    firstLaunchCoversApp || SidebarModeSwitchPlacement.current == .sidebar
  }

  private var showsLeadingItems: Bool {
    SidebarModeSwitchPlacement.current == .sidebar && !firstLaunchCoversApp
  }
}
