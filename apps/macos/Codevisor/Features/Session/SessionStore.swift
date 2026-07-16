import Foundation
import Observation
import CodevisorCore
import ACPKit

/// Caches one `SessionController` per session id so an in-flight conversation
/// survives navigation (e.g. the new-chat → session handoff) and re-selecting a
/// session in the sidebar.
@MainActor
@Observable
final class SessionStore {
    private struct SessionKey: Hashable {
        let serverId: String
        let sessionId: UUID

        init(serverId: String, sessionId: UUID) {
            self.serverId = serverId
            self.sessionId = sessionId
        }

        init(_ session: ChatSession) {
            self.init(serverId: session.serverId, sessionId: session.id)
        }
    }

    private var controllers: [SessionKey: SessionController] = [:]
    /// Tiny viewport snapshots outlive controller eviction. Observation is
    /// intentionally disabled: scroll ticks must never invalidate the store's
    /// sidebar/session observers.
    @ObservationIgnored private var scrollStates: [SessionKey: SessionScrollState] = [:]
    /// Per-session todo-panel expansion, kept outside the controller cache for
    /// the same reason as transcript viewport state.
    @ObservationIgnored private var todoExpansionStates: [SessionKey: Bool] = [:]
    /// Completion edges are cached alongside expansion so reopening a finished
    /// checklist survives navigation and controller eviction.
    @ObservationIgnored private var todoCompletionStates: [SessionKey: Bool] = [:]
    private var paneGroups: [SessionKey: PaneGroupModel] = [:]
    private var scratchpads: [SessionKey: ScratchpadModel] = [:]
    /// One unsent new-chat draft per machine. A controller permanently owns
    /// the server client it was created with, so reusing a draft after a
    /// machine switch can send the new machine's project id to the old server.
    private var draftsByServer: [String: SessionController] = [:]
    /// Turns that finished while their session wasn't open, keyed by session
    /// id — the sidebar's iOS-style unread badges. Cleared on open.
    private var unreadCounts: [SessionKey: Int] = [:]
    /// Invalidates views that observe aggregate activity across the cached
    /// controllers. A turn can finish without otherwise mutating this store
    /// (most notably when its session is open), so nested controller
    /// observation alone can leave cross-session UI such as update banners
    /// holding onto its previous value.
    private var activityRevision = 0
    /// The session currently shown in the detail column; its finished turns
    /// never count as unread.
    private var openSessionKey: SessionKey?
    /// Whether this store's window is key. A selected chat behind Settings or
    /// another Codevisor window is not the focused chat for sound suppression.
    private var isWindowFocused = false
    /// Session ids in access order, most recent last — drives controller
    /// eviction so browsing many sessions doesn't accumulate every transcript
    /// ever opened (conversations retain full tool outputs and diffs).
    private var accessOrder: [SessionKey] = []
    /// How many idle (not open, not working, no background tasks/goal)
    /// controllers stay cached before the least-recently-used are evicted.
    private static let maxIdleControllers = 12
    private let environment: AppEnvironment
    private let notificationDelivery: any ChatNotificationDelivering

    init(
        environment: AppEnvironment,
        notificationDelivery: (any ChatNotificationDelivering)? = nil
    ) {
        self.environment = environment
        self.notificationDelivery = notificationDelivery ?? ChatNotificationManager.shared
    }

