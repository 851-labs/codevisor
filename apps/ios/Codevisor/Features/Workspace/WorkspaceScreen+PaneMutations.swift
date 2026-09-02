import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// New Tab conversion and pane persistence / publication against the
/// shared workspace registry.
extension WorkspaceScreen {
    /// The macOS new-tab conversion: the placeholder becomes a real pane in
    /// place. Chats are created eagerly as deferred sessions (the agent
    /// spawns on first send), exactly like the New Workspace flow. New chats
    /// inherit the workspace's one working directory: the root session's
    /// worktree (or project folder) stamps every sub-chat at creation.
    func convertToChat(_ pane: PaneDescriptorState) {
        // Reachable only from the tab grid, which a draft doesn't have.
        guard let project = resolvedProject, let workspaceSessionId = activeSessionId else { return }
        let chat = environment.projectList.newSession(
            in: project,
            title: "New Chat",
            worktreeName: rootSession?.worktreeName,
            cwd: rootSession?.cwd
        )
        var state = panes
        let converted = state.convertNewTabPane(
            id: pane.id, to: .chat, sessionId: workspaceSessionId, chatSessionId: chat.id
        )
        paneBinding.wrappedValue = state
        if let converted {
            promotePaneToChat(converted, session: chat)
        }
    }

    func convertToTerminal(_ pane: PaneDescriptorState) {
        guard let workspaceSessionId = activeSessionId else { return }
        var state = panes
        let converted = state.convertNewTabPane(
            id: pane.id, to: .terminal, sessionId: workspaceSessionId
        )
        paneBinding.wrappedValue = state
        if let converted {
            publishPane(converted)
        }
    }

    /// The New Tab placeholder becomes a plugin pane in place, mirroring
    /// macOS's New Tab plugin cards.
    func convertToPlugin(_ pane: PaneDescriptorState, option: PluginNewTabOption) {
        guard let workspaceSessionId = activeSessionId else { return }
        var state = panes
        let converted = state.convertNewTabPane(
            id: pane.id,
            to: .plugin,
            sessionId: workspaceSessionId,
            name: option.title,
            pluginId: option.pluginId,
            pluginPaneType: option.paneType
        )
        paneBinding.wrappedValue = state
        if let converted {
            publishPane(converted)
        }
    }

    /// iOS's flat tab order is the device-local layout projection of the
    /// shared pane registry. The Workspace repository is its persistence
    /// root; `paneState` is only the mounted view's writable cache.
    func persistCompactPaneState(_ state: PaneGroupState) {
        guard var workspace = resolvedWorkspace else { return }
        Self.applyCompactPaneState(state, to: &workspace)
        environment.workspaces.save(workspace)
        environment.workspaceSync.noteLocalMutation()
    }

    func publishPane(_ pane: PaneDescriptorState) {
        guard let workspaceId = resolvedWorkspace?.id else { return }
        environment.workspaceSync.publishPane(
            pane,
            workspaceId: workspaceId,
            client: environment.machines.client(for: resolvedServerId)
        )
    }

    private func promotePaneToChat(_ pane: PaneDescriptorState, session: ChatSession) {
        guard let workspaceId = resolvedWorkspace?.id else { return }
        environment.workspaceSync.promotePaneToChat(
            pane,
            session: session,
            workspaceId: workspaceId,
            client: environment.machines.client(for: resolvedServerId)
        )
    }

    /// Projects the shared pane registry into iOS's compact, single-group
    /// layout without importing macOS tab order or split placement.
    func synchronizePaneStateFromWorkspace() {
        guard let workspace = resolvedWorkspace else { return }
        let shared =
            workspace.centerTabs.flatMap { tab in
                tab.root.allGroups.flatMap(\.state.panes)
            } + workspace.bottomGroup.panes
        guard !shared.isEmpty else {
            guard !panes.panes.isEmpty else { return }
            let empty = PaneGroupState()
            paneState = empty
            persistCompactPaneState(empty)
            return
        }

        var state = panes
        var remaining = shared
        var reconciled: [PaneDescriptorState] = []
        for local in state.panes {
            let index = remaining.firstIndex(where: { candidate in
                candidate.id == local.id || Self.sameResource(candidate, local)
            })
            guard let index else { continue }
            reconciled.append(remaining.remove(at: index))
        }
        reconciled.append(contentsOf: remaining)
        guard reconciled != state.panes else { return }
        state.panes = reconciled
        if !reconciled.contains(where: { $0.id == state.selectedPaneId }) {
            state.selectedPaneId = reconciled.first?.id
        }
        state.isVisible = true
        paneState = state
        persistCompactPaneState(state)
    }

    private static func sameResource(
        _ lhs: PaneDescriptorState,
        _ rhs: PaneDescriptorState
    ) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        switch lhs.kind {
        case .chat:
            return lhs.chatSessionId != nil && lhs.chatSessionId == rhs.chatSessionId
        case .terminal:
            return lhs.terminalKey.caseInsensitiveCompare(rhs.terminalKey) == .orderedSame
        case .newTab, .plugin:
            return false
        }
    }
}
