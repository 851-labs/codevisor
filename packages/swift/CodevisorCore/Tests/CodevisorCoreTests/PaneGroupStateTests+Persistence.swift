import Foundation
import Testing
@testable import CodevisorCore

extension PaneGroupStateTests {
  @Test("Descriptors persisted before attachOnly existed decode as user shells")
  func decodeLegacyDescriptor() throws {
    let legacy = Data(
      """
      {"id":"\(UUID().uuidString)","kind":"terminal","name":"Terminal 1","terminalKey":"abc","cwdOverride":"/tmp/x"}
      """.utf8)
    // Panes persisted with the retired per-pane cwd override still decode.
    let decoded = try JSONDecoder().decode(PaneDescriptorState.self, from: legacy)
    #expect(decoded.kind == .terminal)
    #expect(decoded.attachOnly == false)
    // Pre-owner-scoping agent tabs decode ownerless (any syncer adopts).
    #expect(decoded.ownerChatSessionId == nil)
    // Pre-plugin descriptors decode with no plugin payload.
    #expect(decoded.pluginId == nil)
    #expect(decoded.pluginPaneType == nil)
  }

  @Test("Agent terminal panes carry their owning chat and round-trip it")
  func agentTerminalOwner() throws {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    let owner = UUID()
    let pane = PaneDescriptorState.agentTerminal(
      name: "bun run dev",
      terminalKey: "\(sessionId.uuidString):bg:tool-2",
      owner: owner
    )
    state.panes.append(pane)
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self, from: JSONEncoder().encode(state)
    )
    #expect(decoded.panes.first { $0.id == pane.id }?.ownerChatSessionId == owner)
  }

  @Test("Codable round-trip preserves panes and selection")
  func codableRoundTrip() throws {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    state.addTerminalPane(sessionId: sessionId)
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self,
      from: JSONEncoder().encode(state)
    )
    #expect(decoded == state)
  }

  @Test("Decoding drops a selection that no longer matches a pane")
  func decodeRepairsSelection() throws {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
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
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    state.addTerminalPane(sessionId: sessionId)
    repo.save(state, sessionId: sessionId)
    var other = PaneGroupState()
    other.addTerminalPane(sessionId: otherSession)
    repo.save(other, sessionId: otherSession)
    #expect(repo.load(sessionId: sessionId) == state)
    #expect(repo.load(sessionId: otherSession)?.panes.count == 1)
  }
}
