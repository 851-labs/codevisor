import CodevisorUI
import Foundation

nonisolated struct RememberedSidebarSelection: Hashable, Codable, Sendable {
  static let preferenceKey = "sidebar.lastSelections"

  let selection: SidebarSelection
  let workspaceId: UUID?

  var parentWorkspace: SidebarSelection? {
    guard case let .session(serverId, _) = selection, let workspaceId else { return nil }

    return .workspace(serverId: serverId, id: workspaceId)
  }
}

extension RememberedSidebarSelection: Identifiable {
  var id: SidebarSelection { parentWorkspace ?? selection }
}

typealias RememberedSidebarSelections = SidebarModeSelections<RememberedSidebarSelection>
