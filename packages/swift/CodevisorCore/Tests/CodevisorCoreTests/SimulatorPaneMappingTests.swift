import Foundation
import Testing

import CodevisorClient
@testable import CodevisorCore

@Suite struct SimulatorPaneMappingTests {
  @Test func theChosenDeviceTravelsThroughThePaneRegistry() throws {
    let pane = PaneDescriptorState(
      id: UUID(), kind: .simulator, name: "Simulator", terminalKey: "key",
      simulator: SimulatorPanePreferences(udid: "8C2D33A1-7E5B-4F0A-9C3D-2B1E4F6A7D90"))
    let record = WorkspaceSyncModel.serverPane(
      from: pane, workspaceId: UUID(), createdAt: Date(timeIntervalSince1970: 0))
    #expect(record.providerId == "codevisor")
    #expect(record.paneType == "simulator")
    let restored = try #require(WorkspaceSyncModel.descriptor(from: record))
    #expect(restored.kind == .simulator)
    #expect(restored.simulator == pane.simulator)
    #expect(try JSONDecoder().decode(PaneDescriptorState.self, from: JSONEncoder().encode(pane)) == pane)
  }

  @Test func aPaneWithoutADeviceOpensOnThePickerAndNewerSchemasAreLeftAlone() throws {
    // A pane created by another client before it chose a device.
    var record = ServerWorkspacePane(
      id: UUID().uuidString, workspaceId: UUID().uuidString, providerId: "codevisor",
      paneType: "simulator", title: "Simulator", createdAt: "2026-01-01T00:00:00.000Z")
    #expect(WorkspaceSyncModel.descriptor(from: record)?.simulator == SimulatorPanePreferences())
    record.metadata = #"{"schemaVersion":2}"#
    #expect(WorkspaceSyncModel.descriptor(from: record) == nil)
    var state = PaneGroupState.centerInitial(sessionId: UUID())
    let placeholder = state.addNewTabPane()
    let result = state.convertNewTabPane(id: placeholder.id, to: .simulator, sessionId: UUID())
    let converted = try #require(result)
    #expect(converted.simulator?.udid == nil)
    #expect(state.selectedPaneId == converted.id)
  }
}
