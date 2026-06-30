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
    private var terminals: [UUID: TerminalSession] = [:]
    private let agentService: any AgentServicing
    private let configCache: ConfigOptionCache
    private let workspaceList: WorkspaceListModel
    private let settings: AppSettingsModel?

    init(
        agentService: any AgentServicing,
        configCache: ConfigOptionCache,
        workspaceList: WorkspaceListModel,
        settings: AppSettingsModel? = nil
    ) {
        self.agentService = agentService
        self.configCache = configCache
        self.workspaceList = workspaceList
        self.settings = settings
    }

    /// Returns the cached controller for a session, creating + configuring it
    /// (resume id, harness, persistence callback) if needed.
    func controller(for session: ChatSession, workspace: Workspace) -> SessionController {
        if let existing = controllers[session.id] {
            existing.workspace = workspace
            return existing
        }
        let controller = SessionController(workspace: workspace, agentService: agentService, configCache: configCache, settings: settings)
        controller.resumeAgentSessionId = session.agentSessionId
        if !session.harnessId.isEmpty {
            controller.selectedHarnessId = session.harnessId
        }
        controller.onAgentSessionCreated = { [weak workspaceList] agentSessionId in
            workspaceList?.setAgentSessionId(agentSessionId, for: session.id)
        }
        controllers[session.id] = controller
        return controller
    }

    /// Creates a fresh, unregistered controller for the new-chat page.
    func makeDraft(workspace: Workspace) -> SessionController {
        SessionController(workspace: workspace, agentService: agentService, configCache: configCache, settings: settings)
    }

    /// Returns the cached terminal for a session, creating it (scoped to the
    /// workspace folder) on first use. Mirrors `controller(for:workspace:)` so
    /// the terminal survives panel close + navigation away and back.
    func terminal(for session: ChatSession, workspace: Workspace) -> TerminalSession {
        if let existing = terminals[session.id] { return existing }
        let terminal = TerminalSession(id: session.id, workingDirectory: workspace.folderURL)
        terminals[session.id] = terminal
        return terminal
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
        terminals[sessionId]?.terminate()
        terminals[sessionId] = nil
    }
}
