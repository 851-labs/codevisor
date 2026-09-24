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
    guard let project = resolvedProject, let workspaceSessionId = paneStorageId else { return }
    let chat = environment.projectList.newSession(
      in: project,
      title: "New Chat",
      worktreeName: rootSession?.worktreeName,
      cwd: workspaceCwd
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

  func convertToBrowser(_ pane: PaneDescriptorState) {
    guard let workspaceSessionId = paneStorageId else { return }
    var state = panes
    let converted = state.convertNewTabPane(id: pane.id, to: .browser, sessionId: workspaceSessionId)
    paneBinding.wrappedValue = state
    if let converted { publishPane(converted) }
  }

  func convertToTerminal(_ pane: PaneDescriptorState) {
    guard let workspaceSessionId = paneStorageId else { return }
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
    guard let workspaceSessionId = paneStorageId else { return }
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
  /// root; `paneState` is only the mounted view's writable cache. A state
  /// the workspace already holds is not saved again: the save would change
  /// nothing but still re-render every view of this workspace.
  func persistCompactPaneState(_ state: PaneGroupState) {
    guard let current = resolvedWorkspace else { return }
    var workspace = current
    Self.applyCompactPaneState(state, to: &workspace)
    guard workspace != current else { return }
    environment.workspaces.save(workspace)
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
    // One flatten: every pane across the tabs, and the active selection.
    let shared = Self.compactPaneState(from: workspace)
    guard !shared.panes.isEmpty else {
      guard !panes.panes.isEmpty else { return }
      let empty = PaneGroupState()
      paneState = empty
      persistCompactPaneState(empty)
      return
    }

    var state = panes
    // The repository owns this device's order and selection. Client-control
    // writes must reach an already mounted screen just like sidebar changes.
    // A pane arriving under a new id for a resource already mounted keeps
    // that mount's identity; panes whose id is unchanged need no lookup.
    let localIds = Set(state.panes.map(\.id))
    for candidate in shared.panes where !localIds.contains(candidate.id) {
      guard let local = state.panes.first(where: { Self.sameResource(candidate, $0) }) else { continue }
      let identity = paneViewIdentities[local.id] ?? local.id
      if paneViewIdentities[candidate.id] != identity { paneViewIdentities[candidate.id] = identity }
    }
    guard shared.panes != state.panes || shared.selectedPaneId != state.selectedPaneId else { return }
    state.panes = shared.panes
    state.selectedPaneId = shared.selectedPaneId
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
    case .newTab, .plugin, .document, .browser, .screenSharing:
      return false
    }
  }
}
