import Foundation
import Testing
@testable import CodevisorCore

extension PaneGroupStateTests {
  @Test("Descriptors persisted with retired fields still decode")
  func decodeLegacyDescriptor() throws {
    let legacy = Data(
      """
      {"id":"\(UUID().uuidString)","kind":"terminal","name":"Terminal 1","terminalKey":"abc","cwdOverride":"/tmp/x","attachOnly":false}
      """.utf8)
    let decoded = try JSONDecoder().decode(PaneDescriptorState.self, from: legacy)
    #expect(decoded.kind == .terminal)
    #expect(decoded.terminalActivity == nil)
    #expect(decoded.liveTitle == nil)
    #expect(decoded.ownerChatSessionId == nil)
    #expect(decoded.pluginId == nil)
    #expect(decoded.pluginPaneType == nil)
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

    let second = state.addTerminalPane(sessionId: sessionId)
    let kept = try JSONDecoder().decode(PaneGroupState.self, from: JSONEncoder().encode(state))
    #expect(kept.selectedPaneId == second.id)
  }
}
