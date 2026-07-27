import CodevisorCore
import Foundation

/// App-wide SessionController cache — the iOS counterpart of the macOS
/// SessionStore's controller map. Controllers outlive any single screen:
/// leaving a workspace mid-stream and coming back rebinds the SAME
/// controller, whose model kept consuming the live stream the whole time.
/// Without this, every visit minted a fresh controller that only knew the
/// settled history until the run finished.
@MainActor
@Observable
final class ChatControllerCache {
    static let shared = ChatControllerCache()

    private struct Key: Hashable {
        let serverId: String
        let id: UUID
    }

    private var controllers: [Key: SessionController] = [:]
    /// The chat currently on screen; its finished turns re-mark as read the
    /// moment they land (the server writes the attention event before the
    /// client sees the turn end — same dance as the macOS store).
    @ObservationIgnored private var openKey: Key?
    /// Access order, most recent last — LRU eviction so browsing many chats
    /// doesn't retain every transcript ever opened.
    @ObservationIgnored private var accessOrder: [Key] = []
    private static let maxIdleControllers = 8

    func controller(
        for session: ChatSession,
        project: Project,
        environment: AppEnvironment
    ) -> SessionController {
        let key = Key(serverId: session.serverId, id: session.id)
        noteAccess(key)
        if let existing = controllers[key] {
            if existing.project != project {
                existing.project = project
            }
            if existing.serverSession != session {
                existing.configureExistingSession(session)
            }
            return existing
        }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.machines.client(for: session.serverId)
        )
        controller.configureExistingSession(session)
        // Deferred sends persist the spawned agent id so relaunches resume
        // the same agent session (the same wiring the macOS store does).
        controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
            projectList?.setAgentSessionId(
                agentSessionId,
                for: session.id,
                serverId: session.serverId
            )
        }
        // Attention: a turn finishing (or a question arriving) while this
        // chat is the open one immediately re-marks it read, so the unread
        // dot never lights for the conversation you're looking at.
        let markReadIfOpen = { [weak self, weak projectList = environment.projectList] in
            guard let self, self.openKey == key else { return }
            projectList?.markSessionRead(key.id, serverId: key.serverId)
        }
        controller.onTurnEnded = markReadIfOpen
        controller.onActionRequired = markReadIfOpen
        controllers[key] = controller
        evictIfNeeded()
        return controller
    }

    /// Marks a chat as the open one and clears its unread state — the iOS
    /// counterpart of the macOS store's markOpened.
    func noteOpened(sessionId: UUID, serverId: String, projectList: ProjectListModel) {
        let key = Key(serverId: serverId, id: sessionId)
        openKey = key
        projectList.markSessionRead(sessionId, serverId: serverId)
    }

    func noteClosed(sessionId: UUID, serverId: String) {
        let key = Key(serverId: serverId, id: sessionId)
        if openKey == key { openKey = nil }
    }

    private func noteAccess(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// Drops the least-recently-used idle controllers; anything mid-send or
    /// mid-connect stays put regardless of age.
    private func evictIfNeeded() {
        var idle = accessOrder.filter { key in
            guard let controller = controllers[key] else { return false }
            return !controller.isSending && !controller.isConnecting
        }
        while idle.count > Self.maxIdleControllers {
            let key = idle.removeFirst()
            controllers[key]?.model?.shutdown()
            controllers[key] = nil
            accessOrder.removeAll { $0 == key }
        }
    }
}
