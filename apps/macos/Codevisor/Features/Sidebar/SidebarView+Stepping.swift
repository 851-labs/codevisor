import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  enum SidebarStop {
    case workspace(SidebarWorkspaceListItem)
    case tab(UUID, workspaceID: UUID)
    case archived(Workspace)
  }

  private func sidebarStop(at row: SidebarRow, content: SidebarRowContent) -> SidebarStop? {
    switch row.kind {
    case let .tab(id, workspaceID, _):
      .tab(id, workspaceID: workspaceID)
    case let .workspace(item, .archived):
      environment.navigationStore.workspaceEntries.entry(item.id).workspace.map(SidebarStop.archived)
    case let .workspace(item, _):
      content.listItem(for: item).map(SidebarStop.workspace)
    case .section, .group, .showMoreArchived:
      nil
    }
  }

  func stepWorkspace(_ offset: Int) {
    let selected = SidebarSelectionSync.selectedRow(showing: selectionTarget, rowIDs: shownRows.ids)
    let content = rowContent
    let target = SidebarStep.target(among: shownRows.rows, isCurrent: { $0.id == selected }, by: offset) { row in
      sidebarStop(at: row, content: content)
    }
    guard let target else { return }

    activate(target)
  }

  private func activate(_ stop: SidebarStop) {
    switch stop {
    case let .workspace(item):
      requestReveal(of: item.workspace.id)
      activateWorkspace(item, tabId: item.workspace.mainTab.id)
    case let .tab(id, workspaceID):
      selectTab(id, in: workspaceID)
    case let .archived(workspace):
      requestReveal(of: workspace.id)
      selectTab(workspace.mainTab.id, in: workspace.id)
    }
  }

  private func requestReveal(of workspaceID: UUID) {
    if let frame = dragGeometry.workspaces[workspaceID], let visible = dragGeometry.visibleRows,
      visible.contains(frame.minY), visible.contains(frame.maxY)
    {
      return
    }
    revealRequest.rowID = workspaceID
  }
}
