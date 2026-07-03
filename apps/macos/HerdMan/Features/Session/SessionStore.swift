import Foundation
import Observation
import HerdManCore

/// Caches one `SessionController` per session id so an in-flight conversation
/// survives navigation (e.g. the new-chat → session handoff) and re-selecting a
/// session in the sidebar.
@MainActor
@Observable
final class SessionStore {
    private var controllers: [UUID: SessionController] = [:]
    private var paneGroups: [UUID: PaneGroupModel] = [:]
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Returns the cached controller for a session, creating + configuring it
    /// (resume id, harness, persistence callback) if needed.
    func controller(for session: ChatSession, project: Project) -> SessionController {
        if let existing = controllers[session.id] {
            existing.project = project
            existing.serverSession = session
            return existing
        }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            settings: environment.settings,
            serverClient: environment.machines.client(for: session.serverId)
        )
        controller.serverSession = session
        controller.resumeAgentSessionId = session.agentSessionId
        if !session.harnessId.isEmpty {
            controller.selectedHarnessId = session.harnessId
        }
        controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
            projectList?.setAgentSessionId(agentSessionId, for: session.id)
        }
        controllers[session.id] = controller
        return controller
    }

    /// Creates a fresh, unregistered controller for the new-chat page.
    func makeDraft(project: Project) -> SessionController {
        SessionController(
            project: project,
            configCache: environment.configCache,
            settings: environment.settings,
            serverClient: environment.serverClient
        )
    }

    /// Returns the cached pane group for a session, creating it on first use.
    /// Mirrors `controller(for:project:)` so panes (and their terminals)
    /// survive panel close + navigation away and back.
    func paneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
        if let existing = paneGroups[session.id] { return existing }
        let machine = environment.machines.machine(for: session.serverId) ?? HerdManMachine.local
        let group = PaneGroupModel(
            sessionId: session.id,
            repository: environment.paneGroups,
            makeContext: { descriptor in
                PaneContext(
                    paneId: descriptor.id,
                    sessionId: session.id,
                    terminalKey: descriptor.terminalKey,
                    machine: machine,
                    session: session,
                    project: project
                )
            }
        )
        paneGroups[session.id] = group
        return group
    }

    /// Whether the session with this id is actively generating a response.
    func isRunning(_ sessionId: UUID) -> Bool {
        controllers[sessionId]?.isSending ?? false
    }

    /// Registers a draft controller under a newly created session id.
    func register(_ controller: SessionController, for sessionId: UUID) {
        controllers[sessionId] = controller
    }

    func discard(_ sessionId: UUID) {
        controllers[sessionId] = nil
        paneGroups[sessionId]?.detachAll()
        paneGroups[sessionId] = nil
    }
}
