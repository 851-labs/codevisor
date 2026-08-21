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
    /// The retained new-chat draft controller per machine — the iOS
    /// counterpart of the macOS store's `draftsByServer`. Unsent composer
    /// state survives leaving the page and relaunches; the first send
    /// promotes the controller to a real session and clears the draft.
    private var draftsByServer: [String: SessionController] = [:]
    /// Viewport snapshots outlive the heavier controller LRU. This mirrors
    /// macOS's SessionStore: opening enough chats may discard a transcript
    /// model, but it must not forget where the user was reading.
    @ObservationIgnored private var scrollStates: [Key: SessionScrollState] = [:]
    /// Todo disclosure outlives the heavier controller LRU, matching the
    /// macOS SessionStore contract for pinned session checklists.
    @ObservationIgnored private var todoExpansionStates: [Key: Bool] = [:]
    /// Access order, most recent last — LRU eviction so browsing many chats
    /// doesn't retain every transcript ever opened.
    @ObservationIgnored private var accessOrder: [Key] = []
    private static let maxIdleControllers = 8

    func controller(
        for session: ChatSession,
        project: Project,
        workspaceId: UUID,
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
            composerDefaultsScope: .workspace(
                id: workspaceId,
                serverId: session.serverId
            ),
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
        bindRetainedSessionState(controller, to: key)
        controllers[key] = controller
        evictIfNeeded()
        return controller
    }

    /// Returns the retained draft controller for the new-chat page, restoring
    /// its disk snapshot first or seeding it from last-used composer defaults
    /// if none exists — the same contract as the macOS store's
    /// `draft(project:)`. The draft is retained until its first send promotes
    /// it to a real session, so unsent composer state survives navigation and
    /// relaunches.
    func draftController(
        preferredProject: Project,
        environment: AppEnvironment
    ) -> SessionController {
        let serverId = preferredProject.serverId
        if let draft = draftsByServer[serverId], draft.serverSession == nil {
            return draft
        }
        let persisted = environment.composerDrafts.draft(forServer: serverId)
        let restoredProject =
            persisted.flatMap { saved in
                environment.projectList.activeProjects.first {
                    $0.serverId == serverId && $0.id == saved.projectId
                }
            } ?? environment.composerDefaults.lastProjectId(forServer: serverId).flatMap {
                rememberedId in
                environment.projectList.activeProjects.first {
                    $0.serverId == serverId && $0.id == rememberedId
                }
            } ?? preferredProject
        environment.composerDefaults.rememberNewWorkspaceProject(
            serverId: serverId,
            projectId: restoredProject.id
        )
        let controller = SessionController(
            project: restoredProject,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            composerDefaultsScope: .newWorkspace(serverId: serverId),
            serverClient: environment.serverClient
        )
        controller.applyComposerDefaults()
        // Fresh drafts start from the machine's remembered run-location
        // choice (worktrees only apply to git projects). Retained drafts
        // returned above keep whatever the user toggled.
        controller.wantsNewWorktree =
            restoredProject.isGitRepository
            && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
                forServer: serverId
            )
        if let persisted { controller.restoreDraft(persisted) }
        controller.onDraftChange = { [weak drafts = environment.composerDrafts] draft in
            drafts?.saveDraft(draft, forServer: serverId)
        }
        environment.composerDrafts.saveDraft(controller.draftSnapshot(), forServer: serverId)
        draftsByServer[serverId] = controller
        return controller
    }

    /// Adopts a draft controller under its freshly created session id (the
    /// new-chat page's first send), so the workspace screen rebinds the SAME
    /// controller — mid-flight worktree setup, optimistic message and all —
    /// instead of minting a fresh one. The promoted chat leaves the draft
    /// slot behind and clears its persisted snapshot, exactly like the macOS
    /// store's registration path.
    func register(
        _ controller: SessionController,
        for session: ChatSession,
        environment: AppEnvironment
    ) {
        let key = Key(serverId: session.serverId, id: session.id)
        noteAccess(key)
        controllers[key] = controller
        bindRetainedSessionState(controller, to: key)
        if draftsByServer[session.serverId] === controller {
            draftsByServer[session.serverId] = nil
        }
        controller.onDraftChange = nil
        environment.composerDrafts.clearDraft(forServer: session.serverId)
        evictIfNeeded()
    }

    /// The live controller for a chat if one is already cached, without
    /// creating anything. Lets a screen render an in-flight chat on its FIRST
    /// frame — the workspace opening onto a just-sent new chat would otherwise
    /// flash a spinner while its async connect bound the very controller the
    /// cache already held.
    func existingController(sessionId: UUID, serverId: String) -> SessionController? {
        controllers[Key(serverId: serverId, id: sessionId)]
    }

    /// Whether the chat's agent is actively working — the same classification
    /// as the macOS sidebar (sending, running setup phases, or waiting on
    /// background subagents; deliberately not `isConnecting`, which is client
    /// plumbing, not agent work). A cached live controller is freshest; rows
    /// without one use the server-projected sidebar state.
    func isInProgress(_ session: ChatSession) -> Bool {
        guard let controller = controllers[Key(serverId: session.serverId, id: session.id)] else {
            return session.sidebarState == .inProgress
        }
        return controller.pendingUserMessage != nil
            || controller.isSending
            || controller.setupPhases.contains(where: \.isRunning)
            || controller.isWaitingOnBackgroundTasks
    }

    /// Foreground/network-recovery sweep: every cached chat with a turn in
    /// flight re-verifies against durable server history. Suspension can
    /// strand a turn in ways stream replay alone cannot fix (a reconcile
    /// that failed while unreachable, a server-side repair missed while
    /// asleep); idle chats are a no-op.
    func reconcileInFlightControllers() async {
        for controller in controllers.values where controller.isSending {
            await controller.reconcileInFlightTurn()
        }
    }

    private func noteAccess(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func bindRetainedSessionState(_ controller: SessionController, to key: Key) {
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
    }

    /// Drops the least-recently-used idle controllers; anything mid-send or
    /// mid-connect stays put regardless of age — except a turn that has been
    /// quiet past the stall window. Treating a stalled send as pinned kept a
    /// stuck controller resident for the app's lifetime, so "navigate away
    /// and back" could never rebuild it; a re-opened chat reconstructs from
    /// durable history (and its stream cursor) losing nothing.
    private func evictIfNeeded() {
        var idle = accessOrder.filter { key in
            guard let controller = controllers[key] else { return false }
            if controller.isConnecting { return false }
            return !controller.isSending || controller.isTakingLongerThanExpected
        }
        while idle.count > Self.maxIdleControllers {
            let key = idle.removeFirst()
            controllers[key]?.model?.shutdown()
            controllers[key] = nil
            accessOrder.removeAll { $0 == key }
        }
    }
}

extension SessionController {
    func keepOrRetargetDraft(to project: Project) -> Bool {
        if self.project.isArchived, self.project.id != project.id {
            Task { await selectProject(project) }
        }
        return true
    }
}
