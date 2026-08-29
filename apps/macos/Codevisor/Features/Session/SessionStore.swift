// swiftlint:disable file_length type_body_length

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

    /// Identity cache, not presentation state. Views resolve controllers while
    /// constructing pane trees; tracking cache insertion would invalidate the
    /// AttributeGraph from inside that same render pass. The controllers are
    /// observable themselves, while `activityRevision` covers aggregate reads.
    @ObservationIgnored private var controllers: [SessionKey: SessionController] = [:]
    /// Tiny viewport snapshots share the controller cache's lifetime. This
    /// restores an exact position while its transcript remains resident, while
    /// a genuinely uncached chat opens at the latest content after reloading.
    /// Observation is intentionally disabled: scroll ticks must never
    /// invalidate the store's sidebar/session observers.
    @ObservationIgnored private var scrollStates: [SessionKey: SessionScrollState] = [:]
    /// Recent chats retain their mounted native transcript window in addition
    /// to model and geometry state. This is deliberately observation-ignored:
    /// resolving a pane's presentation surface must remain an identity lookup,
    /// not invalidate every session view.
    @ObservationIgnored private var transcriptSurfaces =
        TranscriptPresentationSurfaceCache()
    /// Per-session todo-panel expansion deliberately outlives controller
    /// eviction so pinned checklists retain their disclosure state.
    @ObservationIgnored private var todoExpansionStates: [SessionKey: Bool] = [:]
    /// Bottom-panel models by WORKSPACE (the panel belongs to the
    /// workspace, and its chats share one detail container — a per-session
    /// key would mint duplicate models over the same persisted group).
    @ObservationIgnored private var bottomGroups: [UUID: PaneGroupModel] = [:]
    /// Center-tree leaf groups, keyed by (workspace, leaf group) — the ONE
    /// model per leaf that both the top bar and the split view share.
    private struct CenterLeafKey: Hashable {
        let workspaceId: UUID
        let groupId: UUID
    }
    @ObservationIgnored private var centerLeafGroups: [CenterLeafKey: PaneGroupModel] = [:]
    /// One live unsent new-chat draft per machine, mirrored to disk by
    /// `ComposerDraftStore`. A controller permanently owns the server client
    /// it was created with, so reusing a draft after a machine switch can send
    /// the new machine's project id to the old server.
    @ObservationIgnored var draftsByServer: [String: SessionController] = [:]
    /// One draft controller per DRAFT CHAT PANE (the in-workspace new-chat
    /// composer), keyed by pane id. Promoted to the session cache on first
    /// send; discarded when the pane closes unsent.
    @ObservationIgnored private var paneDrafts: [UUID: SessionController] = [:]
    /// Invalidates views that observe aggregate activity across the cached
    /// controllers. A turn can finish without otherwise mutating this store
    /// (most notably when its session is open), so nested controller
    /// observation alone can leave cross-session UI such as update banners
    /// holding onto its previous value.
    private var activityRevision = 0
    /// The session selected by navigation. It is used for controller
    /// retention, never as proof that content was read.
    private var openSessionKey: SessionKey?
    /// The chat pane facing the user in this window: the selected chat pane
    /// of the active split leaf. Combined with window key state below, this
    /// is what the app-wide attention coordinator treats as "focused" — the
    /// chat it marks read.
    private var focusedChatKey: SessionKey?
    /// Whether this store's window is key. A selected chat behind Settings or
    /// another Codevisor window is not the focused chat.
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
    // Internal so split-off extension files (workspace helpers) reach it.
    let environment: AppEnvironment
    let notificationDelivery: any ChatNotificationDelivering

    init(
        environment: AppEnvironment,
        notificationDelivery: (any ChatNotificationDelivering)? = nil
    ) {
        self.environment = environment
        self.notificationDelivery = notificationDelivery ?? ChatNotificationManager.shared
        environment.onMachineRouteChanged = { [weak self] machineId in
            self?.rerouteControllers(on: machineId)
        }
    }

    /// A route flip (direct ↔ relay) leaves cached controllers streaming
    /// over a dead transport. Re-home each affected chat: adopt a client
    /// resolved over the new route, then reconnect — which replays history
    /// and resumes from the durable cursor.
    private func rerouteControllers(on machineId: String) {
        for (key, controller) in controllers where key.serverId == machineId {
            controller.adoptServerClient(environment.machines.client(for: machineId))
            Task { await controller.reconnect() }
        }
        // Drafts have no live stream, but their next send must ride the new
        // route too.
        for controller in draftsByServer.values
        where controller.project.serverId == machineId {
            controller.adoptServerClient(environment.machines.client(for: machineId))
        }
    }

    /// Returns the cached controller for a session, creating + configuring it
    /// (resume id, harness, persistence callback) if needed.
    func controller(for session: ChatSession, project: Project) -> SessionController {
        let key = SessionKey(session)
        // Registration is the durable draft -> live boundary. A first send
        // registers its controller before the server has produced an agent
        // session id, so it must win over the fallback inference below. If the
        // pane-draft check runs first, the newly bound chat briefly receives a
        // second empty controller and its optimistic row appears only when the
        // agent id later forces lookup back through this cache.
        if let existing = controllers[key] {
            noteAccess(key)
            // Cached lookup runs during view construction and must remain a
            // pure identity read. Observed controller state is reconciled by
            // explicit post-render lifecycle callbacks below.
            return existing
        }

        // A New Chat chosen from an in-workspace placeholder gets a durable
        // session record before its first send, but its live configuration
        // still belongs to the pane draft UNTIL that controller is registered.
        // Reuse (or create) that exact controller here. Minting an ordinary
        // session controller would seed it from the harness default and let
        // focus routing overwrite the workspace profile before the draft
        // composer appears.
        if session.agentSessionId?.isEmpty != false,
            let location = paneDraftLocation(for: session)
        {
            return paneDraft(
                paneId: location.paneId,
                project: project,
                preCreatedSession: session,
                workspaceId: location.workspaceId
            )
        }

        noteAccess(key)
        let workspaceId = environment.workspaces.workspaceId(forSession: session.id)
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: workspaceId == nil ? nil : environment.composerDefaults,
            composerDefaultsScope: workspaceId.map {
                .workspace(id: $0, serverId: session.serverId)
            },
            serverClient: environment.machines.client(for: session.serverId),
            notificationDelivery: notificationDelivery
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
            isExpanded: todoExpansionStates[key] ?? false
        )
        controller.onTodosExpandedChange = { [weak self] isExpanded in
            self?.todoExpansionStates[key] = isExpanded
        }
        controller.onTurnEnded = { [weak self] in self?.noteTurnEnded() }
        controllers[key] = controller
        return controller
    }

    /// Returns the pane-specific native transcript presentation. Including the
    /// pane id lets the same chat appear in two splits without one AppKit view
    /// being stolen back and forth between them.
    func transcriptSurface(
        for session: ChatSession,
        paneID: UUID,
        controller: SessionController
    ) -> TranscriptPresentationSurface {
        transcriptSurfaces.surface(
            for: .init(
                serverID: session.serverId,
                sessionID: session.id,
                paneID: paneID
            ),
            controller: controller
        )
    }

    /// Reconciles a controller after view construction (or from an explicit
    /// event callback). The identity guard prevents a stale view from writing
    /// into a controller that has since been replaced or evicted.
    func reconcile(
        _ controller: SessionController,
        for session: ChatSession,
        project: Project
    ) {
        guard activeController(for: session) === controller else { return }
        if controller.project != project {
            controller.project = project
        }
        controller.reconcileExistingSession(session)
    }

    /// The live controller for a session WITHOUT creating one — a pure read,
    /// safe in view bodies. For an eagerly-created unsent chat this is its
    /// pane-draft controller, not a second generic session controller.
    func activeController(for session: ChatSession) -> SessionController? {
        if let controller = controllers[SessionKey(session)] {
            return controller
        }
        guard session.agentSessionId?.isEmpty != false,
            let location = paneDraftLocation(for: session)
        else { return nil }
        return paneDrafts[location.paneId]
    }

    /// The live draft selected in an unbound chat pane. Split/tab inheritance
    /// uses this when the focused pane has no eager session record.
    func paneDraftController(forPane paneId: UUID) -> SessionController? {
        paneDrafts[paneId]
    }

    /// Resolves an eagerly-created unsent session back to the pane that owns
    /// its draft controller.
    private func paneDraftLocation(
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

    private func enablePaneDraftPersistence(for controller: SessionController, paneId: UUID) {
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
        guard
            let leafId = workspace.centerTabs.lazy.compactMap({
                $0.root.groupId(containingChat: session.id)
            }).first
                ?? workspace.centerTree.allGroups.first?.id
        else {
            // Unreachable (a workspace always has a leaf); satisfies the
            // optional without a second cache.
            return makePaneGroup(for: session, project: project, placement: .center)
        }
        return centerGroup(leafId: leafId, workspace: workspace, session: session, project: project)
    }

    /// The workspace owning this session's chat, created (backfilled from
    /// the session + any pre-workspace pane state) on first access.
    func workspace(for session: ChatSession, project: Project) -> Workspace {
        let seed = WorkspaceSessionSeed(
            sessionId: session.id,
            initialName: session.worktreeName ?? project.name,
            serverId: session.serverId,
            projectId: project.id,
            rootDirectory: session.cwd ?? project.folderURL.path,
            worktreeName: session.worktreeName
        )
        // A chat that is no longer active and has NO persisted workspace must
        // not mint one: archiving a scratch chat deletes its workspace (index
        // entry included), and the chat's still-mounted screen re-evaluates
        // during the teardown transition — persisting here resurrected the
        // just-deleted workspace as a zombie sidebar row. Hand such screens a
        // stable ephemeral stand-in instead.
        if environment.workspaces.workspaceId(forSession: session.id) == nil,
            !environment.projectList.sessions.contains(where: {
                $0.serverId == session.serverId && $0.id == session.id && !$0.isArchived
            })
        {
            if let cached = ephemeralWorkspaces[session.id] { return cached }
            let ephemeral = environment.workspaces.ephemeralWorkspace(for: seed)
            ephemeralWorkspaces[session.id] = ephemeral
            return ephemeral
        }
        return environment.workspaces.ensureWorkspace(
            for: seed,
            legacyGroups: environment.paneGroups
        )
    }

    /// Stand-in workspaces for chats mid-teardown (see `workspace(for:)`);
    /// cached so repeated body evaluations see one stable identity.
    @ObservationIgnored private var ephemeralWorkspaces: [UUID: Workspace] = [:]

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

    /// Pushes repository truth into pane models that are already mounted.
    /// Workspace sync owns the repository write; these model updates are a
    /// non-persisting presentation reconciliation so they cannot echo remote
    /// changes back to the server.
    @discardableResult
    func reconcileMountedPaneGroups(in workspace: Workspace) -> Bool {
        var changed = false
        if let bottom = bottomGroups[workspace.id] {
            changed = bottom.reconcileExternalState(workspace.bottomGroup) || changed
        }

        let centerStates = Dictionary(
            uniqueKeysWithValues: workspace.centerTabs.flatMap { tab in
                tab.root.allGroups.map { ($0.id, $0.state) }
            }
        )
        var removedKeys: [CenterLeafKey] = []
        for (key, model) in centerLeafGroups where key.workspaceId == workspace.id {
            if let state = centerStates[key.groupId] {
                changed = model.reconcileExternalState(state) || changed
            } else {
                changed = model.reconcileExternalState(PaneGroupState()) || changed
                removedKeys.append(key)
            }
        }
        for key in removedKeys {
            centerLeafGroups[key] = nil
        }
        return changed
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
        let resolvedLeafId =
            placement == .center
            ? (leafId
                ?? workspace.centerTabs.lazy.compactMap {
                    $0.root.groupId(containingChat: session.id)
                }.first)
            : nil
        let repository = WorkspacePaneGroupRepository(
            workspaceId: workspace.id,
            groupId: resolvedLeafId,
            repository: environment.workspaces
        )
        let client = environment.machines.client(for: session.serverId)
        let workspaceIdForPanes = workspace.id
        let model = PaneGroupModel(
            sessionId: session.id,
            placement: placement,
            repository: repository,
            pluginIconClient: client,
            pluginIconCacheNamespace: session.serverId,
            makeContext: {
                [
                    weak projectList = environment.projectList,
                    weak machines = environment.machines
                ] descriptor in
                // Panes are built lazily, so this cached closure can outlive
                // the snapshot passed in above: a fresh worktree session may
                // not have synced its cwd yet. Resolve the live session at
                // pane-creation time so terminals open in the worktree, not
                // the project folder.
                let liveSession =
                    projectList?.sessions.first {
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
                    workspaceId: workspaceIdForPanes,
                    client: client,
                    resolveHTTPBaseURL: {
                        await machines?.effectiveHTTPBaseURL(forMachineId: session.serverId)
                    }
                )
            }
        )
        model.onPaneChanged = { [weak environment] pane in
            guard let environment else { return }
            environment.workspaceSync.publishPane(
                pane,
                workspaceId: workspace.id,
                client: environment.machines.client(for: session.serverId)
            )
        }
        let workspaceId = workspace.id
        model.shouldReplaceClosedPaneWithNewTab = { [weak environment] pane in
            guard let liveWorkspace = environment?.workspaces.workspace(id: workspaceId) else {
                return false
            }
            let panes =
                liveWorkspace.centerTabs.flatMap { tab in
                    tab.root.allGroups.flatMap(\.state.panes)
                } + liveWorkspace.bottomGroup.panes
            return panes.count == 1 && panes[0].id == pane.id
        }
        model.onPaneRemoved = { [weak environment] pane, replacement in
            guard let environment else { return }
            environment.workspaceSync.deletePane(
                id: pane.id,
                workspaceId: workspaceId,
                optimisticReplacement: replacement,
                client: environment.machines.client(for: session.serverId)
            )
        }
        // Identity for cross-group drops (bar targets, content zones).
        model.dropRef =
            placement == .bottom
            ? .bottom
            : resolvedLeafId.map { .centerLeaf($0) }
        return model
    }

    /// Drops a dissolved leaf's cached model (its panes have already moved
    /// elsewhere — nothing to detach).
    func evictCenterLeaf(workspaceId: UUID, leafId: UUID) {
        centerLeafGroups[CenterLeafKey(workspaceId: workspaceId, groupId: leafId)] = nil
    }

    /// Whether the session is doing work the user should see as activity:
    /// generating a response, running pre-chat setup (worktree creation, agent
    /// start), or waiting on background work it will return to on its own.
    ///
    /// Deliberately excludes the connection pulse from opening a session —
    /// connecting is loading, not activity, so the leading icon keeps showing
    /// the harness icon and sidebar ordering does not make an idle row jump
    /// while its transcript connects.
    func isInProgress(_ session: ChatSession) -> Bool {
        guard let controller = controllers[SessionKey(session)] else {
            return session.sidebarState == .inProgress
        }
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
        // A first-send optimistic row exists before the provider flips
        // `model.isSending`. Keep it in its final visible tier from insertion
        // onward instead of briefly adding it as idle and reordering it again.
        controller.pendingUserMessage != nil
            || isActivelyWorking(controller)
            || controller.isWaitingOnBackgroundTasks
    }

    /// Whether the session is blocked waiting on the user — an agent question or
    /// a plan-approval prompt. The model isn't busy, it needs a response, so the
    /// sidebar surfaces this as the attention badge instead of the spinner.
    func isWaitingOnUser(_ session: ChatSession) -> Bool {
        guard let controller = controllers[SessionKey(session)] else {
            return session.actionRequired
        }
        return session.actionRequired
            || controller.pendingQuestion != nil
            || controller.pendingPlanApproval
    }

    // MARK: - Unread badges

    /// Finished-and-not-yet-acknowledged turns — the sidebar badge count.
    func unreadCount(_ session: ChatSession) -> Int {
        session.unreadCount
    }

    func hasUnreadError(_ session: ChatSession) -> Bool {
        session.hasUnreadError
    }

    /// Manually flags a session as unread (sidebar context menu). Keeps any
    /// existing turn-finish count rather than resetting it to 1.
    func markUnread(_ session: ChatSession) {
        environment.projectList.markSessionUnread(session.id, serverId: session.serverId)
    }

    /// Manually clears a session's unread badge (sidebar context menu) without
    /// making it the on-screen session. Banner clearing rides the resulting
    /// read transition through the attention coordinator.
    func markRead(_ session: ChatSession) {
        environment.projectList.markSessionRead(session.id, serverId: session.serverId)
    }

    /// Tracks the selected session so its live controller stays in the cache.
    func markOpened(_ sessionId: UUID, serverId: String) {
        let key = SessionKey(serverId: serverId, sessionId: sessionId)
        openSessionKey = key
    }

    /// Called when navigation leaves the session detail (new chat, nothing
    /// selected), so finished turns start counting as unread again.
    func clearOpenSession() {
        openSessionKey = nil
    }

    func setWindowFocused(_ focused: Bool) {
        isWindowFocused = focused
        publishFocus()
    }

    /// Publishes the chat pane facing the user in this window. Nil when a
    /// non-chat pane (terminal, new tab) is selected. Closing or deactivating
    /// the window publishes nil via `setWindowFocused` — resign-key always
    /// fires before a window goes away.
    func setFocusedChat(_ sessionId: UUID?, serverId: String) {
        focusedChatKey = sessionId.map { SessionKey(serverId: serverId, sessionId: $0) }
        publishFocus()
    }

    /// Clears focus only if `sessionId` still holds it. A container going
    /// away must not clobber the focus a newly mounted container has already
    /// published: SwiftUI mounts the incoming view (and fires its publisher)
    /// before the outgoing view's `onDisappear` runs.
    func clearFocusedChat(ifCurrent sessionId: UUID) {
        guard focusedChatKey?.sessionId == sessionId else { return }
        focusedChatKey = nil
        publishFocus()
    }

    private func publishFocus() {
        environment.attentionCoordinator.updateFocus(
            owner: ObjectIdentifier(self),
            session: isWindowFocused
                ? focusedChatKey.map {
                    SessionAttentionFocus(serverId: $0.serverId, sessionId: $0.sessionId)
                }
                : nil
        )
    }

    /// Notifications and unread state are handled by the server-side attention
    /// projection + `SessionAttentionCoordinator`; a finished turn here only
    /// invalidates aggregate-activity observers.
    private func noteTurnEnded() {
        activityRevision &+= 1
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
        transcriptSurfaces.remove(serverID: key.serverId, sessionID: key.sessionId)
        ephemeralWorkspaces[session.id] = nil
        detachBottomGroup(for: session)
        detachCenterLeaves(for: session)
        scrollStates[key] = nil
        todoExpansionStates[key] = nil
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
            let controller = controllers.removeValue(forKey: id)
            controller?.onScrollStateChange = nil
            controller?.model?.shutdown()
            scrollStates[id] = nil
            transcriptSurfaces.remove(serverID: id.serverId, sessionID: id.sessionId)
        }
    }
}
