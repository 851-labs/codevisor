import AppKit
import CodevisorCore
import SwiftUI

struct RootSidebarVisibility {
  static let collapsedKey = "sidebar.collapsed"

  let panelLayout: AdaptivePanelLayout
  var windowControl: ClientWindowControl?

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
    guard visible != isVisible else { return }

    if panelLayout.docksSidebar {
      toggleDockedColumn()
    } else {
      panelLayout.toggleDrawer(.leading)
    }
  }

  private func toggleDockedColumn() {
    guard let splitController else {
      setCollapsed(!isCollapsed)
      return
    }
    splitController.toggleSidebar(nil)
  }

  private var splitController: NSSplitViewController? {
    windowControl?.window?.contentView.flatMap(SidebarSplitController.find(in:))
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
