import Foundation
import Testing

import CodevisorClient
@testable import CodevisorCore

@Suite("Plugin app pane mapping")
struct PluginAppPaneMappingTests {
  private let resource = PluginAppPaneResource(
    viewId: "view-1", machineId: "cloud:studio", serverId: "mcp-z", serverName: "Zillow",
    toolName: "search_homes", resourceUri: "ui://zillow/results.html")

  @Test("A fullscreen app tab syncs as its view, so another device opens the same app on the same machine")
  func roundTrip() throws {
    let owner = UUID()
    let pane = PaneDescriptorState(
      id: UUID(), kind: .plugin, name: "Zillow", terminalKey: "key", ownerChatSessionId: owner, pluginId: "mcp-z",
      pluginApp: resource)

    let record = ServerPaneMapping.record(from: pane, workspaceId: UUID(), createdAt: Date(timeIntervalSince1970: 0))

    #expect(record.providerId == "plugin-app")
    #expect(record.paneType == "app")
    #expect(record.resourceKind == "app-view")
    #expect(record.resourceId == "view-1")
    let restored = try #require(ServerPaneMapping.descriptor(from: record))
    #expect(restored.kind == .plugin)
    #expect(restored.pluginApp == resource)
    #expect(restored.pluginId == "mcp-z")
    #expect(try JSONDecoder().decode(PaneDescriptorState.self, from: JSONEncoder().encode(pane)) == pane)
  }

  @Test("An app tab whose metadata doesn't name the synced view is dropped")
  func mismatchedRecord() {
    let record = ServerWorkspacePane(
      id: UUID().uuidString, workspaceId: UUID().uuidString, providerId: "plugin-app", paneType: "app",
      title: "Zillow", resourceKind: "app-view", resourceId: "view-2",
      metadata: #"{"viewId":"view-1","serverId":"mcp-z","serverName":"Zillow","toolName":"t","resourceUri":"ui://z"}"#,
      createdAt: "2026-01-01T00:00:00.000Z")

    #expect(ServerPaneMapping.descriptor(from: record) == nil)
  }
}
