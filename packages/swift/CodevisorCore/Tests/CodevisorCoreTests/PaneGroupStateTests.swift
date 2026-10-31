import Foundation
import Testing
@testable import CodevisorCore

@Suite("PaneGroupState")
struct PaneGroupStateTests {
  let sessionId = UUID()

  @Test("Shared reconciliation promotes a placeholder without replacing local presentation")
  func sharedReconciliationPromotesPlaceholder() {
    let paneId = UUID()
    let createdSessionId = UUID()
    let placeholder = PaneDescriptorState(
      id: paneId,
      kind: .newTab,
      name: "New Tab",
      terminalKey: paneId.uuidString
    )
    var local = PaneGroupState(
      panes: [placeholder],
      selectedPaneId: paneId
    )
    let promoted = PaneDescriptorState(
      id: paneId,
      kind: .chat,
      name: "New Chat",
      terminalKey: paneId.uuidString,
      chatSessionId: createdSessionId
    )
    let incoming = PaneGroupState(
      panes: [promoted],
      selectedPaneId: nil
    )

    let didPromote = local.reconcilePaneDescriptors(from: incoming)
    #expect(didPromote)
    #expect(local.panes == [promoted])
    #expect(local.panes[0].id == paneId)
    #expect(local.panes[0].chatSessionId == createdSessionId)
    #expect(local.selectedPaneId == paneId)
    let didRepeat = local.reconcilePaneDescriptors(from: incoming)
    #expect(!didRepeat)
  }

  @Test("Shared reconciliation repairs selection when its pane disappears")
  func sharedReconciliationRepairsSelection() {
    let removed = PaneDescriptorState(
      id: UUID(), kind: .newTab, name: "New Tab", terminalKey: "removed"
    )
    let survivor = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "survivor"
    )
    var local = PaneGroupState(
      panes: [removed, survivor],
      selectedPaneId: removed.id
    )
    let incoming = PaneGroupState(
      panes: [survivor],
      selectedPaneId: survivor.id
    )

    let didRemove = local.reconcilePaneDescriptors(from: incoming)
    #expect(didRemove)
    #expect(local.panes == [survivor])
    #expect(local.selectedPaneId == survivor.id)

    local.selectedPaneId = nil
    let didRepairSelection = local.reconcilePaneDescriptors(from: incoming)
    #expect(didRepairSelection)
    #expect(local.selectedPaneId == survivor.id)
  }

  @Test("Closing the selected pane selects the pane before it, else the one after")
  func closeSelectsNeighbor() {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    let first = state.panes[0]
    let second = state.addTerminalPane(sessionId: sessionId)
    let third = state.addTerminalPane(sessionId: sessionId)
    state.selectPane(id: second.id)
    state.closePane(id: second.id)
    #expect(state.selectedPaneId == first.id)
    state.closePane(id: first.id)
    #expect(state.selectedPaneId == third.id)
  }

  @Test("Closing a non-selected pane keeps the selection")
  func closeKeepsSelection() {
    var state = PaneGroupState()
    let first = state.addTerminalPane(sessionId: sessionId)
    state.addTerminalPane(sessionId: sessionId)
    let third = state.addTerminalPane(sessionId: sessionId)
    state.closePane(id: first.id)
    #expect(state.selectedPaneId == third.id)
  }

  @Test("Closing the last remaining pane clears selection")
  func closeLastClearsSelection() {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    state.selectPane(id: state.panes[0].id)
    state.closePane(id: state.panes[0].id)
    #expect(state.panes.isEmpty)
    #expect(state.selectedPaneId == nil)
  }

  @Test("Selecting a pane ignores unknown identities")
  func selectPane() {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    state.selectPane(id: state.panes[0].id)
    state.selectPane(id: UUID())
    #expect(state.selectedPaneId == state.panes[0].id)
  }
}
