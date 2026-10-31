import Foundation
import Testing

@testable import CodevisorCore

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
}
