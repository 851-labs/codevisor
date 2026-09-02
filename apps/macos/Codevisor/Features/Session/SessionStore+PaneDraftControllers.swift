import Foundation
import Observation
import CodevisorCore
import ACPKit

// MARK: - PaneDraftControllers

extension SessionStore {
  /// The live draft selected in an unbound chat pane. Split/tab inheritance
  /// uses this when the focused pane has no eager session record.
  func paneDraftController(forPane paneId: UUID) -> SessionController? {
    paneDrafts[paneId]
  }

  /// Resolves an eagerly-created unsent session back to the pane that owns
  /// its draft controller.
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

  /// The draft controller behind an in-workspace draft chat pane (created
  /// on first use), mirrored to disk per PANE — an unsent in-workspace
  /// composer (text, attachments, settings) survives relaunches and app
  /// updates just like the per-server page draft does.
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
      composerDefaultsScope: .workspace(
        id: workspaceId,
        serverId: project.serverId
      ),
      serverClient: environment.machines.client(for: project.serverId),
      notificationDelivery: notificationDelivery
    )
    controller.applyComposerDefaults()
    if let persisted = environment.composerDrafts.paneDraft(forPane: paneId) {
      controller.restoreDraft(persisted)
    }
    enablePaneDraftPersistence(for: controller, paneId: paneId)
    paneDrafts[paneId] = controller
    return controller
  }

  /// First send bound the pane's session; the controller now lives in the
  /// session cache and the pane's disk draft is spent.
  func removePaneDraft(paneId: UUID) {
    paneDrafts[paneId]?.onDraftChange = nil
    paneDrafts[paneId] = nil
    environment.composerDrafts.clearPaneDraft(forPane: paneId)
  }

  /// First-send setup failed, but its durable session/workspace remains.
  /// Reattach the exact same controller to the pane's original draft slot
  /// so all composer state keeps using the established persistence path.
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
