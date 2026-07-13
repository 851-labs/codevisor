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
    private var controllers: [UUID: SessionController] = [:]
    /// Tiny viewport snapshots outlive controller eviction. Observation is
    /// intentionally disabled: scroll ticks must never invalidate the store's
    /// sidebar/session observers.
    @ObservationIgnored private var scrollStates: [UUID: SessionScrollState] = [:]
    /// Per-session todo-panel expansion, kept outside the controller cache for
    /// the same reason as transcript viewport state.
    @ObservationIgnored private var todoExpansionStates: [UUID: Bool] = [:]
    /// Completion edges are cached alongside expansion so reopening a finished
    /// checklist survives navigation and controller eviction.
    @ObservationIgnored private var todoCompletionStates: [UUID: Bool] = [:]
    private var paneGroups: [UUID: PaneGroupModel] = [:]
    private var scratchpads: [UUID: ScratchpadModel] = [:]
    /// The unsent new-chat draft. A single slot — the new-chat page is one
    /// place — so composer text/attachments survive navigating away and back
    /// no matter which sidebar entry reopens it.
    private var draft: SessionController?
    /// Turns that finished while their session wasn't open, keyed by session
    /// id — the sidebar's iOS-style unread badges. Cleared on open.
    private var unreadCounts: [UUID: Int] = [:]
    /// Invalidates views that observe aggregate activity across the cached
    /// controllers. A turn can finish without otherwise mutating this store
    /// (most notably when its session is open), so nested controller
    /// observation alone can leave cross-session UI such as update banners
    /// holding onto its previous value.
    private var activityRevision = 0
    /// The session currently shown in the detail column; its finished turns
    /// never count as unread.
    private var openSessionId: UUID?
    /// Whether this store's window is key. A selected chat behind Settings or
    /// another Codevisor window is not the focused chat for sound suppression.
    private var isWindowFocused = false
    /// Session ids in access order, most recent last — drives controller
    /// eviction so browsing many sessions doesn't accumulate every transcript
    /// ever opened (conversations retain full tool outputs and diffs).
    private var accessOrder: [UUID] = []
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
        noteAccess(session.id)
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
        controller.scrollState = scrollStates[session.id]
        controller.onScrollStateChange = { [weak self] state in
            self?.scrollStates[session.id] = state
        }
        controller.restoreTodoDisclosure(
            isExpanded: todoExpansionStates[session.id] ?? true,
            wasCompleted: todoCompletionStates[session.id] ?? false
        )
        controller.onTodosExpandedChange = { [weak self] isExpanded in
            self?.todoExpansionStates[session.id] = isExpanded
        }
        controller.onTodosCompletionChange = { [weak self] isCompleted in
            self?.todoCompletionStates[session.id] = isCompleted
        }
        controller.onTurnEnded = { [weak self] in self?.noteTurnEnded(for: session.id) }
        controller.onActionRequired = { [weak self] in self?.noteActionRequired(for: session.id) }
        controllers[session.id] = controller
        return controller
    }

    /// Returns the retained draft controller for the new-chat page, creating
    /// one seeded from the last-used composer defaults (harness, model,
    /// worktree) if none exists. The draft is retained until its first send
    /// promotes it to a real session, so unsent composer state survives
    /// navigation.
    func draft(project: Project) -> SessionController {
        if let draft, draft.serverSession == nil {
            return draft
        }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            settings: environment.settings,
            serverClient: environment.serverClient
        )
        controller.applyComposerDefaults()
        draft = controller
        return controller
    }

    /// Returns the cached pane group for a session, creating it on first use.
    /// Mirrors `controller(for:project:)` so panes (and their terminals)
    /// survive panel close + navigation away and back.
    func paneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
        if let existing = paneGroups[session.id] { return existing }
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
                let liveSession = projectList?.sessions.first { $0.id == session.id } ?? session
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
        paneGroups[session.id] = group
        return group
    }

    /// Returns the cached scratchpad for a session, creating it (seeded from
    /// the repository) on first use, so notes and the inspector's open state
    /// survive navigation away and back.
    func scratchpad(for session: ChatSession) -> ScratchpadModel {
        if let existing = scratchpads[session.id] { return existing }
        let model = ScratchpadModel(sessionId: session.id, repository: environment.scratchpads)
        scratchpads[session.id] = model
        return model
    }

    /// Whether the session with this id is showing activity: generating a
    /// response, connecting its agent, running pre-chat setup (worktree
    /// creation, agent start), or waiting on background work it will return to
    /// on its own — everything the sidebar spinner covers.
    func isRunning(_ sessionId: UUID) -> Bool {
        guard let controller = controllers[sessionId] else { return false }
        return Self.isInProgress(controller) || controller.isConnecting
    }

    /// Whether the session is doing work represented by the sidebar spinner,
    /// excluding the short connection pulse caused by opening a session.
    /// Sidebar ordering uses this narrower signal so selecting an idle row
    /// cannot make it jump temporarily while its transcript connects.
    func isInProgress(_ sessionId: UUID) -> Bool {
        guard let controller = controllers[sessionId] else { return false }
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
    func isWaitingOnUser(_ sessionId: UUID) -> Bool {
        guard let controller = controllers[sessionId] else { return false }
        return controller.pendingQuestion != nil || controller.pendingPlanApproval
    }

    // MARK: - Unread badges

    /// Finished-and-not-yet-opened turns for a session — the sidebar badge count.
    func unreadCount(_ sessionId: UUID) -> Int {
        unreadCounts[sessionId] ?? 0
    }

    /// Manually flags a session as unread (sidebar context menu). Keeps any
    /// existing turn-finish count rather than resetting it to 1.
    func markUnread(_ sessionId: UUID) {
        unreadCounts[sessionId] = max(1, unreadCounts[sessionId] ?? 0)
    }

    /// Marks a session as the one on screen and clears its unread badge.
    func markOpened(_ sessionId: UUID) {
        openSessionId = sessionId
        unreadCounts[sessionId] = nil
        notificationDelivery.clearNotifications(for: sessionId)
    }

    /// Called when navigation leaves the session detail (new chat, nothing
    /// selected), so finished turns start counting as unread again.
    func clearOpenSession() {
        openSessionId = nil
    }

    func setWindowFocused(_ focused: Bool) {
        isWindowFocused = focused
    }

    private func noteTurnEnded(for sessionId: UUID) {
        activityRevision &+= 1
        // A turn that ends into a "waiting on background work" state isn't the
        // end of the agent's work — it will start an agent-initiated turn when
        // the task settles. Hold the unread badge (the spinner covers this via
        // `isRunning`) until that follow-up turn ends with nothing left waiting.
        if controllers[sessionId]?.isWaitingOnBackgroundTasks == true { return }
        let kind: ChatAttentionKind = isWaitingOnUser(sessionId) ? .actionRequired : .finished
        deliverNotification(for: sessionId, kind: kind)
        guard sessionId != openSessionId else { return }
        unreadCounts[sessionId, default: 0] += 1
    }

    private func noteActionRequired(for sessionId: UUID) {
        deliverNotification(for: sessionId, kind: .actionRequired)
    }

    private func deliverNotification(for sessionId: UUID, kind: ChatAttentionKind) {
        guard let session = environment.projectList.sessions.first(where: { $0.id == sessionId }) else { return }
        notificationDelivery.deliver(
            ChatAttentionEvent(
                sessionId: session.id,
                serverId: session.serverId,
                sessionTitle: session.title,
                kind: kind
            ),
            sessionIsOpen: sessionId == openSessionId && isWindowFocused
        )
    }

    /// Registers a draft controller under a newly created session id and
    /// releases the draft slot so the next new chat starts fresh.
    func register(_ controller: SessionController, for sessionId: UUID) {
        controller.scrollState = scrollStates[sessionId]
        controller.onScrollStateChange = { [weak self] state in
            self?.scrollStates[sessionId] = state
        }
        controller.restoreTodoDisclosure(
            isExpanded: todoExpansionStates[sessionId] ?? true,
            wasCompleted: todoCompletionStates[sessionId] ?? false
        )
        controller.onTodosExpandedChange = { [weak self] isExpanded in
            self?.todoExpansionStates[sessionId] = isExpanded
        }
        controller.onTodosCompletionChange = { [weak self] isCompleted in
            self?.todoCompletionStates[sessionId] = isCompleted
        }
        controller.onTurnEnded = { [weak self] in self?.noteTurnEnded(for: sessionId) }
        controller.onActionRequired = { [weak self] in self?.noteActionRequired(for: sessionId) }
        controllers[sessionId] = controller
        if draft === controller { draft = nil }
    }

    /// Reverts a failed first-send promotion: forgets the session registration
    /// (the record is being deleted) and returns the controller to the draft
    /// slot, so the reopened new-chat page picks it back up with its restored
    /// composer text and failure status.
    func demote(_ controller: SessionController, sessionId: UUID) {
        if controllers[sessionId] === controller { controllers[sessionId] = nil }
        paneGroups[sessionId]?.detachAll()
        paneGroups[sessionId] = nil
        scratchpads[sessionId]?.flush()
        scratchpads[sessionId] = nil
        unreadCounts[sessionId] = nil
        scrollStates[sessionId] = nil
        todoExpansionStates[sessionId] = nil
        todoCompletionStates[sessionId] = nil
        draft = controller
    }

    func discard(_ sessionId: UUID) {
        controllers[sessionId]?.model?.shutdown()
        controllers[sessionId] = nil
        paneGroups[sessionId]?.detachAll()
        paneGroups[sessionId] = nil
        scratchpads[sessionId]?.flush()
        scratchpads[sessionId] = nil
        unreadCounts[sessionId] = nil
        scrollStates[sessionId] = nil
        todoExpansionStates[sessionId] = nil
        todoCompletionStates[sessionId] = nil
        accessOrder.removeAll { $0 == sessionId }
    }

    // MARK: - Eviction

    /// Bumps a session to most-recently-used and evicts idle controllers
    /// beyond the cache limit. Pane groups are deliberately NOT evicted:
    /// their panes hold live server PTYs that must survive navigation.
    private func noteAccess(_ sessionId: UUID) {
        accessOrder.removeAll { $0 == sessionId }
        accessOrder.append(sessionId)
        evictIdleControllers()
    }

    /// Frees the least-recently-used cached controllers, keeping every
    /// controller that could still produce activity: the open session,
    /// anything running/connecting/in setup, sessions the agent will return
    /// to on its own (background tasks, active goals). Evicted sessions
    /// reload from server history on next open.
    private func evictIdleControllers() {
        let idle = accessOrder.filter { id in
            guard let controller = controllers[id] else { return false }
            return id != openSessionId
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
