import Foundation
import Testing

@testable import CodevisorCore

/// "No project" drafts run in a single-use scratch folder, which has no
/// repository: a worktree preference must never follow the draft there.
@MainActor
@Suite("SessionController no-project drafts")
struct SessionControllerNoProjectTests {
  private func gitProject(serverId: String = "machine-a") -> Project {
    var project = Project.fromFolder(URL(fileURLWithPath: "/tmp/repo"), serverId: serverId)
    project.locations[0].isGitRepository = true
    return project
  }

  @Test("Choosing No project drops a worktree preference carried from a git project")
  func selectPlaceholderResetsWorktreePreference() async {
    let controller = SessionController(
      project: gitProject(),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    controller.wantsNewWorktree = true

    await controller.selectProject(.runTargetPlaceholder(serverId: "machine-a"))

    #expect(controller.project.isRunTargetPlaceholder)
    #expect(!controller.wantsNewWorktree)
  }

  @Test("Retargeting to No project on another machine drops the preference too")
  func retargetToPlaceholderResetsWorktreePreference() async {
    let controller = SessionController(
      project: gitProject(serverId: "machine-a"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: SyncFakeServerClient(projects: [], sessions: [])
    )
    controller.wantsNewWorktree = true

    await controller.retarget(
      to: .runTargetPlaceholder(serverId: "machine-b"),
      serverClient: SyncFakeServerClient(projects: [], sessions: [])
    )

    #expect(controller.project.serverId == "machine-b")
    #expect(!controller.wantsNewWorktree)
  }

  @Test("A draft mid-send on a scratch folder snapshots as No project")
  func scratchProjectSnapshotsAsPlaceholder() {
    var scratch = Project.fromFolder(URL(fileURLWithPath: "/tmp/workspaces/burrito"))
    scratch.isScratch = true
    let controller = SessionController(
      project: scratch,
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    #expect(controller.draftSnapshot().projectId == Project.runTargetPlaceholderID)
    #expect(controller.draftSnapshot().projectServerId == scratch.serverId)
  }

  @Test("Switching between real projects keeps the worktree preference")
  func selectingGitProjectKeepsPreference() async {
    let controller = SessionController(
      project: gitProject(),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    controller.wantsNewWorktree = true

    let next = gitProject()
    await controller.selectProject(next)

    #expect(controller.project.id == next.id)
    #expect(controller.wantsNewWorktree)
  }
}
