import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Progress step lists")
struct ProgressStepsTests {
  @Test("A remote update marks stages it never reached as skipped and details the current one")
  func serverUpdateSkipsUnreachedStages() {
    var stages = ServerUpdateStages(.pausingChats)
    stages.advance(to: .updatingData)
    let migration = ServerMigrationProgress(id: "chat", name: "Updating chat history", completed: 40, total: 100)

    let steps = ServerUpdateSteps.steps(
      for: ServerUpdateActivity(stages: stages, migration: migration),
      isFailed: false
    )

    #expect(steps.map(\.state) == [.done, .skipped, .running, .pending, .pending])
    #expect(steps[2].details == ["Updating chat history · 40 of 100", "40 of 100"])
    #expect(steps.filter { !$0.details.isEmpty }.count == 1)
  }

  @Test("A failed remote update fails the stage it stopped on")
  func serverUpdateFailsCurrentStage() {
    var stages = ServerUpdateStages(.installing)
    stages.advance(to: .restarting)

    let steps = ServerUpdateSteps.steps(for: ServerUpdateActivity(stages: stages), isFailed: true)

    #expect(steps.map(\.state) == [.skipped, .done, .skipped, .failed, .pending])
  }

  @Test("Local startup runs the step the server is on, with its work count")
  func localStartupShowsCurrentWork() throws {
    var progress = LocalServerStartupProgress(stage: "openingDatabase", completed: 3)
    progress.work = try JSONDecoder().decode(
      LocalServerStartupProgress.Work.self,
      from: Data(#"{"id":"chat","completed":2,"total":5,"name":"Indexing chats"}"#.utf8)
    )

    let steps = LocalServerStartupSteps.steps(for: progress, isFailed: false)

    #expect(steps.map(\.state) == [.done, .done, .done, .running, .pending, .pending, .pending])
    #expect(steps[3].title == "Preparing database")
    #expect(steps[3].details == ["Indexing chats · 2 of 5", "2 of 5"])
  }

  @Test("A finished local startup shows every step done")
  func localStartupFinished() {
    let progress = LocalServerStartupProgress(stage: "ready", completed: 7)

    let steps = LocalServerStartupSteps.steps(for: progress, isFailed: false)

    #expect(steps.allSatisfy { $0.state == .done })
  }

  @Test("An app update shows its download percentage on the current step")
  func appUpdateShowsPercent() {
    let activity = AppUpdateActivity(stage: .preparing, statusMessage: "Preparing…", progress: 0.256)

    let steps = AppUpdateSteps.steps(for: activity)

    #expect(steps.map(\.state) == [.done, .running, .pending, .pending])
    #expect(steps[1].details == ["26%"])
  }
}
