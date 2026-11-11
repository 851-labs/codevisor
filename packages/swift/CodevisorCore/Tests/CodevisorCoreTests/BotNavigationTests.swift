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
    #expect(fixture.store.workspaceEntries.entry(workspaces[1].id).workspace?.projectId == home.id)
    #expect(fixture.projectList.fleetActiveProjects.map(\.id) == [regular.id])
  }
}
