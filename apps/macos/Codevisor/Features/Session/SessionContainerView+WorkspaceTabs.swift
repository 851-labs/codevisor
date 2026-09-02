import SwiftUI
import CodevisorCore
import CodevisorUI

// MARK: - WorkspaceTabs

extension SessionContainerView {
    /// Workspace sync writes reconciled descriptors into the repository.
    /// Mounted pane models retain live views and focus, so explicitly adopt
    /// that content identity instead of leaving their creation-time snapshot
    /// in front of repository truth.
    func synchronizeMountedPaneGroups() {
        let workspace = store.workspace(for: session, project: project)
        let modelsChanged = store.reconcileMountedPaneGroups(in: workspace)
        let storedTree = workspace.centerTree
        let storedLeafIds = Set(storedTree.allGroups.map(\.id))
        let liveLeafIds = liveCenterTree.map { Set($0.allGroups.map(\.id)) }
        let topologyChanged = liveLeafIds.map { $0 != storedLeafIds } ?? false
        if topologyChanged {
            liveCenterTree = storedTree
        }

        let activeLeafChanged = activeLeafId.map { !storedLeafIds.contains($0) } ?? false
        if activeLeafChanged {
            activeLeafId = workspace.selectedCenterTab?.activeLeafId
        }
        if modelsChanged || topologyChanged || activeLeafChanged {
            workspaceRevision += 1
        }
    }

    func activeCenterModel(in workspace: Workspace) -> PaneGroupModel {
        let leafId =
            activeLeafId
            ?? workspace.selectedCenterTab?.activeLeafId
            ?? workspace.centerTree.allGroups.first!.id
        return configuredCenterModel(leafId: leafId)
    }

    func workspaceTabDescriptor(_ tab: WorkspaceTab) -> PaneDescriptorState? {
        configuredCenterModel(leafId: tab.activeLeafId).state.selectedPane
            ?? tab.root.group(id: tab.activeLeafId)?.selectedPane
            ?? tab.root.allGroups.first?.state.selectedPane
    }

    func workspaceTabTitle(_ tab: WorkspaceTab) -> String {
        if let customTitle = tab.customTitle {
            return customTitle
        }
        guard let descriptor = workspaceTabDescriptor(tab) else { return "New Tab" }
        return paneTitle(descriptor)
    }

    func selectCenterTab(_ tabId: UUID) {
        var workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.centerTabs.first(where: { $0.id == tabId }) else { return }
        if let old = workspace.selectedCenterTab, old.id != tabId {
            for leaf in old.root.allGroups {
                configuredCenterModel(leafId: leaf.id).selectedPane?.visibilityChanged(false)
            }
        }
        workspace.selectedCenterTabId = tabId
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = tab.root
        activateLeaf(tab.activeLeafId)
        let model = configuredCenterModel(leafId: tab.activeLeafId)
        model.selectedPane?.visibilityChanged(true)
        DispatchQueue.main.async { model.focusSelectedPane() }
    }

    func addCenterTab() {
        var workspace = store.workspace(for: session, project: project)
        if let current = workspace.selectedCenterTab {
            rememberWorkspaceDefaults(
                fromLeaf: activeLeafId ?? current.activeLeafId,
                in: workspace
            )
        }
        if let current = workspace.selectedCenterTab {
            for leaf in current.root.allGroups {
                configuredCenterModel(leafId: leaf.id).selectedPane?.visibilityChanged(false)
            }
        }
        var state = PaneGroupState()
        let pane = state.addNewTabPane()
        let tab = WorkspaceTab(root: .leaf(state))
        workspace.centerTabs.append(tab)
        workspace.selectedCenterTabId = tab.id
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = tab.root
        activateLeaf(tab.activeLeafId)
        publishPane(pane, workspaceId: workspace.id)
    }

    func moveCenterTab(_ sourceId: UUID, _ targetId: UUID) {
        var workspace = store.workspace(for: session, project: project)
        guard sourceId != targetId,
            let source = workspace.centerTabs.firstIndex(where: { $0.id == sourceId }),
            let target = workspace.centerTabs.firstIndex(where: { $0.id == targetId })
        else { return }
        let tab = workspace.centerTabs.remove(at: source)
        workspace.centerTabs.insert(tab, at: target)
        environment.workspaces.save(workspace)
        workspaceRevision += 1
    }

    func renameCenterTab(_ tabId: UUID, to customTitle: String?) {
        var workspace = store.workspace(for: session, project: project)
        guard let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        guard workspace.centerTabs[index].customTitle != normalized else { return }
        workspace.centerTabs[index].customTitle = normalized
        environment.workspaces.save(workspace)
        workspaceRevision += 1
    }

    func closeCenterTab(_ tabId: UUID) {
        var workspace = store.workspace(for: session, project: project)
        guard let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closing = workspace.centerTabs[index]
        let closesRoutedChat = closing.root.allGroups.contains { group in
            group.state.panes.contains { $0.chatSessionId == session.id }
        }
        closingCenterTabId = tabId
        for leaf in closing.root.allGroups {
            let model = configuredCenterModel(leafId: leaf.id)
            for paneId in model.state.panes.map(\.id) {
                model.closePane(id: paneId)
            }
        }
        closingCenterTabId = nil

        // Re-read after the models persisted their mutations. When closing
        // this tab would close the workspace's final pane, that pane has been
        // converted in place and the tab remains. Otherwise empty leaves and
        // the now-empty layout tab are purely local cleanup.
        workspace = store.workspace(for: session, project: project)
        guard let refreshedIndex = workspace.centerTabs.firstIndex(where: { $0.id == tabId }) else {
            return
        }
        if let pruned = workspace.centerTabs[refreshedIndex].root.prunedEmptyGroups {
            workspace.centerTabs[refreshedIndex].root = pruned
            if pruned.group(id: workspace.centerTabs[refreshedIndex].activeLeafId) == nil,
                let first = pruned.allGroups.first?.id
            {
                workspace.centerTabs[refreshedIndex].activeLeafId = first
            }
            workspace.selectedCenterTabId = tabId
        } else {
            workspace.centerTabs.remove(at: refreshedIndex)
        }
        for leaf in closing.root.allGroups
        where workspace.centerTabs.allSatisfy({ $0.root.group(id: leaf.id) == nil }) {
            store.evictCenterLeaf(workspaceId: workspace.id, leafId: leaf.id)
        }
        if workspace.centerTabs.isEmpty {
            let replacement = WorkspaceTab(root: .leaf(PaneGroupState()))
            workspace.centerTabs = [replacement]
            workspace.selectedCenterTabId = replacement.id
        } else if workspace.selectedCenterTabId == tabId {
            workspace.selectedCenterTabId =
                workspace.centerTabs[
                    min(refreshedIndex, workspace.centerTabs.count - 1)
                ].id
        }
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = workspace.centerTree
        activateLeaf(workspace.selectedCenterTab?.activeLeafId)
        if closesRoutedChat, let survivor = firstSurvivingChatId() {
            onFocusedChatChanged?(survivor)
        }
    }
}
