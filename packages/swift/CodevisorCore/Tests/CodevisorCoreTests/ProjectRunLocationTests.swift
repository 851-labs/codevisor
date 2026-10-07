import Foundation
import Testing

@testable import CodevisorCore

/// The project directory vs. new worktree choice belongs to the project:
/// picking it on one machine's checkout, from any client, is what every new
/// chat in that project starts with.
@MainActor
@Suite("Project run location")
struct ProjectRunLocationTests {
  private func checkout(on serverId: String, isGit: Bool = true) -> Project {
    let id = UUID()
    return Project(
      id: id, serverId: serverId, name: "app",
      locations: [
        ProjectLocation(projectId: id, serverId: serverId, folderPath: "/src/app", isGitRepository: isGit)
      ],
      repoUrl: "git@github.com:acme/app.git", repoKey: "github.com/acme/app")
  }

  @Test("One choice reaches every git checkout, and waits for an offline machine")
  func choiceAppliesAcrossMachines() async throws {
    let local = checkout(on: "local")
    let remote = checkout(on: "remote-b")
    let plainFolder = checkout(on: "remote-c", isGit: false)
    let fixture = NavigationFixture()
    fixture.seed(projects: [local, remote, plainFolder])
    let model = fixture.projectList
    let group = try #require(model.fleetActiveProjectGroups.first)
    #expect(group.defaultRunLocation == nil)

    model.setDefaultRunLocation(.newWorktree, for: group)

    // Shown at once, before any machine has it.
    #expect(model.fleetActiveProjectGroups.first?.defaultRunLocation == .newWorktree)
    let localClient = FakeServerClient(projects: [serverProject(from: local)])
    fixture.connect(localClient, machineId: "local")
    await fixture.flush(machineId: "local")
    #expect(
      await localClient.snapshot().runLocationUpdates
        == [FakeRunLocationUpdate(projectId: local.id.uuidString, location: .newWorktree)])
    // The folder that isn't a repository has no worktrees to choose.
    let waiting = fixture.store.pendingIntents.filter {
      guard $0.state == .pending, case .setProjectDefaultRunLocation = $0.intent else { return false }
      return true
    }
    #expect(waiting.map(\.machineId) == ["remote-b"])
  }

  @Test("New chats follow the project's choice over this client's own memory")
  func sharedChoiceWinsOverLocalMemory() throws {
    let local = checkout(on: "local")
    let remote = checkout(on: "remote-b")
    let plainFolder = checkout(on: "remote-c", isGit: false)
    let environment = AppEnvironment.preview(seedProjects: [local, remote, plainFolder], seedSessions: [])
    let composerDefaults = environment.composerDefaults
    // Remembered on this client before choices were shared: only that
    // machine's checkout knows it.
    composerDefaults.rememberNewWorkspaceWorktreePreference(
      serverId: local.serverId, projectId: local.id, createsWorktree: true)
    #expect(environment.prefersNewWorktree(for: local))
    #expect(!environment.prefersNewWorktree(for: remote))

    // Sending shares it, since nobody has chosen for the project yet.
    environment.rememberSentRunLocation(newWorktree: true, for: local)
    #expect(environment.prefersNewWorktree(for: remote))

    // A later send elsewhere doesn't override the choice; a pick does.
    environment.rememberSentRunLocation(newWorktree: false, for: remote)
    #expect(environment.prefersNewWorktree(for: local))
    environment.rememberRunLocation(newWorktree: false, for: remote)
    #expect(!environment.prefersNewWorktree(for: local))
    #expect(!environment.prefersNewWorktree(for: plainFolder))
  }
}
