import Foundation
import Testing

@testable import CodevisorCore

/// Plugin pane decode-compat: the new `.plugin` kind, its descriptor payload,
/// the element-lenient pane-array decode, and New Tab conversion.
@Suite("PaneGroupState plugin panes")
struct PaneGroupStatePluginTests {
    private let sessionId = UUID()

    @Test("Plugin descriptors round-trip their plugin payload")
    func pluginDescriptorRoundTrip() throws {
        let pane = PaneDescriptorState(
            id: UUID(),
            kind: .plugin,
            name: "Git Diff",
            terminalKey: UUID().uuidString,
            pluginId: "codevisor.git-diff",
            pluginPaneType: "diff"
        )
        let decoded = try JSONDecoder().decode(
            PaneDescriptorState.self, from: JSONEncoder().encode(pane)
        )
        #expect(decoded == pane)
        #expect(decoded.pluginId == "codevisor.git-diff")
        #expect(decoded.pluginPaneType == "diff")
    }

    @Test("Descriptors persisted before plugin panes decode with no plugin payload")
    func decodePrePluginDescriptor() throws {
        let legacy = Data(
            """
            {"id":"\(UUID().uuidString)","kind":"terminal","name":"Terminal 1","terminalKey":"abc"}
            """.utf8)
        let decoded = try JSONDecoder().decode(PaneDescriptorState.self, from: legacy)
        #expect(decoded.pluginId == nil)
        #expect(decoded.pluginPaneType == nil)
    }

    @Test("An unknown future pane kind drops alone instead of failing the group")
    func lenientPaneArrayDecode() throws {
        var state = PaneGroupState.initial(sessionId: sessionId)
        state.selectPane(id: state.panes[0].id)
        var json =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(state)
            ) as! [String: Any]
        var panes = json["panes"] as! [[String: Any]]
        // A pane persisted by a NEWER build: its kind means nothing here.
        let unknownId = UUID().uuidString
        panes.append([
            "id": unknownId, "kind": "hologram", "name": "Future", "terminalKey": unknownId,
        ])
        // Selection pointing at the dropped pane must repair, not crash.
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

        // A plugin conversion without its plugin identity is refused (the
        // placeholder stays).
        let second = state.addNewTabPane()
        #expect(state.convertNewTabPane(id: second.id, to: .plugin, sessionId: sessionId) == nil)
        #expect(state.panes.first { $0.id == second.id }?.kind == .newTab)
    }
}
