import Foundation
import Testing
import CodevisorClient

@testable import CodevisorCore

@Suite("Ephemeral machine setup steps")
struct EphemeralSetupStepsTests {
  @Test("Server steps become phases with the server's start times and durations")
  func stepsBecomePhaseUpdates() {
    let steps = [
      ServerEphemeralSetupStep(
        stage: "create", startedAt: "2026-10-26T18:00:00.000Z", endedAt: "2026-10-26T18:00:00.250Z"),
      ServerEphemeralSetupStep(stage: "boot", startedAt: "2026-10-26T18:00:00.250Z"),
      ServerEphemeralSetupStep(stage: "warpDrive", startedAt: "2026-10-26T18:00:01.000Z"),
    ]

    let updates = EphemeralSetupSteps.updates(steps: steps, begun: [], finished: [])

    #expect(
      updates == [
        .begin(.create, startedAt: Date(timeIntervalSince1970: 1_793_037_600)),
        .succeed(.create, durationMs: 250),
        .begin(.boot, startedAt: Date(timeIntervalSince1970: 1_793_037_600.25)),
      ])
  }

  @Test("Stages already shown or finished aren't started or finished again")
  func repeatedPollsChangeNothing() {
    let steps = [
      ServerEphemeralSetupStep(stage: "create", startedAt: "2026-10-26T18:00:00Z", endedAt: "2026-10-26T18:00:01Z"),
      ServerEphemeralSetupStep(stage: "boot", startedAt: "2026-10-26T18:00:01Z", endedAt: "2026-10-26T18:00:11Z"),
    ]

    let updates = EphemeralSetupSteps.updates(steps: steps, begun: [.create, .boot], finished: [.create])

    #expect(updates == [.succeed(.boot, durationMs: 10_000)])
  }

  @Test("Phases and status lines name the machine, the project and the agent")
  func titles() {
    let steps = EphemeralSetupSteps(target: .provider("tart"), projectName: "hello-world", agentName: "OpenCode")
    let phases = EphemeralSetupStage.allCases.map { steps.phase($0) }

    #expect(phases.map(\.id).first == "ephemeral-create")
    #expect(
      phases.map(\.activeTitle) == [
        "Creating Tart VM", "Booting Tart VM", "Installing Codevisor", "Signing in to Codevisor",
        "Syncing your setup", "Cloning hello-world", "Connecting to Tart VM", "Preparing OpenCode",
      ])
    #expect(phases.map(\.failedTitle).first == "Could not create Tart VM")
    #expect(steps.phase(.signIn).completedTitle == "Signed in to Codevisor")
    #expect(steps.phase(.signIn, isPending: true).upcomingTitle == "Sign in to Codevisor")
    #expect(steps.status(.clone) == "Cloning hello-world…")
  }

  @Test("Upcoming steps follow the machine's plan, then the app's own steps")
  func upcomingSteps() {
    let upcoming = EphemeralSetupSteps.upcoming(
      plan: ["create", "install", "signIn", "sync", "clone"], begun: [.create, .install])

    #expect(upcoming == [.signIn, .sync, .clone, .connect, .agent])
  }

  @Test("The machine's own record of the clone folds into the Clone step instead of trailing the list")
  func cloneCoversProjectSetup() {
    let steps = EphemeralSetupSteps(target: .provider("tart"), projectName: "hello-world")
    let live = [steps.phase(.clone), steps.phase(.connect)]
    let project = SessionSetupPhase(
      id: "project.setup:p1", activeTitle: "Setting up project", completedTitle: "Set up project",
      failedTitle: "Could not set up project")
    let worktree = SessionSetupPhase(
      id: "worktree.setup:w1", activeTitle: "Setting up worktree", completedTitle: "Set up worktree",
      failedTitle: "Could not set up worktree")

    let merged = SessionSetupPhases.merging(live: live, persisted: [project, worktree])

    #expect(merged.map(\.id) == ["ephemeral-clone", "ephemeral-connect", "worktree.setup:w1"])
    #expect(
      SessionSetupPhases.merging(live: [.worktree()], persisted: [worktree, project]).map(\.id)
        == ["worktree", "project.setup:p1"])
  }

  @Test("Each provider has a picker title, and unknown ones still read sensibly")
  func pickerTitles() {
    let titles = ["tart", "e2b", "modal", "acme"].map { EphemeralTarget.provider($0).pickerTitle }

    #expect(titles == ["New Tart VM", "New E2B Sandbox", "New Modal Sandbox", "New acme machine"])
  }

  @Test("A relocated workspace keeps its id, tabs and order but moves machine and project")
  @MainActor
  func relocatedWorkspace() {
    let original = Workspace(
      name: "hello-world", rootDirectory: "/owner/repo", serverId: "local", projectId: UUID(),
      centerTree: .leaf(PaneGroupState.centerInitial(sessionId: UUID()))
    )
    var remote = Project.fromFolder(URL(fileURLWithPath: "/Users/admin/hello-world"), serverId: "cloud:dev-1")
    remote.id = UUID()

    let moved = EphemeralSessionRelocation.relocatedWorkspace(original, to: remote)

    #expect(moved.id == original.id)
    #expect(moved.serverId == "cloud:dev-1")
    #expect(moved.projectId == remote.id)
    #expect(moved.rootDirectory == nil)
    #expect(moved.centerTabs == original.centerTabs)
    #expect(moved.sidebarPosition == original.sidebarPosition)
  }
}
