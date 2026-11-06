import CodevisorCore
import SwiftUI

struct RootSidebarVisibility {
  static let collapsedKey = "sidebar.collapsed"

  let panelLayout: AdaptivePanelLayout

  var isVisible: Bool {
    panelLayout.docksSidebar ? !isCollapsed : panelLayout.activeDrawer == .leading
  }

  var hidesDockedColumn: Bool {
    !panelLayout.docksSidebar || isCollapsed
  }

  var columnVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(get: { hidesDockedColumn ? .detailOnly : .all }, set: applyColumnVisibility)
  }

  func setVisible(_ visible: Bool) {
    if panelLayout.docksSidebar {
      setCollapsed(!visible)
    } else if visible != isVisible {
      panelLayout.toggleDrawer(.leading)
    }
  }

  private func applyColumnVisibility(_ visibility: NavigationSplitViewVisibility) {
    if panelLayout.docksSidebar {
      setCollapsed(visibility == .detailOnly)
    } else if visibility != .detailOnly {
      panelLayout.toggleDrawer(.leading)
    }
  }

  private var isCollapsed: Bool {
    ClientPreferences.shared.value(forKey: Self.collapsedKey, default: false)
  }

  private func setCollapsed(_ collapsed: Bool) {
    guard collapsed != isCollapsed else { return }
    ClientPreferences.shared.set(collapsed, forKey: Self.collapsedKey)
  }
}
