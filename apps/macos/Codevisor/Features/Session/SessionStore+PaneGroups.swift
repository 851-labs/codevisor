import Foundation
import Observation
import CodevisorCore
import ACPKit

// MARK: - PaneGroups

extension SessionStore {
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

    func makePaneGroup(
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
}
