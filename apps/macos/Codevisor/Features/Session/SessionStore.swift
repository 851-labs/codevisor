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
    /// Bottom-panel models by WORKSPACE (the panel belongs to the
    /// workspace, and its chats share one detail container — a per-session
    /// key would mint duplicate models over the same persisted group).
    private var bottomGroups: [UUID: PaneGroupModel] = [:]
    /// Center-tree leaf groups, keyed by (workspace, leaf group) — the ONE
    /// model per leaf that both the top bar and the split view share.
    private struct CenterLeafKey: Hashable {
        let workspaceId: UUID
        let groupId: UUID
    }
    private var centerLeafGroups: [CenterLeafKey: PaneGroupModel] = [:]
    private var scratchpads: [SessionKey: ScratchpadModel] = [:]
    /// One live unsent new-chat draft per machine, mirrored to disk by
    /// `ComposerDraftStore`. A controller permanently owns the server client
    /// it was created with, so reusing a draft after a machine switch can send
    /// the new machine's project id to the old server.
    private var draftsByServer: [String: SessionController] = [:]
    /// One draft controller per DRAFT CHAT PANE (the in-workspace new-chat
    /// composer), keyed by pane id. Promoted to the session cache on first
    /// send; discarded when the pane closes unsent.
    private var paneDrafts: [UUID: SessionController] = [:]
    /// Completed activity epochs whose session wasn't open, keyed by session
    /// id — the sidebar's iOS-style unread badges. Cleared on open.
    private var unreadCounts: [SessionKey: Int] = [:]
    /// Unread sessions whose completed activity epoch ended abnormally. Kept
    /// beside the count so controller eviction cannot erase the red indicator.
    private var unreadErrors: Set<SessionKey> = []
    /// One deferred attention outcome per user-created activity epoch. Agent
    /// follow-ups merge into it; only stable quiescence consumes it, preventing
    /// one alert per Claude background-task notification.
    private var pendingAttentionErrors: [SessionKey: Bool] = [:]
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
    /// OBSERVATION-IGNORED, deliberately: `controller(for:)` bumps this
    /// during view bodies (each chat pane resolves its controller there), and
    /// an observed write per body evaluation makes two chat panes invalidate
    /// each other forever — a main-thread render loop (beachball). No view
    /// reads it; it's pure LRU bookkeeping.
    @ObservationIgnored private var accessOrder: [SessionKey] = []
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
            // Only write on change: this runs during view bodies (chat panes
            // resolve their controllers there), and unconditional writes to
            // observed properties re-invalidate the views that read them.
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
            serverClient: environment.machines.client(for: session.serverId)
        )
        controller.configureExistingSession(session)
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
        controller.onRuntimeStateChanged = { [weak self] in self?.noteRuntimeStateChanged(for: key) }
        controller.onGoalChanged = { [weak self] in self?.noteGoalChanged(for: key) }
        controller.onActionRequired = { [weak self] in self?.noteActionRequired(for: key) }
        controllers[key] = controller
        return controller
    }

    /// Returns the retained draft controller for the new-chat page, restoring
    /// its disk snapshot first or seeding it from last-used composer defaults
    /// if none exists. The draft is retained until its first send promotes it
    /// to a real session, so unsent composer state survives navigation and
    /// relaunches.
    func draft(project: Project) -> SessionController {
        if let draft = draftsByServer[project.serverId], draft.serverSession == nil {
            return draft
        }
        let persisted = environment.composerDrafts.draft(forServer: project.serverId)
        let restoredProject = persisted.flatMap { saved in
            environment.projectList.projects.first {
                $0.serverId == project.serverId && $0.id == saved.projectId
            }
        } ?? project
        let controller = SessionController(
            project: restoredProject,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.serverClient
        )
        controller.applyComposerDefaults()
        if let persisted { controller.restoreDraft(persisted) }
        enableDraftPersistence(for: controller)
        draftsByServer[project.serverId] = controller
        return controller
    }

    /// Creates a workspace around a fresh eager chat session. The workspace
    /// begins with the project's name and directory. Worktrees are per-chat
    /// contexts chosen later in the composer.
    func createWorkspaceSession(in project: Project) -> ChatSession {
        let session = environment.projectList.newSession(in: project, title: "New Chat")
        var created = workspace(for: session, project: project)
        created.name = project.name
        created.hasCustomName = false
        created.symbolName = project.symbolName
        environment.workspaces.save(created)
        return session
    }

    /// The cached controller for a session WITHOUT creating one — a pure
    /// read, safe in view bodies (deciding whether an unstarted chat still
    /// shows its new-chat composer must not mint controllers).
    func activeController(for session: ChatSession) -> SessionController? {
        controllers[SessionKey(session)]
    }

    /// The draft controller behind an in-workspace draft chat pane (created
    /// on first use), mirrored to disk per PANE — an unsent in-workspace
    /// composer (text, attachments, settings) survives relaunches and app
    /// updates just like the per-server page draft does.
    func paneDraft(
        paneId: UUID,
        project: Project,
        preCreatedSession: ChatSession? = nil
    ) -> SessionController {
        if let existing = paneDrafts[paneId] { return existing }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.serverClient
        )
        controller.applyComposerDefaults()
        // A session created eagerly INTO a worktree (the New tab page's
        // directory pick) seeds the composer with that context — otherwise
        // the picker would show the project root and the first send would
        // wipe the recorded worktree. Seed BEFORE the draft restore: a
        // persisted draft carries the user's later choice and must win.
        if let preCreatedSession,
           let name = preCreatedSession.worktreeName,
           let cwd = preCreatedSession.cwd {
            controller.setRunContext(.existingWorktree(name: name, path: cwd))
        }
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

    private func enablePaneDraftPersistence(for controller: SessionController, paneId: UUID) {
        controller.onDraftChange = { [weak drafts = environment.composerDrafts] draft in
            drafts?.savePaneDraft(draft, forPane: paneId)
        }
        environment.composerDrafts.savePaneDraft(controller.draftSnapshot(), forPane: paneId)
    }

    private func enableDraftPersistence(for controller: SessionController) {
        let serverId = controller.project.serverId
        controller.onDraftChange = { [weak drafts = environment.composerDrafts] draft in
            drafts?.saveDraft(draft, forServer: serverId)
        }
        environment.composerDrafts.saveDraft(controller.draftSnapshot(), forServer: serverId)
    }

    /// Returns the cached bottom-panel pane group for a session's WORKSPACE,
    /// creating it on first use. Mirrors `controller(for:project:)` so panes
    /// (and their terminals) survive panel close + navigation away and back.
    func paneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
        let workspaceId = workspace(for: session, project: project).id
        if let existing = bottomGroups[workspaceId] { return existing }
        let group = makePaneGroup(for: session, project: project, placement: .bottom)
        bottomGroups[workspaceId] = group
        return group
    }

    /// The center group hosting this session's chat: THE SAME model instance
    /// the split view renders for that leaf (one model per leaf, ever —
    /// duplicate instances would clobber each other's saves).
    func centerPaneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
        let workspace = workspace(for: session, project: project)
        guard let leafId = workspace.centerTabs.lazy.compactMap({
            $0.root.groupId(containingChat: session.id)
        }).first
            ?? workspace.centerTree.allGroups.first?.id else {
            // Unreachable (a workspace always has a leaf); satisfies the
            // optional without a second cache.
            return makePaneGroup(for: session, project: project, placement: .center)
        }
        return centerGroup(leafId: leafId, workspace: workspace, session: session, project: project)
    }

    /// The workspace owning this session's chat, created (backfilled from
    /// the session + any pre-workspace pane state) on first access.
    func workspace(for session: ChatSession, project: Project) -> Workspace {
        environment.workspaces.ensureWorkspace(
            for: WorkspaceSessionSeed(
                sessionId: session.id,
                initialName: session.worktreeName ?? project.name,
                serverId: session.serverId,
                projectId: project.id,
                rootDirectory: session.cwd ?? project.folderURL.path
            ),
            legacyGroups: environment.paneGroups
        )
    }

    /// Persists a divider drag: the workspace's center tree with updated
    /// fractions (same topology).
    func saveCenterTree(_ tree: SplitNode, workspaceId: UUID) {
        guard var workspace = environment.workspaces.workspace(id: workspaceId) else { return }
        workspace.centerTree = tree
        environment.workspaces.save(workspace)
    }

    /// A specific center-tree LEAF's group model (split groups beyond the
    /// primary). Cached per (workspace, leaf) so panes survive navigation.
    func centerGroup(
        leafId: UUID,
        workspace: Workspace,
        session: ChatSession,
        project: Project
    ) -> PaneGroupModel {
        let key = CenterLeafKey(workspaceId: workspace.id, groupId: leafId)
        if let existing = centerLeafGroups[key] { return existing }
        let group = makePaneGroup(for: session, project: project, placement: .center, leafId: leafId)
        centerLeafGroups[key] = group
        return group
    }

    private func makePaneGroup(
        for session: ChatSession,
        project: Project,
        placement: PaneGroupPlacement,
        leafId: UUID? = nil
    ) -> PaneGroupModel {
        let machine = environment.machines.machine(for: session.serverId) ?? CodevisorMachine.local
        // Pane layout persists in the session's workspace (the pre-workspace
        // per-session states migrate in on first access). Center groups pin
        // to a specific tree leaf: the given one, else the leaf hosting this
        // session's chat.
        let workspace = workspace(for: session, project: project)
        let resolvedLeafId = placement == .center
            ? (leafId ?? workspace.centerTabs.lazy.compactMap {
                $0.root.groupId(containingChat: session.id)
            }.first)
            : nil
        let repository = WorkspacePaneGroupRepository(
            workspaceId: workspace.id,
            groupId: resolvedLeafId,
            repository: environment.workspaces
        )
        let model = PaneGroupModel(
            sessionId: session.id,
            placement: placement,
            repository: repository,
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
                    project: project,
                    cwdOverride: descriptor.cwdOverride
                )
            }
        )
        // Identity for cross-group drops (bar targets, content zones).
        model.dropRef = placement == .bottom
            ? .bottom
            : resolvedLeafId.map { .centerLeaf($0) }
        return model
    }

    /// Drops a dissolved leaf's cached model (its panes have already moved
    /// elsewhere — nothing to detach).
    func evictCenterLeaf(workspaceId: UUID, leafId: UUID) {
        centerLeafGroups[CenterLeafKey(workspaceId: workspaceId, groupId: leafId)] = nil
    }

    /// Returns the cached scratchpad for a session's WORKSPACE, creating it
    /// (seeded from the repository) on first use. Workspace-scoped: the
    /// inspector's notes and open state belong to the workspace — focus-
    /// following between sibling chats must not swap notes or slam the
    /// panel shut. Notes written before workspace scoping (keyed by chat)
    /// are adopted into the workspace record on first access.
    func scratchpad(for session: ChatSession) -> ScratchpadModel {
        let workspaceId = environment.workspaces.workspaceId(forSession: session.id)
        let key = SessionKey(serverId: session.serverId, sessionId: workspaceId ?? session.id)
        if let existing = scratchpads[key] { return existing }
        let model = ScratchpadModel(
            sessionId: workspaceId ?? session.id,
            legacyId: workspaceId == nil ? nil : session.id,
            repository: environment.scratchpads
        )
        scratchpads[key] = model
        // SERVER MIRROR (workspace-scoped notes reach other clients —
        // mobile included). Push: every debounced text save uploads with
        // its LWW stamp. Pull: one fetch on model creation applies a newer
        // server copy. Both best-effort — notes never block the UI, and a
        // failed upload retries on the next edit.
        if let workspaceId {
            let client = environment.machines.client(for: session.serverId)
            model.onContentSaved = { state in
                guard let content = Self.encodeNotes(state.text) else { return }
                Task {
                    try? await client.saveWorkspaceNotes(
                        workspaceId: workspaceId,
                        content: content,
                        updatedAt: state.updatedAt ?? Date()
                    )
                }
            }
            Task { [weak model] in
                guard let notes = try? await client.workspaceNotes(workspaceId: workspaceId),
                      notes.format == "attributed-string-v1",
                      let text = Self.decodeNotes(notes.content),
                      let stamp = notes.updatedAtDate else { return }
                model?.applyRemote(text: text, updatedAt: stamp)
            }
        }
        return model
    }

    /// The notes wire format: AttributedString Codable JSON (the same
    /// encoding the local scratchpad files use), UTF-8 in a string field.
    private static func encodeNotes(_ text: AttributedString) -> String? {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeNotes(_ content: String) -> AttributedString? {
        content.data(using: .utf8).flatMap { try? JSONDecoder().decode(AttributedString.self, from: $0) }
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

    /// Whether any chat bound to `harnessId` on a machine is mid-turn — gates
    /// the immediate harness update offer (updating a busy harness waits for
    /// the when-idle flow instead).
    func hasActiveSessions(forHarness harnessId: String, onServer serverId: String) -> Bool {
        _ = activityRevision
        return controllers.values.contains { controller in
            controller.serverSession?.serverId == serverId
                && (controller.activeHarnessId ?? controller.serverSession?.harnessId) == harnessId
                && Self.isActivelyWorking(controller)
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

    func hasUnreadError(_ session: ChatSession) -> Bool {
        unreadErrors.contains(SessionKey(session))
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
        unreadErrors.remove(key)
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
        guard let controller = controllers[key] else { return }

        let failed = controller.lastTurnEndedWithError || goalNeedsErrorAttention(controller.goal)
        if controller.lastTurnInitiator == .user {
            // A human turn starts (or refreshes) the one attention epoch that
            // all of its autonomous continuations belong to.
            pendingAttentionErrors[key] = (pendingAttentionErrors[key] ?? false) || failed
        } else if pendingAttentionErrors[key] != nil {
            pendingAttentionErrors[key] = (pendingAttentionErrors[key] ?? false) || failed
        } else if failed {
            // A late autonomous failure is still important even when its
            // originating completion was already presented.
            pendingAttentionErrors[key] = true
        } else {
            // Ordinary autonomous/task-notification completions never create a
            // fresh unread badge or another sound by themselves.
            return
        }
        deliverPendingAttentionIfQuiescent(for: key)
    }

    private func noteRuntimeStateChanged(for key: SessionKey) {
        deliverPendingAttentionIfQuiescent(for: key)
    }

    private func noteGoalChanged(for key: SessionKey) {
        deliverPendingAttentionIfQuiescent(for: key)
    }

    private func deliverPendingAttentionIfQuiescent(for key: SessionKey) {
        guard var failed = pendingAttentionErrors[key], let controller = controllers[key] else { return }
        // Active goals can contain many individually-ended turns. The epoch is
        // intentionally held until the goal reaches a terminal status.
        guard controller.goal?.status != .active else { return }
        // Subagents/poll-and-resume tasks keep the epoch open. Terminal-backed
        // work (for example a dev server) is excluded by the controller.
        guard !controller.isWaitingOnBackgroundTasks, controller.isRuntimeIdle else { return }

        failed = failed || goalNeedsErrorAttention(controller.goal)
        pendingAttentionErrors[key] = nil
        let kind: ChatAttentionKind = isWaitingOnUser(key) ? .actionRequired : .finished
        deliverNotification(for: key, kind: kind)
        guard key != openSessionKey else { return }
        unreadCounts[key, default: 0] += 1
        if failed { unreadErrors.insert(key) }
    }

    private func goalNeedsErrorAttention(_ goal: SessionGoal?) -> Bool {
        guard let status = goal?.status else { return false }
        return status == .blocked || status == .usageLimited || status == .budgetLimited
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
        controller.onRuntimeStateChanged = { [weak self] in self?.noteRuntimeStateChanged(for: key) }
        controller.onGoalChanged = { [weak self] in self?.noteGoalChanged(for: key) }
        controller.onActionRequired = { [weak self] in self?.noteActionRequired(for: key) }
        controllers[key] = controller
        if draftsByServer[controller.project.serverId] === controller {
            draftsByServer[controller.project.serverId] = nil
        }
        controller.onDraftChange = nil
        environment.composerDrafts.clearDraft(forServer: controller.project.serverId)
    }

    /// Standalone counterpart to `restorePaneDraftPersistence`: retain the
    /// durable session registration while restoring the original new-chat
    /// draft/defaults persistence until the retry succeeds.
    func restoreDraftPersistence(_ controller: SessionController) {
        draftsByServer[controller.project.serverId] = controller
        enableDraftPersistence(for: controller)
    }

    /// Flushes and evicts the session's WORKSPACE scratchpad (the map is
    /// workspace-keyed; a session-keyed lookup would silently miss).
    private func flushScratchpad(for session: ChatSession) {
        let workspaceId = environment.workspaces.workspaceId(forSession: session.id)
        let key = SessionKey(serverId: session.serverId, sessionId: workspaceId ?? session.id)
        scratchpads[key]?.flush()
        scratchpads[key] = nil
    }

    /// Detaches and evicts the session's workspace bottom-panel model.
    private func detachBottomGroup(for session: ChatSession) {
        guard let workspaceId = environment.workspaces.workspaceId(forSession: session.id) else { return }
        bottomGroups[workspaceId]?.detachAll()
        bottomGroups[workspaceId] = nil
    }

    /// Detaches and evicts every cached center-leaf group of the session's
    /// workspace (backing shells survive on the server).
    private func detachCenterLeaves(for session: ChatSession) {
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
        detachBottomGroup(for: session)
        detachCenterLeaves(for: session)
        flushScratchpad(for: session)
        unreadCounts[key] = nil
        unreadErrors.remove(key)
        pendingAttentionErrors[key] = nil
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
