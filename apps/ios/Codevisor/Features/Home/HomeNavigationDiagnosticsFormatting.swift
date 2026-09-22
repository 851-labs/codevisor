import CodevisorCore
import Foundation

func navigationPathSummary(_ routes: [HomeRoute]) -> String {
  guard !routes.isEmpty else { return "[]" }
  return "["
    + routes.map { route in
      switch route {
      case let .newChat(serverId):
        return "newChat(\(serverId ?? "-"))"
      case let .workspace(
        serverId,
        workspaceId,
        anchorSessionId,
        preferredChatSessionId,
        preferredPaneId,
        preferredLeafId
      ):
        let preferred = preferredChatSessionId.map(navigationShortID) ?? "nil"
        let pane = preferredPaneId.map(navigationShortID) ?? "nil"
        let leaf = preferredLeafId.map(navigationShortID) ?? "nil"
        let workspace = navigationShortID(workspaceId)
        let anchor = anchorSessionId.map(navigationShortID) ?? "nil"
        return "workspace(\(serverId)/\(workspace)/\(anchor)/\(preferred)/\(pane)/\(leaf))"
      }
    }.joined(separator: ",") + "]"
}

func routeDispositionSummary(_ disposition: WorkspaceRouteDisposition) -> String {
  switch disposition {
  case .keep:
    return "keep"
  case let .selectSession(sessionId):
    return "selectSession(\(navigationShortID(sessionId)))"
  case .dismiss:
    return "dismiss"
  }
}

private func navigationShortID(_ id: UUID) -> String {
  String(id.uuidString.prefix(8))
}
