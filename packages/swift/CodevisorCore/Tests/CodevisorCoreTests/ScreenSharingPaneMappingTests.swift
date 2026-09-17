import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct ScreenSharingPaneMappingTests {
  @Test func nativePaneRoundTripsOnlyPresentationPreferences() throws {
    let id = UUID()
    let preferences = ScreenSharingPanePreferences(preferredDisplayId: "display-uuid")
    let pane = PaneDescriptorState(
      id: id, kind: .screenSharing, name: "Screen Sharing", terminalKey: id.uuidString,
      screenSharing: preferences)
    let record = WorkspaceSyncModel.serverPane(
      from: pane, workspaceId: UUID(), createdAt: Date(timeIntervalSince1970: 0))
    #expect(record.providerId == "codevisor")
    #expect(record.paneType == "screen-sharing")
    #expect(record.resourceId == nil)
    #expect(record.resourceKind == nil)
    let data = try #require(record.metadata?.data(using: .utf8))
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(fields.keys) == ["schemaVersion", "preferredDisplayId"])
    #expect(WorkspaceSyncModel.descriptor(from: record) == pane)
    #expect(try JSONDecoder().decode(PaneDescriptorState.self, from: JSONEncoder().encode(pane)) == pane)
  }

  @Test func unsupportedMetadataDoesNotDiscardSiblingPanes() throws {
    let id = UUID()
    var record = ServerWorkspacePane(
      id: id.uuidString, workspaceId: UUID().uuidString, providerId: "codevisor",
      paneType: "screen-sharing", title: "Screen Sharing", metadata: #"{"schemaVersion":2}"#,
      createdAt: "2026-01-01T00:00:00.000Z")
    #expect(WorkspaceSyncModel.descriptor(from: record) == nil)
    record.metadata = "invalid"
    #expect(WorkspaceSyncModel.descriptor(from: record) == nil)
    var state = PaneGroupState.centerInitial(sessionId: UUID())
    let initial = state.panes
    let placeholder = state.addNewTabPane()
    let result = state.convertNewTabPane(id: placeholder.id, to: .screenSharing, sessionId: UUID())
    let converted = try #require(result)
    #expect(converted.screenSharing == ScreenSharingPanePreferences())
    #expect(state.panes.first == initial.first)
    #expect(state.selectedPaneId == converted.id)
  }
}
