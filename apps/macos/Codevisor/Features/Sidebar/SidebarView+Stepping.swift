import CodevisorCore
import SwiftUI

extension SidebarView {
  enum SidebarStop {
    case newChat
    case bot(Bot)
    case workspace(SidebarWorkspaceListItem)
    case archived(Workspace)
  }

  var sidebarStops: [SidebarStop] {
    let bots = visibleBotEntries.flatMap { entry in
      [SidebarStop.bot(entry.bot)]
        + visibleBotChildren(entry).compactMap(listItem(for:)).map(SidebarStop.workspace)
    }
    return [.newChat] + bots + listedWorkspaceItems.map(SidebarStop.workspace)
      + listedArchivedWorkspaces.map(SidebarStop.archived)
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
    case let .bot(bot):
      isBotSelected(bot)
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
    case let .bot(bot):
      revealRequest.rowID = bot.id
      selection = .bot(serverId: bot.serverId, id: bot.id)
    case let .workspace(item):
      revealRequest.rowID = item.workspace.id
      activateWorkspace(item)
    case let .archived(workspace):
      revealRequest.rowID = workspace.id
      selection = .archivedWorkspace(serverId: workspace.serverId, id: workspace.id)
    }
  }
}
