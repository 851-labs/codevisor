import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  enum SidebarStop {
    case workspace(SidebarWorkspaceListItem)
    case tab(UUID, workspaceID: UUID)
    case archived(Workspace)
  }

  func sidebarStops(in rows: [SidebarRow]) -> [SidebarStop] {
    rows.compactMap { row in
      switch row.kind {
      case let .tab(id, workspaceID, _):
        SidebarStop.tab(id, workspaceID: workspaceID)
      case let .workspace(item, .archived):
        environment.navigationStore.workspaceEntries.entry(item.id).workspace.map(SidebarStop.archived)
      case let .workspace(item, _):
        listItem(for: item).map(SidebarStop.workspace)
      case .section, .group, .showMoreArchived:
        nil
      }
    }
  }

  func stepWorkspace(_ offset: Int) {
    let rows = sidebarRows
    let stops = sidebarStops(in: rows)
    let selected = selectedRowID(in: rows)
    let current = stops.firstIndex { isSelected($0, selected: selected) }
    guard let target = SidebarStep.target(in: stops, from: current, by: offset) else { return }

    activate(target)
  }

  private func isSelected(_ stop: SidebarStop, selected: SidebarRowID?) -> Bool {
    switch stop {
    case let .workspace(item):
      selected == .workspace(item.workspace.id)
    case let .tab(id, _):
      selected == .tab(id)
    case let .archived(workspace):
      selected == .workspace(workspace.id)
    }
  }

  private func activate(_ stop: SidebarStop) {
    switch stop {
    case let .workspace(item):
      revealRequest.rowID = item.workspace.id
      activateWorkspace(item, tabId: item.workspace.mainTab.id)
    case let .tab(id, workspaceID):
      selectTab(id, in: workspaceID)
    case let .archived(workspace):
      revealRequest.rowID = workspace.id
      selectTab(workspace.mainTab.id, in: workspace.id)
    }
  }
}
