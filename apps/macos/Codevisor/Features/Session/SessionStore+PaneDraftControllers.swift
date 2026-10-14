import Foundation
import Observation
import CodevisorCore
import ACPKit

extension SessionStore {
  func paneDraftLocation(
    for session: ChatSession
  ) -> (workspaceId: UUID, paneId: UUID)? {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
      let workspace = environment.workspaces.workspace(id: workspaceId)
    else {
      return nil
    }
    let paneId = workspace.pane(containingChat: session.id)?.id
    return paneId.map { (workspaceId, $0) }
  }

  func paneDraft(
    paneId: UUID,
    project: Project,
    preCreatedSession: ChatSession? = nil,
    workspaceId: UUID
  ) -> SessionController {
    if let existing = paneDrafts[paneId] { return existing }
    let controller = SessionController(
      project: project,
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults,
      hostWorkspaceId: workspaceId,
      serverClient: environment.machines.client(for: project.serverId),
      machines: environment.machines,
      notificationDelivery: notificationDelivery,
      attachmentFiles: environment.composerDrafts.attachmentFiles
    )
    controller.applyComposerDefaults()
    if let persisted = environment.composerDrafts.paneDraft(forPane: paneId) {
      controller.restoreDraft(persisted)
    }
    enablePaneDraftPersistence(for: controller, paneId: paneId)
    paneDrafts[paneId] = controller
    return controller
  }

  func removePaneDraft(paneId: UUID) {
    paneDrafts[paneId]?.onDraftChange = nil
    paneDrafts[paneId] = nil
    environment.composerDrafts.clearPaneDraft(forPane: paneId)
  }

  func restorePaneDraftPersistence(
    _ controller: SessionController,
    paneId: UUID
  ) {
    paneDrafts[paneId] = controller
    enablePaneDraftPersistence(for: controller, paneId: paneId)
  }

  func enablePaneDraftPersistence(for controller: SessionController, paneId: UUID) {
    controller.onDraftChange = { [weak drafts = environment.composerDrafts] draft in
      drafts?.savePaneDraft(draft, forPane: paneId)
    }
    environment.composerDrafts.savePaneDraft(controller.draftSnapshot(), forPane: paneId)
  }

  func enableDraftPersistence(
    for controller: SessionController,
    slotServerId: String? = nil
  ) {
    let serverId = slotServerId ?? controller.project.serverId
    controller.onDraftChange = { [weak drafts = environment.composerDrafts] draft in
      drafts?.saveDraft(draft, forServer: serverId)
    }
    environment.composerDrafts.saveDraft(controller.draftSnapshot(), forServer: serverId)
  }
}
