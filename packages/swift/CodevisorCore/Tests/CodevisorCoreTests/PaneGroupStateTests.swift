import Foundation
import Testing
@testable import CodevisorCore

@Suite("PaneGroupState")
struct PaneGroupStateTests {
  let sessionId = UUID()

  @Test("Defaults have no panes or selection")
  func defaults() {
    let state = PaneGroupState()
    #expect(state.panes.isEmpty)
    #expect(state.selectedPaneId == nil)
  }

  @Test("Initial state has one selected terminal pane keyed on the bare session UUID")
  func initialState() {
    let state = PaneGroupState.initial(sessionId: sessionId)
    #expect(state.panes.count == 1)
    #expect(state.panes[0].name == "Terminal 1")
    #expect(state.panes[0].kind == .terminal)
    // Migration: pane 1 must reattach to shells created before panes existed.
    #expect(state.panes[0].terminalKey == sessionId.uuidString)
    #expect(state.selectedPaneId == state.panes[0].id)
  }

  @Test("The first requested terminal materializes from an empty group")
  func lazyFirstTerminal() {
    var state = PaneGroupState()

    #expect(state.panes.isEmpty)

    let added = state.addTerminalPane(sessionId: sessionId)

    #expect(added.name == "Terminal 1")
    #expect(added.kind == .terminal)
    #expect(added.terminalKey == "\(sessionId.uuidString):\(added.id.uuidString)")
    #expect(state.panes == [added])
    #expect(state.selectedPaneId == added.id)
  }

  @Test("Adding a pane names it Terminal N, selects it and uses a synthetic key")
  func addPane() {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let added = state.addTerminalPane(sessionId: sessionId)
    #expect(added.name == "Terminal 2")
    #expect(state.panes.count == 2)
    #expect(state.selectedPaneId == added.id)
    #expect(added.terminalKey == "\(sessionId.uuidString):\(added.id.uuidString)")
  }

  @Test("A New Tab placeholder converts to a terminal in place")
  func newTabPaneConvertsToTerminal() {
    var state = PaneGroupState.centerInitial(sessionId: sessionId)
    let placeholder = state.addNewTabPane()
    #expect(placeholder.kind == .newTab)
    let converted = state.convertNewTabPane(
      id: placeholder.id, to: .terminal, sessionId: sessionId
    )
    #expect(converted?.kind == .terminal)
    #expect(converted?.id == placeholder.id)
  }

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

  @Test("Naming is max numeric suffix + 1, including after close and re-add")
  func naming() {
    #expect(PaneGroupState.nextTerminalName(existing: []) == "Terminal 1")
    #expect(PaneGroupState.nextTerminalName(existing: ["Terminal 1"]) == "Terminal 2")
    #expect(PaneGroupState.nextTerminalName(existing: ["Terminal 1", "Terminal 3"]) == "Terminal 4")
    #expect(PaneGroupState.nextTerminalName(existing: ["Renamed", "Terminal 2"]) == "Terminal 3")

    var state = PaneGroupState.initial(sessionId: sessionId)
    let second = state.addTerminalPane(sessionId: sessionId)
    state.closePane(id: second.id)
    // After closing "Terminal 2" of [1, 2], the next add is "Terminal 2" again.
    #expect(state.addTerminalPane(sessionId: sessionId).name == "Terminal 2")
  }

  @Test("Closing the selected pane selects its right neighbor, else the new last pane")
  func closeSelectsNeighbor() {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let second = state.addTerminalPane(sessionId: sessionId)
    let third = state.addTerminalPane(sessionId: sessionId)
    state.selectPane(id: second.id)
    state.closePane(id: second.id)
    #expect(state.selectedPaneId == third.id)
    // Closing the last pane in the list falls back to the left neighbor.
    state.closePane(id: third.id)
    #expect(state.selectedPaneId == state.panes[0].id)
  }

  @Test("Closing a non-selected pane keeps the selection")
  func closeKeepsSelection() {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let first = state.panes[0]
    let second = state.addTerminalPane(sessionId: sessionId)
    state.closePane(id: first.id)
    #expect(state.selectedPaneId == second.id)
  }

  @Test("Closing the last remaining pane clears selection")
  func closeLastClearsSelection() {
    var state = PaneGroupState.initial(sessionId: sessionId)
    state.selectPane(id: state.panes[0].id)
    state.closePane(id: state.panes[0].id)
    #expect(state.panes.isEmpty)
    #expect(state.selectedPaneId == nil)
  }

  @Test("Selecting a pane ignores unknown identities")
  func selectPane() {
    var state = PaneGroupState.initial(sessionId: sessionId)
    state.selectPane(id: state.panes[0].id)
    // Unknown ids are ignored.
    state.selectPane(id: UUID())
    #expect(state.selectedPaneId == state.panes[0].id)
  }

  @Test("Moving a pane reorders it around the target in both directions")
  func movePane() {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let first = state.panes[0]
    let second = state.addTerminalPane(sessionId: sessionId)
    let third = state.addTerminalPane(sessionId: sessionId)

    state.movePane(id: first.id, onto: third.id)
    #expect(state.panes.map(\.id) == [second.id, third.id, first.id])

    state.movePane(id: first.id, onto: second.id)
    #expect(state.panes.map(\.id) == [first.id, second.id, third.id])

    // No-ops: same pane, unknown ids.
    state.movePane(id: first.id, onto: first.id)
    state.movePane(id: UUID(), onto: second.id)
    #expect(state.panes.map(\.id) == [first.id, second.id, third.id])
  }
}
