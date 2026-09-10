import CodevisorCore
import Foundation
import SwiftUI

extension HomeView {
  func clientControlContext(serverId: String) -> NativeClientContext {
    let workspaceId: UUID?
    if case let .workspace(selectedServer, id, _, _, _)? = path.last, selectedServer == serverId {
      workspaceId = id
    } else {
      workspaceId = nil
    }
    return .capture(
      repository: environment.workspaces, serverId: serverId,
      workspaceId: workspaceId, isActive: scenePhase == .active
    )
  }

  func navigateClient(serverId: String, request: ClientNavigationRequest) async throws {
    guard presentedSettingsDestination == nil, newChatFlow == nil else {
      throw ClientControlError("Dismiss the presented sheet before navigating this client")
    }
    await environment.workspaceSync.refreshFromServer(
      serverId: serverId, client: environment.machines.client(for: serverId)
    )
    try Task.checkCancellation()
    guard let workspace = environment.workspaces.workspace(id: request.workspaceId),
      workspace.serverId == serverId
    else { throw ClientControlError("Workspace is not available on this machine") }
    let selected = try request.applying(to: workspace)
    let tab = selected.selectedCenterTab
    let pane = tab.flatMap { $0.root.group(id: $0.activeLeafId)?.selectedPane }
    let candidates = [pane?.chatSessionId].compactMap { $0 } + workspace.chatSessionIds
    guard
      let anchor = candidates.first(where: { id in
        projectList.sessions.contains { $0.serverId == serverId && $0.id == id }
      })
    else { throw ClientControlError("Workspace has no available chat route on this client") }
    environment.workspaces.save(selected)
    environment.workspaceSync.noteLocalMutation()
    path = [
      .workspace(
        serverId: serverId, workspaceId: workspace.id, anchorSessionId: anchor,
        preferredChatSessionId: nil, preferredPaneId: pane?.id
      )
    ]
  }
}
