import Foundation
import Testing
@testable import CodevisorCore

@Suite("Legacy pane migration")
struct WorkspaceLegacyPaneMigrationTests {
  @Test("Retired panel panes become stable tabs with their terminal identity and ownership intact")
  func migrateSavedPanel() throws {
    let session = UUID()
    let owner = UUID()
    var workspace = Workspace(
      name: "Saved", rootDirectory: "/saved", serverId: "local", projectId: UUID(),
      centerTree: .leaf(.centerInitial(sessionId: session)), createdAt: Date(timeIntervalSince1970: 0)
    )
    workspace.centerTabs[0].customTitle = "Pinned"
    let user = PaneGroupState.initial(sessionId: session).panes[0]
    let agent = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Server", terminalKey: "agent-key",
      attachOnly: true, ownerChatSessionId: owner
    )
    let plugin = PaneDescriptorState(
      id: UUID(), kind: .plugin, name: "Plugin", terminalKey: "plugin-key", pluginId: "test.plugin"
    )
    var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
    var legacy = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(
          PaneGroupState(panes: [user, agent, plugin], selectedPaneId: agent.id)
        )) as? [String: Any])
    legacy["height"] = 420
    legacy["isVisible"] = false
    payload["bottomGroup"] = legacy
    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try JSONDecoder().decode(Workspace.self, from: data)
    let decodedAgain = try JSONDecoder().decode(Workspace.self, from: data)
    #expect(decoded == decodedAgain)
    #expect(decoded.centerTabs.first == workspace.centerTabs.first)
    #expect(decoded.selectedCenterTabId == workspace.selectedCenterTabId)
    #expect(Array(decoded.allPanes.suffix(3)) == [user, agent, plugin])
    #expect(decoded.centerTabs.count == 4)
    #expect(decoded.centerTabs.allSatisfy { $0.root.allGroups.count == 1 })
    #expect(decoded.allPanes.filter { PaneNavigationVisibility().includes($0) }.count == 3)

    let saved = try JSONEncoder().encode(decoded)
    let savedJSON = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(savedJSON["bottomGroup"] == nil)
    #expect(try JSONDecoder().decode(Workspace.self, from: saved) == decoded)
    let groupJSON = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(
          decoded.centerTabs.last?.root.allGroups[0].state
        )) as? [String: Any])
    #expect(groupJSON["height"] == nil)
    #expect(groupJSON["isVisible"] == nil)
  }

  @Test("Migration does not duplicate panes already present in workspace tabs")
  func deduplicate() {
    let session = UUID()
    var workspace = Workspace(
      name: "Saved", rootDirectory: nil, serverId: "local", projectId: UUID(),
      centerTree: .leaf(.centerInitial(sessionId: session)), createdAt: Date(timeIntervalSince1970: 0)
    )
    let user = PaneGroupState.initial(sessionId: session).panes[0]
    workspace.upsertCenterPane(user, selecting: false)
    let duplicate = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Duplicate", terminalKey: user.terminalKey)
    let before = workspace
    workspace.importLegacyPanes([user, duplicate, user])
    #expect(workspace == before)
  }
}
