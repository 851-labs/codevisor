import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  enum SidebarStop {
    case newChat
    case workspace(SidebarWorkspaceListItem)
    case archived(Workspace)
  }

  var sidebarStops: [SidebarStop] {
    [.newChat]
      + sidebarRows.compactMap { row in
        switch row.kind {
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
    let stops = sidebarStops
    guard let current = stops.firstIndex(where: isSelected) else { return }
    let target = current + offset
    guard target != current, stops.indices.contains(target) else { return }
    activate(stops[target])
  }

  private func isSelected(_ stop: SidebarStop) -> Bool {
    switch stop {
    case .newChat:
      isNewChatSelected
    case let .workspace(item):
      routesSelectedSession(item.workspace)
    case let .archived(workspace):
      selection == .archivedWorkspace(serverId: workspace.serverId, id: workspace.id)
    }
  }

  private func activate(_ stop: SidebarStop) {
    switch stop {
    case .newChat:
      selection = .newChat(nil)
    case let .workspace(item):
      revealRequest.rowID = item.workspace.id
      activateWorkspace(item)
    case let .archived(workspace):
      revealRequest.rowID = workspace.id
      selection = .archivedWorkspace(serverId: workspace.serverId, id: workspace.id)
    }
  }
}