    /// Returns the cached controller for a session, creating + configuring it
    /// (resume id, harness, persistence callback) if needed.
    func controller(for session: ChatSession, project: Project) -> SessionController {
        let key = SessionKey(session)
        noteAccess(key)
        if let existing = controllers[key] {
            existing.project = project
            existing.serverSession = session
            return existing
        }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            serverClient: environment.machines.client(for: session.serverId)
        )
        controller.serverSession = session
        controller.resumeAgentSessionId = session.agentSessionId
        if !session.harnessId.isEmpty {
            controller.selectedHarnessId = session.harnessId
        }
        controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
            projectList?.setAgentSessionId(
                agentSessionId,
                for: session.id,
                serverId: session.serverId
            )
        }
        controller.scrollState = scrollStates[key]
        controller.onScrollStateChange = { [weak self] state in
            self?.scrollStates[key] = state
        }
        controller.restoreTodoDisclosure(
            isExpanded: todoExpansionStates[key] ?? true,
            wasCompleted: todoCompletionStates[key] ?? false
        )
        controller.onTodosExpandedChange = { [weak self] isExpanded in
            self?.todoExpansionStates[key] = isExpanded
        }
        controller.onTodosCompletionChange = { [weak self] isCompleted in
            self?.todoCompletionStates[key] = isCompleted
        }
        controller.onTurnEnded = { [weak self] in self?.noteTurnEnded(for: key) }
        controller.onActionRequired = { [weak self] in self?.noteActionRequired(for: key) }
        controllers[key] = controller
        return controller
    }

    /// Returns the retained draft controller for the new-chat page, creating
    /// one seeded from the last-used composer defaults (harness, model,
    /// worktree) if none exists. The draft is retained until its first send
    /// promotes it to a real session, so unsent composer state survives
    /// navigation.
    func draft(project: Project) -> SessionController {
        if let draft = draftsByServer[project.serverId], draft.serverSession == nil {
            return draft
        }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.serverClient
        )
        controller.applyComposerDefaults()
        draftsByServer[project.serverId] = controller
        return controller
    }

    /// Returns the cached pane group for a session, creating it on first use.
    /// Mirrors `controller(for:project:)` so panes (and their terminals)
    /// survive panel close + navigation away and back.
    func paneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
        let key = SessionKey(session)
        if let existing = paneGroups[key] { return existing }
        let machine = environment.machines.machine(for: session.serverId) ?? CodevisorMachine.local
        let group = PaneGroupModel(
            sessionId: session.id,
            repository: environment.paneGroups,
            makeContext: { [weak projectList = environment.projectList] descriptor in
                // Panes are built lazily, so this cached closure can outlive
                // the snapshot passed in above: a fresh worktree session
                // starts with cwd == nil and only learns its worktree path
                // once setup finishes (ProjectListModel.setWorktree). Resolve
                // the live session at pane-creation time so terminals open in
                // the worktree, not the project folder.
                let liveSession = projectList?.sessions.first {
                    $0.serverId == session.serverId && $0.id == session.id
                } ?? session
                return PaneContext(
                    paneId: descriptor.id,
                    sessionId: session.id,
                    terminalKey: descriptor.terminalKey,
                    attachOnly: descriptor.attachOnly,
                    machine: machine,
                    session: liveSession,
                    project: project
                )
            }
        )
        paneGroups[key] = group
        return group
    }

    /// Returns the cached scratchpad for a session, creating it (seeded from
    /// the repository) on first use, so notes and the inspector's open state
    /// survive navigation away and back.
    func scratchpad(for session: ChatSession) -> ScratchpadModel {
        let key = SessionKey(session)
        if let existing = scratchpads[key] { return existing }
        let model = ScratchpadModel(sessionId: session.id, repository: environment.scratchpads)
        scratchpads[key] = model
        return model
    }

    /// Whether the session with this id is showing activity: generating a
    /// response, connecting its agent, running pre-chat setup (worktree
    /// creation, agent start), or waiting on background work it will return to
    /// on its own — everything the sidebar spinner covers.
    func isRunning(_ session: ChatSession) -> Bool {
        guard let controller = controllers[SessionKey(session)] else { return false }
        return Self.isInProgress(controller) || controller.isConnecting
    }

    /// Whether the session is doing work represented by the sidebar spinner,
    /// excluding the short connection pulse caused by opening a session.
    /// Sidebar ordering uses this narrower signal so selecting an idle row
    /// cannot make it jump temporarily while its transcript connects.
    func isInProgress(_ session: ChatSession) -> Bool {
        guard let controller = controllers[SessionKey(session)] else { return false }
        return Self.isInProgress(controller)
    }

    /// Whether any cached session on a given server is doing real work
    /// (generating a response or running pre-chat setup). Gates app/server
    /// updates so a restart never interrupts a live turn. The transient
    /// connect pulse on first open deliberately does not block an update.
    func hasActiveSessions(onServer serverId: String) -> Bool {
        _ = activityRevision
        return controllers.values.contains { controller in
            controller.serverSession?.serverId == serverId && Self.isActivelyWorking(controller)
        }
    }

    private static func isActivelyWorking(_ controller: SessionController) -> Bool {
        controller.isSending
            || controller.setupPhases.contains(where: \.isRunning)
    }

    private static func isInProgress(_ controller: SessionController) -> Bool {
        isActivelyWorking(controller) || controller.isWaitingOnBackgroundTasks
    }

    /// Whether the session is blocked waiting on the user — an agent question or
    /// a plan-approval prompt. The model isn't busy, it needs a response, so the
    /// sidebar surfaces this as the attention badge instead of the spinner.
    func isWaitingOnUser(_ session: ChatSession) -> Bool {
        guard let controller = controllers[SessionKey(session)] else { return false }
        return controller.pendingQuestion != nil || controller.pendingPlanApproval
    }

    private func isWaitingOnUser(_ key: SessionKey) -> Bool {
        guard let controller = controllers[key] else { return false }
        return controller.pendingQuestion != nil || controller.pendingPlanApproval
    }

    // MARK: - Unread badges

    /// Finished-and-not-yet-opened turns for a session — the sidebar badge count.
    func unreadCount(_ session: ChatSession) -> Int {
        unreadCounts[SessionKey(session)] ?? 0
    }

    /// Manually flags a session as unread (sidebar context menu). Keeps any
    /// existing turn-finish count rather than resetting it to 1.
    func markUnread(_ session: ChatSession) {
        let key = SessionKey(session)
        unreadCounts[key] = max(1, unreadCounts[key] ?? 0)
    }

    /// Marks a session as the one on screen and clears its unread badge.
    func markOpened(_ sessionId: UUID, serverId: String) {
        let key = SessionKey(serverId: serverId, sessionId: sessionId)
        openSessionKey = key
        unreadCounts[key] = nil
        notificationDelivery.clearNotifications(for: sessionId)
    }

    /// Called when navigation leaves the session detail (new chat, nothing
    /// selected), so finished turns start counting as unread again.
    func clearOpenSession() {
        openSessionKey = nil
    }

    func setWindowFocused(_ focused: Bool) {
        isWindowFocused = focused
    }

    private func noteTurnEnded(for key: SessionKey) {
        activityRevision &+= 1
        // Transcript/runtime events are session-scoped and intentionally do
        // not invalidate the global projects snapshot. Advance the sidebar's
        // local recency stamp at the completion edge instead of waiting for an
        // unrelated metadata refresh to pick up the server's updated value.
        environment.projectList.touchSession(key.sessionId, serverId: key.serverId)
        // A turn that ends into a "waiting on background work" state isn't the
        // end of the agent's work — it will start an agent-initiated turn when
        // the task settles. Hold the unread badge (the spinner covers this via
        // `isRunning`) until that follow-up turn ends with nothing left waiting.
        if controllers[key]?.isWaitingOnBackgroundTasks == true { return }
        let kind: ChatAttentionKind = isWaitingOnUser(key) ? .actionRequired : .finished
        deliverNotification(for: key, kind: kind)
        guard key != openSessionKey else { return }
        unreadCounts[key, default: 0] += 1
    }

    private func noteActionRequired(for key: SessionKey) {
        deliverNotification(for: key, kind: .actionRequired)
    }

    private func deliverNotification(for key: SessionKey, kind: ChatAttentionKind) {
        guard let session = environment.projectList.sessions.first(where: {
            $0.serverId == key.serverId && $0.id == key.sessionId
        }) else { return }
        notificationDelivery.deliver(
            ChatAttentionEvent(
                sessionId: session.id,
                serverId: session.serverId,
                sessionTitle: session.title,
                kind: kind
            ),
            sessionIsOpen: key == openSessionKey && isWindowFocused
        )
    }

    /// Registers a draft controller under a newly created session id and
    /// releases the draft slot so the next new chat starts fresh.
    func register(_ controller: SessionController, for session: ChatSession) {
        let key = SessionKey(session)
        controller.scrollState = scrollStates[key]
        controller.onScrollStateChange = { [weak self] state in
            self?.scrollStates[key] = state
        }
        controller.restoreTodoDisclosure(
            isExpanded: todoExpansionStates[key] ?? true,
            wasCompleted: todoCompletionStates[key] ?? false
        )
        controller.onTodosExpandedChange = { [weak self] isExpanded in
            self?.todoExpansionStates[key] = isExpanded
        }
        controller.onTodosCompletionChange = { [weak self] isCompleted in
            self?.todoCompletionStates[key] = isCompleted
        }
        controller.onTurnEnded = { [weak self] in self?.noteTurnEnded(for: key) }
        controller.onActionRequired = { [weak self] in self?.noteActionRequired(for: key) }
        controllers[key] = controller
        if draftsByServer[controller.project.serverId] === controller {
            draftsByServer[controller.project.serverId] = nil
        }
    }

    /// Reverts a failed first-send promotion: forgets the session registration
    /// (the record is being deleted) and returns the controller to the draft
    /// slot, so the reopened new-chat page picks it back up with its restored
    /// composer text and failure status.
    func demote(_ controller: SessionController, session: ChatSession) {
        let key = SessionKey(session)
        if controllers[key] === controller { controllers[key] = nil }
        paneGroups[key]?.detachAll()
        paneGroups[key] = nil
        scratchpads[key]?.flush()
        scratchpads[key] = nil
        unreadCounts[key] = nil
        scrollStates[key] = nil
        todoExpansionStates[key] = nil
        todoCompletionStates[key] = nil
        draftsByServer[controller.project.serverId] = controller
    }

    func discard(_ session: ChatSession) {
        let key = SessionKey(session)
        controllers[key]?.model?.shutdown()
        controllers[key] = nil
        paneGroups[key]?.detachAll()
        paneGroups[key] = nil
        scratchpads[key]?.flush()
        scratchpads[key] = nil
        unreadCounts[key] = nil
        scrollStates[key] = nil
        todoExpansionStates[key] = nil
        todoCompletionStates[key] = nil
        accessOrder.removeAll { $0 == key }
    }

    // MARK: - Eviction

    /// Bumps a session to most-recently-used and evicts idle controllers
    /// beyond the cache limit. Pane groups are deliberately NOT evicted:
    /// their panes hold live server PTYs that must survive navigation.
    private func noteAccess(_ key: SessionKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        evictIdleControllers()
    }

    private func isRunning(_ key: SessionKey) -> Bool {
        guard let controller = controllers[key] else { return false }
        return Self.isInProgress(controller) || controller.isConnecting
    }

    /// Frees the least-recently-used cached controllers, keeping every
    /// controller that could still produce activity: the open session,
    /// anything running/connecting/in setup, sessions the agent will return
    /// to on its own (background tasks, active goals). Evicted sessions
    /// reload from server history on next open.
    private func evictIdleControllers() {
        let idle = accessOrder.filter { id in
            guard let controller = controllers[id] else { return false }
            return id != openSessionKey
                && !isRunning(id)
                && !controller.isWaitingOnBackgroundTasks
                && controller.goal?.status != .active
        }
        guard idle.count > Self.maxIdleControllers else { return }
        for id in idle.dropLast(Self.maxIdleControllers) {
            controllers[id]?.model?.shutdown()
            controllers[id] = nil
        }
    }
}
