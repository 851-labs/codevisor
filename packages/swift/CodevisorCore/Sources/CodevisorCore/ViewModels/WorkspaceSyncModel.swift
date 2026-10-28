import Foundation
import Observation

public enum WorkspaceRouteDisposition: Equatable, Sendable {
  case keep
  case selectSession(UUID)
  case dismiss
}

@MainActor
@Observable
public final class WorkspaceSyncModel {
  public var revision: UInt64 { navigationStore?.revision ?? 0 }

  let repository: any WorkspaceRepository
  let projectList: ProjectListModel
  @ObservationIgnored var navigationStore: NavigationStore?

  public init(repository: any WorkspaceRepository, projectList: ProjectListModel) {
    self.repository = repository
    self.projectList = projectList
  }

  @discardableResult
  public func refreshFromServer(
    serverId: String, client: any CodevisorServerClienting
  ) async -> ServerNavigationRefreshResult {
    guard let navigationStore else { return .failed("No navigation store") }
    return await navigationStore.refresh(machineId: serverId, client: client)
  }

  func enqueue(_ intent: NavigationIntent, serverId: String) {
    navigationStore?.enqueue(intent, machineId: serverId)
  }

  public func routeDisposition(
    sessionId: UUID,
    serverId: String,
    preservingSelectedPane: Bool = false
  ) -> WorkspaceRouteDisposition {
    guard
      projectList.sessions.contains(where: { $0.id == sessionId && $0.serverId == serverId })
    else { return .dismiss }
    guard let workspaceId = repository.workspaceId(forSession: sessionId) else { return .keep }
    return routeDisposition(
      workspaceId: workspaceId,
      anchorSessionId: sessionId,
      preservingSelectedPane: preservingSelectedPane
    )
  }

  public func routeDisposition(
    workspaceId: UUID,
    anchorSessionId: UUID,
    preservingSelectedPane: Bool = false
  ) -> WorkspaceRouteDisposition {
    guard let workspace = repository.workspace(id: workspaceId), !workspace.isArchived else { return .dismiss }
    let serverId = workspace.serverId

    let hasAnchor = projectList.sessions.contains {
      $0.serverId == serverId && $0.id == anchorSessionId
    }
    if preservingSelectedPane, hasAnchor,
      repository.workspaceId(forSession: anchorSessionId) == workspaceId,
      let tab = workspace.selectedCenterTab,
      let pane = tab.root.group(id: tab.activeLeafId)?.selectedPane,
      pane.kind != .chat
    {
      return .keep
    }

    let active = projectList.sessions.filter { session in
      session.serverId == serverId
        && repository.workspaceId(forSession: session.id) == workspaceId
        && workspace.pane(containingChat: session.id) != nil
    }
    if active.contains(where: { $0.id == anchorSessionId }) { return .keep }
    if preservingSelectedPane, hasAnchor, !active.isEmpty,
      repository.workspaceId(forSession: anchorSessionId) == workspaceId,
      workspace.selectedCenterTab?.root.allGroups.contains(where: { group in
        group.state.panes.contains { pane in
          pane.kind != .chat || pane.chatSessionId == nil
            || active.contains(where: { $0.id == pane.chatSessionId })
        }
      }) == true
    {
      return .keep
    }
    if let replacement = active.first { return .selectSession(replacement.id) }
    if hasAnchor, workspace.hasOpenNonChatContent,
      repository.workspaceId(forSession: anchorSessionId) == workspaceId
    {
      return .keep
    }
    return .dismiss
  }
}
