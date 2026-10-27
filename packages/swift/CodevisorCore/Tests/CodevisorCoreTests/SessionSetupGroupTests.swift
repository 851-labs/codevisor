import Foundation
import Testing

@testable import CodevisorCore

@Suite("The sandbox's start steps fold into one disclosure")
struct SessionSetupGroupTests {
  private let steps = SandboxSetupSteps(target: .tartVM, projectName: "hello-world")
  private let start = Date(timeIntervalSince1970: 1_000)

  @Test("Sandbox steps fold into one group ahead of other setup, which stays on its own")
  func grouping() {
    let worktree = SessionSetupPhase.worktree(startedAt: start)
    let phases = [steps.phase(.create, startedAt: start), worktree, steps.phase(.boot, isPending: true)]

    let groups = SessionSetupGroup.grouping(phases)

    #expect(groups.map(\.id) == ["sandbox-start", worktree.id])
    #expect(SessionSetupGroup.grouping([worktree]) == [.phase(worktree)])
  }

  @Test("It reads Starting while a step runs, then how long the whole start took")
  func runningThenStarted() throws {
    var create = steps.phase(.create, startedAt: start)
    var boot = steps.phase(.boot, startedAt: start.addingTimeInterval(4))
    let running = try #require(SandboxStartSummary(steps: [create, boot, steps.phase(.clone, isPending: true)]))

    create.succeed(at: start.addingTimeInterval(4))
    boot.succeed(at: start.addingTimeInterval(94))
    let started = try #require(SandboxStartSummary(steps: [create, boot]))

    #expect([running.state, started.state] == [.running, .succeeded])
    #expect(running.title == "Starting sandbox")
    #expect(running.currentStep?.id == "sandbox-create")
    #expect(started.title == "Started sandbox in 1m 34s")
    #expect(started.startedAt == start)
  }

  @Test("A failed step marks the whole start as failed")
  func failed() throws {
    var boot = steps.phase(.boot, startedAt: start)
    boot.fail(message: "The limit of 2 macOS VMs per Mac has been reached", at: start.addingTimeInterval(1))

    let summary = try #require(SandboxStartSummary(steps: [boot]))

    #expect(summary.state == .failed)
    #expect(summary.title == "Couldn't start sandbox")
    #expect(summary.duration == nil)
    #expect(SandboxStartSummary(steps: []) == nil)
  }

  @Test("Setup durations read in seconds, then minutes and seconds")
  func durations() {
    #expect(SetupDuration.completed("Booted Tart VM", after: 0.4) == "Booted Tart VM in a moment")
    #expect(SetupDuration.completed("Booted Tart VM", after: 40) == "Booted Tart VM in 40s")
    #expect(SetupDuration.elapsed(since: start, to: start.addingTimeInterval(125)) == "2m 5s")
    #expect(SetupDuration.elapsed(since: start, to: start.addingTimeInterval(-3)) == "0s")
  }
}
