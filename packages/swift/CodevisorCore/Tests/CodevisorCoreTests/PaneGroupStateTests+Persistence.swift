import Foundation
import Testing
@testable import CodevisorCore

extension PaneGroupStateTests {
  @Test("A reordered pane array and its selection survive persistence")
  func reorderedPanePersistence() throws {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let first = state.panes[0]
    let second = state.addTerminalPane(sessionId: sessionId)
    let third = state.addNewTabPane()
    state.selectPane(id: second.id)

    state.movePane(id: first.id, onto: third.id)
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self,
      from: JSONEncoder().encode(state)
    )

    #expect(decoded.panes.map(\.id) == [second.id, third.id, first.id])
    #expect(decoded.selectedPaneId == second.id)
  }

  @Test("Agent terminal panes are keyed, deduped, and never steal selection")
  func agentTerminalPanes() {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let selectedBefore = state.selectedPaneId
    let key = "\(sessionId.uuidString):bg:tool-1"

    let pane = state.ensureAgentTerminalPane(name: "npm run dev", terminalKey: key)
    #expect(pane.attachOnly)
    #expect(pane.name == "npm run dev")
    #expect(state.panes.count == 2)
    #expect(state.selectedPaneId == selectedBefore)

    // Re-ensuring the same terminal key returns the existing pane.
    let again = state.ensureAgentTerminalPane(name: "renamed", terminalKey: key)
    #expect(again.id == pane.id)
    #expect(state.panes.count == 2)

    // With nothing selected (empty group), the agent pane becomes the
    // selection so the bar has a coherent state.
    var empty = PaneGroupState()
    let first = empty.ensureAgentTerminalPane(name: "dev", terminalKey: key)
    #expect(empty.selectedPaneId == first.id)
  }

  @Test("Descriptors persisted before attachOnly existed decode as user shells")
  func decodeLegacyDescriptor() throws {
    let legacy = Data(
      """
      {"id":"\(UUID().uuidString)","kind":"terminal","name":"Terminal 1","terminalKey":"abc"}
      """.utf8)
    let decoded = try JSONDecoder().decode(PaneDescriptorState.self, from: legacy)
    #expect(decoded.attachOnly == false)
    // Pre-owner-scoping agent tabs decode ownerless (any syncer adopts).
    #expect(decoded.ownerChatSessionId == nil)
  }

  @Test("New tab conversion to terminal survives persistence")
  func newTabConversionPersists() throws {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let placeholder = state.addNewTabPane()
    let converted = state.convertNewTabPane(
      id: placeholder.id,
      to: .terminal,
      sessionId: sessionId
    )
    #expect(converted?.kind == .terminal)
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self, from: JSONEncoder().encode(state)
    )
    #expect(decoded.panes.first { $0.id == converted?.id }?.kind == .terminal)
    // Panes persisted with the retired per-pane cwd override still decode.
    let legacy = Data(
      """
      {"id":"\(UUID().uuidString)","kind":"terminal","name":"T","terminalKey":"k","cwdOverride":"/tmp/x"}
      """.utf8)
    #expect(try JSONDecoder().decode(PaneDescriptorState.self, from: legacy).kind == .terminal)
  }

  @Test("Agent terminal panes carry their owning chat and round-trip it")
  func agentTerminalOwner() throws {
    var state = PaneGroupState.initial(sessionId: sessionId)
    let owner = UUID()
    let pane = state.ensureAgentTerminalPane(
      name: "bun run dev",
      terminalKey: "\(sessionId.uuidString):bg:tool-2",
      ownerChatSessionId: owner
    )
    #expect(pane.ownerChatSessionId == owner)
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self, from: JSONEncoder().encode(state)
    )
    #expect(decoded.panes.first { $0.id == pane.id }?.ownerChatSessionId == owner)
  }

  @Test("Codable round-trip preserves panes and selection")
  func codableRoundTrip() throws {
    var state = PaneGroupState.initial(sessionId: sessionId)
    state.addTerminalPane(sessionId: sessionId)
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self,
      from: JSONEncoder().encode(state)
    )
    #expect(decoded == state)
  }

  @Test("Decoding drops a selection that no longer matches a pane")
  func decodeRepairsSelection() throws {
    var state = PaneGroupState.initial(sessionId: sessionId)
    state.selectedPaneId = nil
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self,
      from: JSONEncoder().encode(state)
    )
    #expect(decoded.selectedPaneId == state.panes[0].id)
  }

  @Test("Repository round-trips state per session")
  func repository() {
    let repo = DefaultPaneGroupRepository(store: InMemoryStore())
    let otherSession = UUID()
    #expect(repo.load(sessionId: sessionId) == nil)
    var state = PaneGroupState.initial(sessionId: sessionId)
    state.addTerminalPane(sessionId: sessionId)
    repo.save(state, sessionId: sessionId)
    repo.save(.initial(sessionId: otherSession), sessionId: otherSession)
    #expect(repo.load(sessionId: sessionId) == state)
    #expect(repo.load(sessionId: otherSession)?.panes.count == 1)
  }

  @Test("Legacy session panes remain available for migration after active group saves")
  func repositoryLegacyPanes() throws {
    let store = InMemoryStore()
    let legacy = PaneGroupState.initial(sessionId: sessionId)
    try store.saveData(JSONEncoder().encode([sessionId.uuidString: legacy]), forKey: "paneGroups")
    let repo = DefaultPaneGroupRepository(store: store)
    let center = PaneGroupState.centerInitial(sessionId: sessionId)
    #expect(repo.load(sessionId: sessionId) == nil)
    #expect(repo.legacyPanes(sessionId: sessionId) == legacy.panes)
    repo.save(center, sessionId: sessionId)
    #expect(repo.legacyPanes(sessionId: sessionId) == legacy.panes)
    #expect(repo.load(sessionId: sessionId) == center)
  }
}
