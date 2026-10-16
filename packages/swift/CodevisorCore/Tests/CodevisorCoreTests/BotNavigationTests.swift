import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Bot navigation")
struct BotNavigationTests {
  @Test("Bot home workspaces stay listed for clients without a Bots section, but bot projects leave pickers")
  func botWorkspacesAreHidden() async {
    let fixture = NavigationFixture()
    let regular = Project.fromFolder(URL(fileURLWithPath: "/tmp/regular"))
    let home = Project.fromFolder(URL(fileURLWithPath: "/tmp/codevisor/bots/helper"))
    let regularChat = ChatSession(projectId: regular.id, harnessId: "codex", title: "Regular")
    let botChat = ChatSession(projectId: home.id, harnessId: "codex", title: "Helper")
    let workspaces = [
      (regular, regularChat, false), (home, botChat, false),
      (home, ChatSession(projectId: home.id, harnessId: "codex"), true),
    ].map { project, chat, isArchived in
      Workspace(
        name: project.name, rootDirectory: project.folderURL.path, serverId: "local",
        projectId: project.id,
        centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat.id)))],
        createdAt: Date(timeIntervalSince1970: 0), isArchived: isArchived, isServerSynced: true
      )
    }
    for workspace in workspaces {
      fixture.store.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    }
    var snapshot = ServerNavigationSnapshot.fixture(
      projects: [regular, home], sessions: [regularChat, botChat], workspaces: workspaces)
    snapshot.projects = snapshot.projects.map { project in
      var project = project
      project.isBot = project.id == home.id.uuidString
      return project
    }

    await fixture.store.replace(snapshot, machineId: "local", requestedAt: Date())

    #expect(Set(fixture.store.workspaceEntries.sidebar.map(\.id)) == [workspaces[0].id, workspaces[1].id])
    #expect(fixture.store.workspaceEntries.archived.map(\.id) == [workspaces[2].id])
    #expect(fixture.store.workspaceEntries.botChildren.isEmpty)
    #expect(fixture.store.workspaceEntries.entry(workspaces[1].id).workspace?.projectId == home.id)
    #expect(fixture.projectList.fleetActiveProjects.map(\.id) == [regular.id])
  }
}

@MainActor
@Suite("Bot workspaces")
struct BotWorkspaceNavigationTests {
  @Test("Workspaces created by a bot are grouped by bot and still listed for clients without a Bots section")
  func botWorkspacesNestUnderTheBot() async throws {
    let fixture = NavigationFixture()
    let botId = UUID()
    let repo = Project.fromFolder(URL(fileURLWithPath: "/tmp/repo"))
    let home = Project.fromFolder(URL(fileURLWithPath: "/tmp/codevisor/bots/helper"))
    func workspace(_ project: Project, _ chat: ChatSession, isArchived: Bool = false, bot: UUID?) -> Workspace {
      var workspace = Workspace(
        name: project.name, rootDirectory: project.folderURL.path, serverId: "local",
        projectId: project.id,
        centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat.id)))],
        createdAt: Date(timeIntervalSince1970: 0), isArchived: isArchived, isServerSynced: true
      )
      workspace.botId = bot
      return workspace
    }
    let chats = (0..<4).map { _ in ChatSession(projectId: repo.id, harnessId: "codex") }
    let regular = workspace(repo, chats[0], bot: nil)
    let child = workspace(repo, chats[1], bot: botId)
    let homeChild = workspace(home, chats[2], bot: botId)
    let archivedChild = workspace(repo, chats[3], isArchived: true, bot: botId)
    let workspaces = [regular, child, homeChild, archivedChild]
    for workspace in workspaces {
      fixture.store.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    }
    var snapshot = ServerNavigationSnapshot.fixture(
      projects: [repo, home], sessions: chats, workspaces: workspaces)
    snapshot.projects = snapshot.projects.map { project in
      var project = project
      project.isBot = project.id == home.id.uuidString
      return project
    }

    await fixture.store.replace(snapshot, machineId: "local", requestedAt: Date())

    let entries = fixture.store.workspaceEntries
    #expect(Set(entries.sidebar.map(\.id)) == [regular.id, child.id, homeChild.id])
    #expect(Set(entries.botChildren[botId]?.map(\.id) ?? []) == [child.id, homeChild.id])
    #expect(entries.archived.map(\.id) == [archivedChild.id])
    #expect(entries.entry(child.id).workspace?.botId == botId)

    let record = try JSONDecoder().decode(
      ServerWorkspace.self,
      from: Data(
        #"{"id":"w","serverId":"s","projectId":"p","name":"n","hasCustomName":false,"isArchived":false,"createdAt":"2026-10-15T00:00:00.000Z","botId":"b"}"#
          .utf8))
    #expect(record.botId == "b")
  }
}
