import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorkspaceGitSyncTests {
  private let git = ServerWorkspaceGit(
    branch: "codevisor/feature",
    pullRequest: ServerGitPullRequest(
      number: 42, title: "Ship it", state: .open, isDraft: false,
      url: URL(string: "https://github.com/acme/app/pull/42")!, checks: .passing))

  private func workspace(in project: Project) -> Workspace {
    var workspace = Workspace(
      name: "Feature", rootDirectory: "/tmp/workspace-git", serverId: "local", projectId: project.id,
      centerTree: .leaf(.centerInitialWithoutChat()), isServerSynced: true)
    workspace.git = git
    return workspace
  }

  @Test("A workspace's branch and pull request arrive with its record and are there on a cold start")
  func gitSurvivesColdStart() async throws {
    let persistence = InMemoryStore()
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/workspace-git"))
    let workspace = workspace(in: project)
    let previous = NavigationFixture(persistence: persistence)
    await previous.install(projects: [project], workspaces: [workspace])
    #expect(previous.workspaces.workspace(id: workspace.id)?.git == git)
    PersistenceEncoding.drain()

    let relaunched = NavigationFixture(persistence: persistence)

    #expect(relaunched.workspaces.workspace(id: workspace.id)?.git == git)
  }

  @Test("Renaming a workspace locally keeps the branch and pull request the server reported")
  func renameKeepsGit() async throws {
    let fixture = NavigationFixture()
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/workspace-git"))
    let workspace = workspace(in: project)
    await fixture.install(projects: [project], workspaces: [workspace])

    fixture.store.enqueue(
      .renameWorkspace(workspaceId: workspace.id, name: "Renamed", hasCustomName: true), machineId: "local")

    let renamed = try #require(fixture.workspaces.workspace(id: workspace.id))
    #expect(renamed.name == "Renamed")
    #expect(renamed.git == git)
  }
}
