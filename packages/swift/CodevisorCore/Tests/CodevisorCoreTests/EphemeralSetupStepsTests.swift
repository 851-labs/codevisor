import Foundation
import Testing

@testable import CodevisorCore

@Suite("Ephemeral machine setup steps")
struct EphemeralSetupStepsTests {
  private let steps = EphemeralSetupSteps(target: .provider("tart"), projectName: "hello-world")

  @Test("Server states map onto the three visible stages")
  func stagesFromServerStates() {
    let states = ["creating", "bootstrapping", "syncing", "cloning", "ready", "failed"]

    #expect(states.map(EphemeralSetupStage.init(serverState:)) == [.starting, .starting, .syncing, .cloning, nil, nil])
  }

  @Test("A stage seen for the first time begins every stage before it, finishing the ones it skipped")
  func skippedStagesFinish() {
    #expect(EphemeralSetupSteps.transitions(from: nil, to: .starting) == [.begin(.starting)])
    #expect(
      EphemeralSetupSteps.transitions(from: nil, to: .cloning) == [
        .begin(.starting), .succeed(.starting), .begin(.syncing), .succeed(.syncing), .begin(.cloning),
      ])
    #expect(
      EphemeralSetupSteps.transitions(from: .starting, to: .syncing) == [.succeed(.starting), .begin(.syncing)])
  }

  @Test("Repeated or earlier states change nothing, and ready finishes what's left")
  func readyFinishesEverything() {
    #expect(EphemeralSetupSteps.transitions(from: .syncing, to: .syncing).isEmpty)
    #expect(EphemeralSetupSteps.transitions(from: .cloning, to: .starting).isEmpty)
    #expect(EphemeralSetupSteps.transitions(from: .cloning, to: nil) == [.succeed(.cloning)])
    #expect(
      EphemeralSetupSteps.transitions(from: .syncing, to: nil) == [
        .succeed(.syncing), .begin(.cloning), .succeed(.cloning),
      ])
  }

  @Test("Phases and status lines name the machine and the project")
  func titles() {
    let phases = EphemeralSetupStage.allCases.map(steps.phase)

    #expect(phases.map(\.id) == ["ephemeral-starting", "ephemeral-syncing", "ephemeral-cloning"])
    #expect(phases.map(\.activeTitle) == ["Starting Tart VM", "Syncing your setup", "Cloning hello-world"])
    #expect(phases.map(\.failedTitle).first == "Could not start Tart VM")
    #expect(steps.status(.cloning) == "Cloning hello-world…")
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
