//  One-time migration for the "1 workspace == 1 working directory" model.
//
//  Under the old model a workspace anchored at the project root could host
//  chats running in per-chat worktrees (picked in the composer). Under the
//  new model every chat in a workspace shares the workspace's one directory,
//  so mixed workspaces are split: each worktree's chats move into their own
//  workspace, named after the worktree. Runs once per store, guarded by a
//  persisted marker.

import Foundation

public enum WorkspaceWorktreeSplitMigration {
    public static let key = "worktree-split-v1"

    /// Everything the migration needs to know about a session. Plain bag,
    /// same pattern as `WorkspaceSessionSeed`: Core never sees app types.
    public struct SessionContext: Sendable {
        public let sessionId: UUID
        public let worktreeName: String?
        public let cwd: String?

        public init(sessionId: UUID, worktreeName: String?, cwd: String?) {
            self.sessionId = sessionId
            self.worktreeName = worktreeName
            self.cwd = cwd
        }
    }

    /// Runs the split across every workspace (archived included — the
    /// invariant must hold when an archived workspace revives). Returns
    /// whether the migration ran.
    @discardableResult
    public static func runIfNeeded(
        workspaces: any WorkspaceRepository,
        sessions: [SessionContext],
        projectNames: [UUID: String]
    ) -> Bool {
        guard !workspaces.hasPerformedMigration(key) else { return false }
        let sessionsById = Dictionary(
            sessions.map { ($0.sessionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for workspace in workspaces.loadAll() {
            migrate(
                workspace,
                repository: workspaces,
                sessionsById: sessionsById,
                projectNames: projectNames
            )
        }
        workspaces.markMigrationPerformed(key)
        return true
    }

    // MARK: - Per-workspace split

    private struct ChatGroup {
        /// nil = project root (or a chat with no local session record —
        /// those are never moved, only grouped in place).
        let worktreeName: String?
        var panes: [PaneDescriptorState] = []
        var sessionIds: [UUID] = []
    }

    private static func migrate(
        _ workspace: Workspace,
        repository: any WorkspaceRepository,
        sessionsById: [UUID: SessionContext],
        projectNames: [UUID: String]
    ) {
        var workspace = workspace

        // Group the workspace's chat panes by worktree, reading order.
        var groups: [ChatGroup] = []
        for tab in workspace.centerTabs {
            for leaf in tab.root.allGroups {
                for pane in leaf.state.panes where pane.kind == .chat {
                    guard let chatId = pane.chatSessionId else { continue }
                    let name = sessionsById[chatId]?.worktreeName
                    if let index = groups.firstIndex(where: { $0.worktreeName == name }) {
                        groups[index].panes.append(pane)
                        groups[index].sessionIds.append(chatId)
                    } else {
                        groups.append(
                            ChatGroup(
                                worktreeName: name, panes: [pane], sessionIds: [chatId]
                            ))
                    }
                }
            }
        }

        func firstCwd(of group: ChatGroup) -> String? {
            group.sessionIds.lazy.compactMap { sessionsById[$0]?.cwd }.first
        }

        // Single-directory workspace: just stamp the (possibly missing)
        // worktree name and backfill the root, no split.
        guard groups.count > 1 else {
            var changed = false
            if let only = groups.first {
                if workspace.worktreeName != only.worktreeName {
                    workspace.worktreeName = only.worktreeName
                    changed = true
                }
                if workspace.rootDirectory == nil, let cwd = firstCwd(of: only) {
                    workspace.rootDirectory = cwd
                    changed = true
                }
            }
            if changed { repository.save(workspace) }
            return
        }

        // Primary group (keeps the workspace's id, name, bottom panel,
        // notes): the group already living at the workspace's root, else the
        // project-root group, else the first in reading order.
        let primaryIndex =
            groups.firstIndex { group in
                guard let root = workspace.rootDirectory else { return false }
                return firstCwd(of: group) == root
            } ?? groups.firstIndex { $0.worktreeName == nil } ?? 0
        let primary = groups[primaryIndex]

        // Every other group becomes its own workspace: one top tab per moved
        // chat pane, pane ids and terminal keys preserved so chat identity
        // and shells survive the move.
        var movedPaneIds = Set<UUID>()
        for (index, group) in groups.enumerated() where index != primaryIndex {
            group.panes.forEach { movedPaneIds.insert($0.id) }
            let tabs = group.panes.map { pane -> WorkspaceTab in
                var state = PaneGroupState()
                state.panes = [pane]
                state.selectedPaneId = pane.id
                state.isVisible = true
                return WorkspaceTab(root: .leaf(state))
            }
            let split = Workspace(
                name: group.worktreeName
                    ?? projectNames[workspace.projectId]
                    ?? "Workspace",
                hasCustomName: false,
                rootDirectory: firstCwd(of: group),
                worktreeName: group.worktreeName,
                symbolName: workspace.symbolName,
                serverId: workspace.serverId,
                projectId: workspace.projectId,
                centerTabs: tabs,
                bottomGroup: .initial(sessionId: group.sessionIds[0]),
                createdAt: workspace.createdAt,
                isArchived: workspace.isArchived
            )
            repository.save(split)
        }

        // Rewrite the original: drop the moved panes, prune emptied leaves
        // and tabs, repair both selection levels (the same normalization the
        // load-time healing performs), and stamp the primary directory.
        workspace.centerTabs = workspace.centerTabs.compactMap { tab in
            var repaired = tab
            for leaf in tab.root.allGroups {
                let movedHere = leaf.state.panes.filter { movedPaneIds.contains($0.id) }
                guard !movedHere.isEmpty else { continue }
                repaired.root = repaired.root.updatingGroup(id: leaf.id) { state in
                    var state = state
                    for pane in movedHere {
                        _ = state.removePane(id: pane.id)
                    }
                    return state
                }
            }
            guard let pruned = repaired.root.prunedEmptyGroups else { return nil }
            repaired.root = pruned
            if pruned.group(id: repaired.activeLeafId) == nil,
                let first = pruned.allGroups.first?.id
            {
                repaired.activeLeafId = first
            }
            return repaired
        }
        if workspace.centerTabs.isEmpty {
            var state = PaneGroupState()
            _ = state.addNewTabPane()
            let replacement = WorkspaceTab(root: .leaf(state))
            workspace.centerTabs = [replacement]
            workspace.selectedCenterTabId = replacement.id
        } else if !workspace.centerTabs.contains(where: { $0.id == workspace.selectedCenterTabId }) {
            workspace.selectedCenterTabId = workspace.centerTabs[0].id
        }
        workspace.worktreeName = primary.worktreeName
        if workspace.rootDirectory == nil {
            workspace.rootDirectory = firstCwd(of: primary)
        }
        repository.save(workspace)
    }
}
