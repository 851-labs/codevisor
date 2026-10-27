import Foundation
import Observation
import CodevisorCore
import ACPKit

extension SessionStore {
  func register(_ controller: SessionController, for session: ChatSession) {
    let key = SessionKey(session)
    controller.scrollState = scrollStates[key]
    controller.onScrollStateChange = { [weak self] state in
      self?.scrollStates[key] = state
    }
    controller.restoreTodoDisclosure(
      isExpanded: todoExpansionStates[key] ?? false
    )
    controller.onTodosExpandedChange = { [weak self] isExpanded in
      self?.todoExpansionStates[key] = isExpanded
    }
    controller.onTurnEnded = { [weak self] in self?.noteTurnEnded() }
    controllers[key] = controller
    if let slotKey = draftsByServer.first(where: { $0.value === controller })?.key {
      draftsByServer[slotKey] = nil
      environment.composerDrafts.clearDraft(forServer: slotKey)
    } else {
      environment.composerDrafts.clearDraft(forServer: controller.project.serverId)
    }
    controller.onDraftChange = nil
  }

  func reregister(_ controller: SessionController, from previous: ChatSession, to relocated: ChatSession) {
    controllers[SessionKey(previous)] = nil
    register(controller, for: relocated)
    detachCenterLeaves(for: relocated)
  }

  func restoreDraftPersistence(_ controller: SessionController) {
    draftsByServer[controller.project.serverId] = controller
    enableDraftPersistence(
      for: controller,
      slotServerId: controller.project.serverId
    )
  }

  func detachCenterLeaves(for session: ChatSession) {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: session.id) else { return }
    for (key, model) in centerLeafGroups where key.workspaceId == workspaceId {
      model.detachAll()
      centerLeafGroups[key] = nil
    }
  }

  func discard(_ session: ChatSession) {
    let key = SessionKey(session)
    controllers[key]?.model?.shutdown()
    controllers[key] = nil
    transcriptSurfaces.remove(serverID: key.serverId, sessionID: key.sessionId)
    ephemeralWorkspaces[session.id] = nil
    detachCenterLeaves(for: session)
    scrollStates[key] = nil
    todoExpansionStates[key] = nil
    accessOrder.removeAll { $0 == key }
  }
}
