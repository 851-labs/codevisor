import Foundation
import Testing

@testable import CodevisorCore

/// Project settings act on the project, not on one machine's checkout: one
/// choice reaches every machine that has it.
@MainActor
@Suite("Project settings across machines")
struct ProjectSettingsFleetTests {
  private let develop = ProjectWorktreeBase(remote: "origin", branch: "develop")
  private let release = ProjectWorktreeBase(remote: "upstream", branch: "release")

  private func checkout(
    on serverId: String, base: ProjectWorktreeBase?, isGit: Bool = true
  ) -> Project {
    let id = UUID()
    return Project(
      id: id, serverId: serverId, name: "app",
      locations: [
        ProjectLocation(projectId: id, serverId: serverId, folderPath: "/src/app", isGitRepository: isGit)
      ],
      repoUrl: "git@github.com:acme/app.git", repoKey: "github.com/acme/app", worktreeBase: base)
  }

  @Test("One base branch choice reaches every git checkout, and waits for an offline machine")
  func baseBranchAppliesAcrossMachines() async throws {
    let local = checkout(on: "local", base: nil)
    let remote = checkout(on: "remote-b", base: develop)
    let plainFolder = checkout(on: "remote-c", base: nil, isGit: false)
    let fixture = NavigationFixture()
    fixture.seed(projects: [local, remote, plainFolder])
    let model = fixture.projectList
    let group = try #require(model.fleetActiveProjectGroups.first)
    #expect(group.members.count == 3)
    // The project's one base branch is the one that was chosen.
    #expect(group.worktreeBase == develop)

    model.setWorktreeBase(release, for: group)

    // Shown at once, before any machine has it.
    #expect(model.fleetActiveProjectGroups.first?.worktreeBase == release)
    let localClient = FakeServerClient(projects: [serverProject(from: local)])
    fixture.connect(localClient, machineId: "local")
    await fixture.flush(machineId: "local")
    #expect(
      await localClient.snapshot().worktreeBaseUpdates
        == [FakeWorktreeBaseUpdate(projectId: local.id.uuidString, worktreeBase: release)])
    // The offline machine keeps the change until it reconnects; the folder
    // that isn't a repository has no base branch to set.
    let waiting = fixture.store.pendingIntents.filter {
      guard $0.state == .pending, case .setProjectWorktreeBase = $0.intent else { return false }
      return true
    }
    #expect(waiting.map(\.machineId) == ["remote-b"])
  }

  @Test("A checkout that differs is brought onto the project's base branch; an unset project is left alone")
  func alignsDivergentCheckouts() throws {
    let older = checkout(on: "local", base: develop)
    let newer = checkout(on: "remote-b", base: nil)
    let fixture = NavigationFixture()
    fixture.seed(projects: [older, newer])
    let model = fixture.projectList
    model.alignWorktreeBase(for: try #require(model.fleetActiveProjectGroups.first))
    let aligned = try #require(model.fleetActiveProjectGroups.first)
    #expect(aligned.members.allSatisfy { $0.worktreeBase == develop })

    let unset = NavigationFixture()
    unset.seed(projects: [checkout(on: "local", base: nil), checkout(on: "remote-b", base: nil)])
    unset.projectList.alignWorktreeBase(for: try #require(unset.projectList.fleetActiveProjectGroups.first))
    #expect(
      !unset.store.pendingIntents.contains {
        if case .setProjectWorktreeBase = $0.intent { return true }
        return false
      })
  }

  @Test("Delete Project and Files removes the folder on every machine; plain delete keeps it")
  func deleteWithFilesReachesEveryMachine() async throws {
    let local = checkout(on: "local", base: nil)
    let remote = checkout(on: "remote-b", base: nil)
    let fixture = NavigationFixture()
    fixture.seed(projects: [local, remote])
    let localClient = FakeServerClient(projects: [serverProject(from: local)])
    let remoteClient = FakeServerClient(projects: [serverProject(from: remote)])
    fixture.connect(localClient, machineId: "local")
    fixture.connect(remoteClient, machineId: "remote-b")
    let group = try #require(fixture.projectList.fleetActiveProjectGroups.first)

    fixture.projectList.removeProjectGroup(group, deletingFiles: true)
    #expect(fixture.projectList.fleetActiveProjectGroups.isEmpty)
    await fixture.flush(machineId: "local")
    await fixture.flush(machineId: "remote-b")

    #expect(await localClient.snapshot().filesDeletedProjectIDs == [local.id.uuidString])
    #expect(await remoteClient.snapshot().filesDeletedProjectIDs == [remote.id.uuidString])

    let other = checkout(on: "local", base: nil)
    fixture.seed(projects: [other])
    fixture.projectList.removeProject(other)
    await fixture.flush(machineId: "local")
    let snapshot = await localClient.snapshot()
    #expect(snapshot.deletedProjectIDs.contains(other.id.uuidString))
    #expect(!snapshot.filesDeletedProjectIDs.contains(other.id.uuidString))
  }

  @Test("A delete saved before folder deletion existed still decodes, and keeps the folder")
  func legacyDeleteIntentDecodes() throws {
    let projectId = UUID()
    let json = #"{"deleteProject":{"projectId":"\#(projectId.uuidString)","sessionIds":[]}}"#
    let intent = try JSONDecoder().decode(NavigationIntent.self, from: Data(json.utf8))
    #expect(intent == .deleteProject(projectId: projectId, sessionIds: [], deletesFiles: nil))
  }

  @Test("Branches merge across machines in the first machine's order, skipping offline ones")
  func branchesMergeAcrossMachines() async {
    let first = checkout(on: "local", base: nil)
    let offline = checkout(on: "remote-offline", base: nil)
    let second = checkout(on: "remote-b", base: nil)
    let failing = checkout(on: "remote-broken", base: nil)
    let model = ProjectBaseBranchModel()

    await model.load([first, offline, second, failing]) { project in
      switch project.serverId {
      case "local":
        return [
          ServerProjectGitBranch(remote: "origin", branch: "main", isDefault: true),
          ServerProjectGitBranch(remote: "origin", branch: "feature", isDefault: false),
        ]
      case "remote-b":
        return [
          ServerProjectGitBranch(remote: "origin", branch: "main", isDefault: false),
          ServerProjectGitBranch(remote: "origin", branch: "develop", isDefault: true),
        ]
      case "remote-broken":
        throw CodevisorServerClientError.httpStatus(422, "Project folder is not a git repository")
      default:
        return nil
      }
    }

    #expect(model.branches.map(\.displayName) == ["origin/main", "origin/feature", "origin/develop"])
    #expect(model.branches.filter(\.isDefault).map(\.displayName) == ["origin/main"])
    #expect(model.errorMessage != nil)
    #expect(!model.isLoading)
  }
}
