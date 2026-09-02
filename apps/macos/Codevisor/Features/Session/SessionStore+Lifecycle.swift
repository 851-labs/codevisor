import Foundation
import Observation
import CodevisorCore
import ACPKit

// MARK: - Lifecycle

extension SessionStore {
    /// Registers a draft controller under a newly created session id and
    /// releases the draft slot so the next new chat starts fresh.
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
        // A retargeted draft's slot key (its home machine) can differ from
        // its project's machine — release whichever slot holds it.
        if let slotKey = draftsByServer.first(where: { $0.value === controller })?.key {
            draftsByServer[slotKey] = nil
            environment.composerDrafts.clearDraft(forServer: slotKey)
        } else {
            environment.composerDrafts.clearDraft(forServer: controller.project.serverId)
        }
        controller.onDraftChange = nil
    }

    /// Standalone counterpart to `restorePaneDraftPersistence`: retain the
    /// durable session registration while restoring the original new-chat
    /// draft/defaults persistence until the retry succeeds.
    func restoreDraftPersistence(_ controller: SessionController) {
        draftsByServer[controller.project.serverId] = controller
        enableDraftPersistence(
            for: controller,
            slotServerId: controller.project.serverId
        )
    }

    /// Detaches and evicts the session's workspace bottom-panel model.
    func detachBottomGroup(for session: ChatSession) {
        guard let workspaceId = environment.workspaces.workspaceId(forSession: session.id) else { return }
        bottomGroups[workspaceId]?.detachAll()
        bottomGroups[workspaceId] = nil
    }

    /// Detaches and evicts every cached center-leaf group of the session's
    /// workspace (backing shells survive on the server).
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
        detachBottomGroup(for: session)
        detachCenterLeaves(for: session)
        scrollStates[key] = nil
        todoExpansionStates[key] = nil
        accessOrder.removeAll { $0 == key }
    }
}
