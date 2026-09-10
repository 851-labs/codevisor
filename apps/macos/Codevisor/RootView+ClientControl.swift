import CodevisorCore
import Foundation
import SwiftUI

extension RootView {
  func clientControlContext(serverId: String) -> NativeClientContext {
    let workspaceId: UUID?
    if case let .session(selectedServer, sessionId) = selection, selectedServer == serverId {
      workspaceId = environment.workspaces.workspaceId(forSession: sessionId)
    } else {
      workspaceId = nil
    }
    return .capture(
      repository: environment.workspaces, serverId: serverId,
      workspaceId: workspaceId, isActive: controlActiveState == .key
    )
  }

  func navigateClient(serverId: String, request: ClientNavigationRequest) async throws {
    guard let store else { throw ClientControlError("Window is still loading") }
    await environment.workspaceSync.refreshFromServer(
      serverId: serverId, client: environment.machines.client(for: serverId)
    )
    try Task.checkCancellation()
    guard let workspace = environment.workspaces.workspace(id: request.workspaceId),
      workspace.serverId == serverId
    else { throw ClientControlError("Workspace is not available on this machine") }
    let selected = try request.applying(to: workspace)
    let tab = selected.selectedCenterTab
    let selectedChat = tab.flatMap { $0.root.group(id: $0.activeLeafId)?.selectedPane?.chatSessionId }
    let candidates = [selectedChat].compactMap { $0 } + workspace.chatSessionIds
    guard
      let anchor = candidates.first(where: { id in
        environment.projectList.sessions.contains { $0.serverId == serverId && $0.id == id }
      })
    else { throw ClientControlError("Workspace has no available chat route on this client") }
    guard
      store.selectDestination(
        request.destination?.workspaceDestination ?? .tab(selected.selectedCenterTabId),
        in: workspace.id
      )
    else { throw ClientControlError("Destination is no longer available") }
    selection = .session(serverId: serverId, id: anchor)
  }
}
