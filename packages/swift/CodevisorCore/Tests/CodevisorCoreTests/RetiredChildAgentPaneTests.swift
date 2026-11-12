import Foundation
import Testing
@testable import CodevisorCore

@Suite("Retired child agent splits")
struct RetiredChildAgentPaneTests {
  @Test("A layout saved with a child agent split still loads, with the split dropped and its chat kept")
  func savedChildSplitIsDropped() throws {
    let persistence = InMemoryStore()
    let chat = PaneDescriptorState(id: UUID(), kind: .chat, name: "Chat", terminalKey: "chat", chatSessionId: UUID())
    let child = PaneDescriptorState(id: UUID(), kind: .newTab, name: "Child", terminalKey: "child")
    var workspace = Workspace(
      name: "W", rootDirectory: nil, serverId: "local", projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState(panes: [chat], selectedPaneId: chat.id)))],
      createdAt: Date(timeIntervalSince1970: 0))
    let inserted = workspace.insertPane(child, besidePane: chat.id, destination: .split(.trailing))
    DeviceLayoutStore(store: persistence).setLayout(DeviceLayout(workspace), for: workspace.id)
    PersistenceEncoding.drain()
    let saved = try #require(persistence.loadData(forKey: DeviceLayoutStore.storageKey))
    let retired = String(decoding: saved, as: UTF8.self).replacingOccurrences(
      of: #""kind":"newTab""#, with: #""kind":"childAgent""#)
    try persistence.saveData(Data(retired.utf8), forKey: DeviceLayoutStore.storageKey)

    let restored = try #require(DeviceLayoutStore(store: persistence).layout(for: workspace.id))
    workspace.centerTabs = restored.tabs
    let records = [ServerPaneMapping.record(from: chat, workspaceId: workspace.id, createdAt: workspace.createdAt)]
    WorkspacePaneReconciler(records: records, protectedLocalPaneIds: []).reconcile(&workspace)

    #expect(inserted != nil)
    #expect(retired.contains("childAgent"))
    #expect(workspace.allPanes.map(\.id) == [chat.id])
    #expect(workspace.centerTabs.map { $0.root.allGroups.count } == [1])
  }
}
