import Foundation
import Testing

@testable import CodevisorCore

@Suite("PaneGroupState plugin panes")
struct PaneGroupStatePluginTests {
  private let sessionId = UUID()

  @Test("An unknown future pane kind drops alone instead of failing the group")
  func lenientPaneArrayDecode() throws {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    state.selectPane(id: state.panes[0].id)
    var json =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(state)
      ) as! [String: Any]
    var panes = json["panes"] as! [[String: Any]]
    let unknownId = UUID().uuidString
    panes.append([
      "id": unknownId, "kind": "hologram", "name": "Future", "terminalKey": unknownId,
    ])
    json["panes"] = panes
    json["selectedPaneId"] = unknownId
    let decoded = try JSONDecoder().decode(
      PaneGroupState.self,
      from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(decoded.panes.map(\.id) == state.panes.map(\.id))
    #expect(decoded.selectedPaneId == state.panes[0].id)
  }

  @Test("A New Tab placeholder converts to a plugin pane in place")
  func newTabConvertsToPlugin() {
    var state = PaneGroupState()
    state.addTerminalPane(sessionId: sessionId)
    let placeholder = state.addNewTabPane()

    let converted = state.convertNewTabPane(
      id: placeholder.id, to: .plugin, sessionId: sessionId,
      name: "Git Diff", pluginId: "codevisor.git-diff",
      pluginPaneType: "diff"
    )
    #expect(converted?.kind == .plugin)
    #expect(converted?.id == placeholder.id)
    #expect(converted?.name == "Git Diff")
    #expect(converted?.pluginId == "codevisor.git-diff")
    #expect(converted?.pluginPaneType == "diff")
    #expect(state.selectedPaneId == converted?.id)

    let second = state.addNewTabPane()
    #expect(state.convertNewTabPane(id: second.id, to: .plugin, sessionId: sessionId) == nil)
    #expect(state.panes.first { $0.id == second.id }?.kind == .newTab)
  }
}
