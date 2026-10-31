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
    #expect(running.shownSteps.map(\.id) == ["sandbox-create", "sandbox-boot"])
    #expect(started.title == "Started sandbox in 1m 34s")
    #expect(started.startedAt == start)
  }

  @Test("Every step that has started streams into one log, with its error at the end")
  func oneLog() throws {
    var create = steps.phase(.create, startedAt: start)
    create.appendLog(stream: "stdout", line: "tart pull ghcr.io/cirruslabs/ubuntu:latest")
    create.appendLog(stream: "stdout", line: "Downloaded 0.2 of 3.1 GB (5%)")
    create.succeed(at: start.addingTimeInterval(30))
    var boot = steps.phase(.boot, startedAt: start.addingTimeInterval(30))
    boot.fail(message: "The Tart guest agent never answered", at: start.addingTimeInterval(90))

    let summary = try #require(SandboxStartSummary(steps: [create, boot, steps.phase(.clone, isPending: true)]))

    #expect(
      summary.log == """
        ==> Creating Tart VM
        tart pull ghcr.io/cirruslabs/ubuntu:latest
        Downloaded 0.2 of 3.1 GB (5%)
        ==> Booting Tart VM
        The Tart guest agent never answered
        """)
  }

  @Test("A failed step fails the whole start, which then reads how long it tried")
  func failed() throws {
    var boot = steps.phase(.boot, startedAt: start)
    boot.fail(message: "This Mac already runs 2 macOS VMs", at: start.addingTimeInterval(75))
    var quick = steps.phase(.create, startedAt: start)
    quick.fail(message: "quota exceeded", at: start)
    let clone = steps.phase(.clone, isPending: true)

    let summary = try #require(SandboxStartSummary(steps: [boot, clone]))

    #expect(summary.state == .failed)
    #expect(summary.title == "Sandbox failed after 1m 15s")
    #expect(summary.shownSteps.map(\.id) == ["sandbox-boot"])
    #expect(SandboxStartSummary(steps: [quick])?.title == "Sandbox failed")
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
