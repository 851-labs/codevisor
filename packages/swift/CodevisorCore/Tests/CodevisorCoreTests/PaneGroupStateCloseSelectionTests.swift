import Foundation
import Testing

@testable import CodevisorCore

/// Closing the selected pane must land where navigation shows: an agent's
/// background terminal never becomes the selection just because it was the
/// closed pane's neighbor.
@Suite("PaneGroupState close selection")
struct PaneGroupStateCloseSelectionTests {
  private let sessionId = UUID()

  private func groupWithAgentTerminalBetween() -> (
    state: PaneGroupState, chat: UUID, agent: UUID, file: UUID
  ) {
    var state = PaneGroupState()
    let chat = state.addChatPane(sessionId: sessionId).id
    let agent = state.appendAgentTerminal(name: "dev server", terminalKey: "task-1")
    let file = state.addTerminalPane(sessionId: sessionId).id
    state.selectPane(id: file)
    return (state, chat, agent, file)
  }

  @Test("Closing the last pane selects the listed pane before it, skipping an agent terminal")
  func closingSkipsAgentTerminalBefore() {
    var (state, chat, agent, file) = groupWithAgentTerminalBetween()
    state.closePane(id: file)
    #expect(state.selectedPaneId == chat)
    #expect(state.panes.map(\.id) == [chat, agent])
  }

  @Test("With nothing listed before, the listed pane after takes over")
  func fallsForwardToListedPane() {
    var state = PaneGroupState()
    let first = state.addTerminalPane(sessionId: sessionId).id
    let agent = state.appendAgentTerminal(name: "tests", terminalKey: "task-2")
    let last = state.addTerminalPane(sessionId: sessionId).id
    state.selectPane(id: first)
    state.closePane(id: first)
    #expect(state.selectedPaneId == last)
    #expect(state.panes.map(\.id) == [agent, last])
  }

  @Test("Only agent terminals left: the neighbor rule still yields a selection")
  func fallsBackToNeighborWhenNothingIsListed() {
    var state = PaneGroupState()
    let agent = state.appendAgentTerminal(name: "build", terminalKey: "task-3")
    let file = state.addTerminalPane(sessionId: sessionId).id
    state.selectPane(id: file)
    state.closePane(id: file)
    #expect(state.selectedPaneId == agent)
  }

  @Test("Closing an unselected pane leaves the selection alone")
  func closingUnselectedPaneKeepsSelection() {
    var (state, chat, _, file) = groupWithAgentTerminalBetween()
    state.selectPane(id: chat)
    state.closePane(id: file)
    #expect(state.selectedPaneId == chat)
  }

  @Test("Closing the only pane clears the selection")
  func closingLastPaneClearsSelection() {
    var state = PaneGroupState()
    let only = state.addTerminalPane(sessionId: sessionId).id
    state.closePane(id: only)
    #expect(state.selectedPaneId == nil)
    #expect(state.panes.isEmpty)
  }
}

extension PaneDescriptorState {
  /// An agent-owned background terminal, shaped like the tabs
  /// `Workspace.syncAgentTerminals` creates.
  static func agentTerminal(name: String, terminalKey: String, owner: UUID? = nil) -> Self {
    PaneDescriptorState(
      id: UUID(), kind: .terminal, name: name, terminalKey: terminalKey,
      attachOnly: true, ownerChatSessionId: owner
    )
  }
}

extension PaneGroupState {
  /// Appends an agent terminal tab and selects it only when the group had
  /// no selection, returning its id.
  @discardableResult
  mutating func appendAgentTerminal(name: String, terminalKey: String) -> UUID {
    let pane = PaneDescriptorState.agentTerminal(name: name, terminalKey: terminalKey)
    panes.append(pane)
    if selectedPaneId == nil { selectedPaneId = pane.id }
    return pane.id
  }
}
