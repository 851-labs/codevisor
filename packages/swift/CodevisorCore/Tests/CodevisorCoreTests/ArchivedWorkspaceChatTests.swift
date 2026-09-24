import Foundation
import Testing

@testable import CodevisorCore

/// On main, opening or listing a chat whose workspace was archived minted a
/// new, live, device-only workspace for it -- the archived chats users saw
/// back in their sidebars on every platform. The chat's workspace is the
/// server's, archived or not.
@MainActor
struct ArchivedWorkspaceChatTests {
  @Test("A chat in an archived workspace resolves to that workspace and never mints a live one")
  func archivedChatStaysArchived() async {
    let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Old chat", worktreeName: "cheddar")
    let archived = Workspace(
      name: "cheddar", rootDirectory: "/src/app", worktreeName: "cheddar", serverId: "m", projectId: project.id,
      centerTree: .leaf(.centerInitial(sessionId: chat.id, paneId: chat.id)), isArchived: true, isServerSynced: true)
    let fixture = NavigationFixture()
    await fixture.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [archived])

    let resolved = fixture.workspaces.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: chat.id, initialName: "cheddar", serverId: "m", projectId: project.id,
        rootDirectory: "/src/app", worktreeName: "cheddar"),
      legacyGroups: nil)

    #expect(resolved.id == archived.id)
    #expect(resolved.isArchived)
    #expect(fixture.workspaces.loadAll().filter { !$0.isArchived }.isEmpty)
    #expect(fixture.store.layouts.drafts.isEmpty)
  }

  @Test("Upgrading drops the device-only duplicates main minted for archived chats")
  func migrationDropsMintedDuplicates() throws {
    let store = InMemoryStore()
    let archivedId = UUID()
    let mintedId = UUID()
    let tab = WorkspaceTab(root: .leaf(PaneGroupState()))
    func record(_ id: UUID, archived: Bool, synced: Bool) -> [String: Any] {
      [
        "id": id.uuidString, "name": "cheddar", "hasCustomName": false, "serverId": "m",
        "projectId": UUID().uuidString, "createdAt": 0, "isArchived": archived, "isServerSynced": synced,
        "centerTabs": [try! JSONSerialization.jsonObject(with: JSONEncoder().encode(tab))],
        "selectedCenterTabId": tab.id.uuidString,
      ]
    }
    let payload: [String: Any] = [
      "version": 2, "sessionIndex": [String](),
      "workspaces": [
        record(archivedId, archived: true, synced: true), record(mintedId, archived: false, synced: false),
      ],
    ]
    try store.saveData(JSONSerialization.data(withJSONObject: payload), forKey: "workspaces")

    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["m"])
    PersistenceEncoding.drain()

    let layouts = DeviceLayoutStore(store: store)
    #expect(layouts.layout(for: archivedId) != nil)
    #expect(layouts.layout(for: mintedId) == nil)
    #expect(layouts.drafts.isEmpty)
  }
}
