import SwiftUI
import CodevisorCore
import CodevisorUI

// MARK: - SplitCommands

extension SessionContainerView {
    func saveSelectedTree(_ tree: SplitNode, workspaceId: UUID) {
        guard var workspace = environment.workspaces.workspace(id: workspaceId),
            let index = workspace.selectedCenterTabIndex
        else { return }
        // Divider callbacks carry render-time topology/fractions. Merge the
        // repository's live leaf states so a recent New Tab conversion or
        // title/session binding can never be overwritten by a resize.
        var merged = tree
        for group in workspace.centerTabs[index].root.allGroups {
            merged = merged.updatingGroup(id: group.id) { _ in group.state }
        }
        workspace.centerTabs[index].root = merged
        if merged.group(id: workspace.centerTabs[index].activeLeafId) == nil,
            let first = merged.allGroups.first?.id
        {
            workspace.centerTabs[index].activeLeafId = first
        }
        environment.workspaces.save(workspace)
        workspaceRevision += 1
    }

    func handleWorkspaceCommand(_ command: PaneGroupCommand) -> Bool {
        switch command {
        case .newTab:
            addCenterTab()
        case .previousTab:
            selectRelativeCenterTab(offset: -1)
        case .nextTab:
            selectRelativeCenterTab(offset: 1)
        case let .selectTab(index):
            let workspace = store.workspace(for: session, project: project)
            guard workspace.centerTabs.indices.contains(index) else { return true }
            selectCenterTab(workspace.centerTabs[index].id)
        case let .split(edge):
            splitActiveLeaf(edge: edge)
        case let .focusSplit(edge):
            focusAdjacentLeaf(edge: edge)
        case .previousSplit:
            focusRelativeSplit(offset: -1)
        case .nextSplit:
            focusRelativeSplit(offset: 1)
        case .closeTab:
            closeActiveLeaf()
        case .togglePanel:
            return false
        }
        return true
    }

    func selectRelativeCenterTab(offset: Int) {
        let workspace = store.workspace(for: session, project: project)
        guard workspace.centerTabs.count > 1,
            let index = workspace.selectedCenterTabIndex
        else { return }
        let target = (index + offset + workspace.centerTabs.count) % workspace.centerTabs.count
        selectCenterTab(workspace.centerTabs[target].id)
    }

    func splitActiveLeaf(edge: SplitEdge) {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        splitLeaf(activeLeafId ?? tab.activeLeafId, edge: edge)
    }

    /// Splits the explicitly targeted leaf. Header buttons call this with
    /// their owning leaf; keyboard/menu commands pass the active leaf.
    func splitLeaf(_ leafId: UUID, edge: SplitEdge) {
        var workspace = store.workspace(for: session, project: project)
        rememberWorkspaceDefaults(fromLeaf: leafId, in: workspace)
        guard
            let tabIndex = workspace.centerTabs.firstIndex(where: {
                $0.root.group(id: leafId) != nil
            })
        else { return }
        var state = PaneGroupState()
        let pane = state.addNewTabPane()
        let newLeafId = UUID()
        workspace.centerTabs[tabIndex].root = workspace.centerTabs[tabIndex].root.splitting(
            groupId: leafId,
            edge: edge,
            newGroupId: newLeafId,
            newGroupState: state
        )
        workspace.centerTabs[tabIndex].activeLeafId = newLeafId
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = workspace.centerTabs[tabIndex].root
        activateLeaf(newLeafId)
        publishPane(pane, workspaceId: workspace.id)
    }

    /// Atomically relocates one whole leaf inside the selected top tab. The
    /// group id survives, so its cached model and any live terminal surface
    /// move with the layout instead of being torn down and recreated.
    func moveSplitLeaf(_ sourceLeafId: UUID, relativeTo targetLeafId: UUID, edge: SplitEdge) {
        var workspace = store.workspace(for: session, project: project)
        guard let tabIndex = workspace.selectedCenterTabIndex else { return }
        let current = workspace.centerTabs[tabIndex].root
        guard current.group(id: sourceLeafId) != nil,
            current.group(id: targetLeafId) != nil
        else { return }

        let moved = current.movingGroup(
            id: sourceLeafId,
            relativeTo: targetLeafId,
            edge: edge
        )
        guard moved != current else { return }

        workspace.centerTabs[tabIndex].root = moved
        workspace.centerTabs[tabIndex].activeLeafId = sourceLeafId
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = moved
        activateLeaf(sourceLeafId)

        DispatchQueue.main.async {
            configuredCenterModel(leafId: sourceLeafId).focusSelectedPane()
        }
    }

