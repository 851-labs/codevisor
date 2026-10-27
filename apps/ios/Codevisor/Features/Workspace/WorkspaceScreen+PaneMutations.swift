import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

extension WorkspaceScreen {
  func convertToChat(_ pane: PaneDescriptorState) {
    guard let project = resolvedProject, let workspaceSessionId = paneStorageId else { return }
    let chat = environment.projectList.newSession(
      in: project,
      title: "New Chat",
      worktreeName: rootSession?.worktreeName,
      cwd: workspaceCwd
    )
    convertedChatFocusRequest = (chatSessionId: chat.id, request: UUID())
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

  func convertToPlugin(_ pane: PaneDescriptorState, option: PluginPaneOffer) {
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

  func synchronizePaneStateFromWorkspace() {
    guard let workspace = resolvedWorkspace else { return }
    let shared = Self.compactPaneState(from: workspace)
    guard !shared.panes.isEmpty else {
      guard !panes.panes.isEmpty else { return }
      let empty = PaneGroupState()
      paneState = empty
      persistCompactPaneState(empty)
      return
    }

    var state = panes
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
    case .subagent:
      return lhs.ownerChatSessionId == rhs.ownerChatSessionId
        && lhs.subagentToolCallId != nil && lhs.subagentToolCallId == rhs.subagentToolCallId
    case .transcript:
      return lhs.ownerChatSessionId != nil && lhs.ownerChatSessionId == rhs.ownerChatSessionId
    case .newTab, .plugin, .document, .browser, .screenSharing, .review, .simulator:
      return false
    }
  }
}
