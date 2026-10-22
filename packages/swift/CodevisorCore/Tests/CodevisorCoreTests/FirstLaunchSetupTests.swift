import CodevisorTestSupport
import Testing

@testable import CodevisorCore

@MainActor
@Suite("First-launch setup screen")
struct FirstLaunchSetupTests {
  @Test("Never shows the screen when everything is ready within half a second")
  func skipsWhenReadyQuickly() async {
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.harnesses.resolve(["Claude Code"])
    work.projects.resolve(2)
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: TestClock())

    await setup.run()

    #expect(setup.presentation == .dismissed)
    #expect(!setup.wasShown)
    #expect(setup.detailCandidates(for: .projects) == ["2 projects"])
  }

  @Test("Offers Get Started once the last check lands, and only dismisses when pressed")
  func offersGetStartedWhenDone() async {
    let clock = TestClock()
    let work = readyExceptHarnesses()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await show(setup, clock: clock)
    setup.getStarted()
    #expect(setup.presentation == .visible)

    work.harnesses.resolve(["Claude Code"])
    await clock.waitForSleep(.milliseconds(140))
    clock.advance(by: .milliseconds(140))
    await clock.waitForSleep(.milliseconds(400))
    #expect(!setup.canGetStarted)
    clock.advance(by: .milliseconds(400))
    await running.value

    #expect(setup.canGetStarted)
    #expect(setup.presentation == .visible)
    setup.getStarted()
    #expect(setup.presentation == .dismissed)
  }

  @Test("Offers Get Started at fifteen seconds while slow work keeps going")
  func offersGetStartedAtCap() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await show(setup, clock: clock)

    await clock.waitForSleep(.seconds(15))
    clock.advance(by: .seconds(15))
    await awaitObserved { setup.canGetStarted }

    #expect(setup.revealed(.server) == .running)
    setup.getStarted()
    #expect(setup.presentation == .dismissed)
    running.cancel()
    await running.value
  }

  @Test("Hands a failed server start to the startup failure view", arguments: [false, true])
  func handsOffServerFailure(afterShowing: Bool) async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    if afterShowing { await show(setup, clock: clock) }

    work.server.resolve(.failed)
    await running.value

    #expect(setup.presentation == .handedOff)
    #expect(setup.wasShown == afterShowing)
    #expect(!setup.canGetStarted)
  }

  @Test("Skips steps that run past their time limits, keeping one spinner at a time")
  func skipsSlowSteps() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    for limit in [Duration.seconds(5), .seconds(6), .seconds(10)] {
      await clock.waitForSleep(limit)
    }
    await show(setup, clock: clock)
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .running, .pending, .pending])

    clock.advance(by: .milliseconds(4_500))
    await awaitObserved { setup.revealed(.harnesses) == .skipped }
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .skipped, .running, .pending])

    clock.advance(by: .seconds(1))
    await awaitObserved { setup.outcomes[.models] == .skipped }
    #expect(setup.revealed(.models) == .pending)

    clock.advance(by: .seconds(4))
    await awaitObserved { setup.isComplete }
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .skipped, .skipped, .skipped])
    #expect(setup.detailCandidates(for: .harnesses).isEmpty)

    await clock.waitForSleep(.milliseconds(400))
    clock.advance(by: .milliseconds(400))
    await running.value
    #expect(setup.canGetStarted)
  }

  @Test("Keeps a finished step quiet until every step above it is done")
  func revealsInOrder() async {
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: TestClock())
    let running = Task { await setup.run() }

    work.projects.resolve(6)
    await awaitObserved { setup.outcomes[.projects] == .done && setup.outcomes[.models] == .done }
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .running, .pending, .pending])
    #expect(setup.detailCandidates(for: .projects).isEmpty)

    work.harnesses.resolve(["Claude Code", "Codex"])
    await running.value
    #expect(setup.visibleHarnessNames == ["Claude Code", "Codex"])
    #expect(setup.detailCandidates(for: .projects) == ["6 projects"])
    #expect(setup.revealed(.models) == .done)
  }

  @Test("Counts projects up from real progress, only once projects is the current step")
  func countsProjectsUp() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await show(setup, clock: clock)

    work.reportProjectsAdded(2)
    work.harnesses.resolve(["Codex"])
    await clock.waitForSleep(.milliseconds(140))
    #expect(setup.visibleProjectCount == 0)
    clock.advance(by: .milliseconds(140))
    await awaitObserved { setup.revealed(.harnesses) == .done }

    for count in 1...2 {
      await clock.waitForSleep(.milliseconds(140), count: count + 1)
      clock.advance(by: .milliseconds(140))
      await awaitObserved { setup.visibleProjectCount == count }
    }
    #expect(setup.revealed(.projects) == .running)

    work.projects.resolve(4)
    await clock.waitForSleep(.milliseconds(140), count: 4)
    clock.advance(by: .milliseconds(140))
    await awaitObserved { setup.visibleProjectCount == 3 }
    await clock.waitForSleep(.milliseconds(140), count: 5)
    clock.advance(by: .milliseconds(140))
    await awaitObserved { setup.revealed(.projects) == .done }
    #expect(setup.detailCandidates(for: .projects) == ["4 projects"])

    await clock.waitForSleep(.milliseconds(400))
    clock.advance(by: .milliseconds(400))
    await running.value
  }

  @Test("Treats a failed step as a skip")
  func skipsFailedStep() async {
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.harnesses.resolve(["Codex"])
    work.projects.fail()
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: TestClock())

    await setup.run()

    #expect(setup.revealed(.projects) == .skipped)
    #expect(setup.revealed(.models) == .done)
  }

  private func readyExceptHarnesses() -> FirstLaunchFakeWork {
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.projects.resolve(0)
    work.models.resolve(())
    return work
  }

  private func show(_ setup: FirstLaunchSetup, clock: TestClock) async {
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await awaitObserved { setup.presentation == .visible }
  }
}