    /// Validates the POST-move topology. A same-row reorder can be valid even
    /// when the hovered leaf itself is too narrow to halve before the source
    /// is removed; evaluating the candidate avoids hiding those targets.
    func canMoveSplitLeaf(
        _ sourceLeafId: UUID,
        relativeTo targetLeafId: UUID,
        edge: SplitEdge,
        canvasSize: CGSize
    ) -> Bool {
        let workspace = store.workspace(for: session, project: project)
        guard let current = workspace.selectedCenterTab?.root,
            canvasSize.width > 0,
            canvasSize.height > 0
        else { return false }
        let candidate = current.movingGroup(
            id: sourceLeafId,
            relativeTo: targetLeafId,
            edge: edge
        )
        guard candidate != current else { return false }

        let currentFrames = normalizedLeafFrames(current).values
        let candidateFrames = normalizedLeafFrames(candidate).values
        guard let currentMinWidth = currentFrames.map({ $0.width * canvasSize.width }).min(),
            let currentMinHeight = currentFrames.map({ $0.height * canvasSize.height }).min()
        else { return false }

        // A window may already be smaller than the nominal pane floor. In
        // that case permit moves that do not make its smallest pane worse.
        let requiredWidth = min(WorkspaceSplitDragCoordinator.minChildWidth, currentMinWidth)
        let requiredHeight = min(WorkspaceSplitDragCoordinator.minChildHeight, currentMinHeight)
        return candidateFrames.allSatisfy { frame in
            frame.width * canvasSize.width >= requiredWidth - 1
                && frame.height * canvasSize.height >= requiredHeight - 1
        }
    }

    func closeActiveLeaf() {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        closeLeaf(activeLeafId ?? tab.activeLeafId)
    }

    func closeLeaf(_ leafId: UUID) {
        let model = configuredCenterModel(leafId: leafId)
        guard let paneId = model.state.selectedPaneId else { return }
        model.closePane(id: paneId)
    }

    func renameLeaf(_ leafId: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let model = configuredCenterModel(leafId: leafId)
        guard let descriptor = model.state.selectedPane else { return }
        model.renamePane(id: descriptor.id, to: trimmed)
        if descriptor.kind == .chat,
            let chatId = descriptor.chatSessionId,
            let chat = environment.projectList.sessions.first(where: {
                $0.serverId == session.serverId && $0.id == chatId
            })
        {
            environment.projectList.renameSession(chat, to: trimmed)
        }
    }

    func focusAdjacentLeaf(edge: SplitEdge) {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        let current = activeLeafId ?? tab.activeLeafId
        let frames = normalizedLeafFrames(tab.root)
        guard let source = frames[current] else { return }
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let candidates = frames.filter { id, frame in
            guard id != current else { return false }
            switch edge {
            case .leading: return frame.midX < sourceCenter.x
            case .trailing: return frame.midX > sourceCenter.x
            case .top: return frame.midY < sourceCenter.y
            case .bottom: return frame.midY > sourceCenter.y
            }
        }
        let target = candidates.min { lhs, rhs in
            let ld = hypot(lhs.value.midX - sourceCenter.x, lhs.value.midY - sourceCenter.y)
            let rd = hypot(rhs.value.midX - sourceCenter.x, rhs.value.midY - sourceCenter.y)
            return ld < rd
        }?.key
        guard let target else { return }
        activateLeaf(target)
        DispatchQueue.main.async { configuredCenterModel(leafId: target).focusSelectedPane() }
    }

    /// Cycles through split leaves in stable visual reading order. This is
    /// deliberately independent of split orientation so ⌘[ / ⌘] remains
    /// predictable in nested horizontal and vertical layouts.
    func focusRelativeSplit(offset: Int) {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        let leaves = tab.root.allGroups.map(\.id)
        guard leaves.count > 1 else { return }
        let current = activeLeafId ?? tab.activeLeafId
        let index = leaves.firstIndex(of: current) ?? 0
        let target = leaves[(index + offset + leaves.count) % leaves.count]
        activateLeaf(target)
        DispatchQueue.main.async { configuredCenterModel(leafId: target).focusSelectedPane() }
    }

    func normalizedLeafFrames(_ root: SplitNode) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        func walk(_ node: SplitNode, in frame: CGRect) {
            switch node {
            case let .group(id, _):
                result[id] = frame
            case let .split(orientation, children):
                var cursor: CGFloat = 0
                for child in children {
                    let fraction = CGFloat(child.fraction)
                    let childFrame: CGRect
                    if orientation == .horizontal {
                        childFrame = CGRect(
                            x: frame.minX + frame.width * cursor, y: frame.minY,
                            width: frame.width * fraction, height: frame.height
                        )
                    } else {
                        childFrame = CGRect(
                            x: frame.minX, y: frame.minY + frame.height * cursor,
                            width: frame.width, height: frame.height * fraction
                        )
                    }
                    walk(child.node, in: childFrame)
                    cursor += fraction
                }
            }
        }
        walk(root, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return result
    }
}
