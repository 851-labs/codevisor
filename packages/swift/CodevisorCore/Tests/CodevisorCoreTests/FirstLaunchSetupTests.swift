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
  }

  @Test("Stays up for at least a second and a half once it is shown")
  func keepsMinimumTimeOnScreen() async {
    let clock = TestClock()
    let work = readyExceptHarnesses()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await show(setup, clock: clock)

    clock.advance(by: .milliseconds(200))
    work.harnesses.resolve(["Claude Code"])
    await clock.waitForSleep(.milliseconds(1_300))
    #expect(setup.presentation == .visible)

    clock.advance(by: .milliseconds(1_300))
    await awaitObserved { setup.presentation == .dismissed }
    await running.value
    #expect(setup.wasShown)
  }

  @Test("Lets the last check settle briefly when the minimum has already passed")
  func settlesAfterMinimum() async {
    let clock = TestClock()
    let work = readyExceptHarnesses()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await show(setup, clock: clock)

    clock.advance(by: .seconds(3))
    work.harnesses.resolve(["Claude Code"])
    await clock.waitForSleep(.milliseconds(400))
    #expect(setup.presentation == .visible)

    clock.advance(by: .milliseconds(400))
    await awaitObserved { setup.presentation == .dismissed }
    await running.value
  }

  @Test("Goes away after fifteen seconds and leaves slow work running")
  func dismissesAtMaximum() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await show(setup, clock: clock)

    await clock.waitForSleep(.seconds(15))
    clock.advance(by: .seconds(15))
    await awaitObserved { setup.presentation == .dismissed }

    #expect(setup.revealed(.server) == .running)
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
  }

  @Test("Skips steps that run past their time limits, revealing them in order")
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

    clock.advance(by: .milliseconds(4_500))
    await awaitObserved { setup.revealed(.harnesses) == .skipped }
    #expect(setup.revealed(.projects) == .running)

    clock.advance(by: .seconds(1))
    await awaitObserved { setup.outcomes[.models] == .skipped }
    #expect(setup.revealed(.models) == .running)

    clock.advance(by: .seconds(4))
    await awaitObserved { setup.isComplete }
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .skipped, .skipped, .skipped])
    #expect(setup.revealedHarnessNames.isEmpty)
    #expect(setup.revealedProjectCount == 0)

    await clock.waitForSleep(.milliseconds(400))
    clock.advance(by: .milliseconds(400))
    await running.value
    #expect(setup.presentation == .dismissed)
  }

  @Test("Holds a finished step and its detail until every step above it is done")
  func revealsDetailsInOrder() async {
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: TestClock())
    let running = Task { await setup.run() }

    work.projects.resolve(6)
    await awaitObserved { setup.outcomes[.projects] == .done && setup.outcomes[.models] == .done }
    #expect(setup.revealed(.models) == .running)
    #expect(setup.revealedProjectCount == 0)

    work.harnesses.resolve(["Claude Code", "Codex"])
    await running.value
    #expect(setup.revealedHarnessNames == ["Claude Code", "Codex"])
    #expect(setup.revealedProjectCount == 6)
    #expect(setup.revealed(.models) == .done)
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
    work.projects.resolve(3)
    work.models.resolve(())
    return work
  }

  private func show(_ setup: FirstLaunchSetup, clock: TestClock) async {
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await awaitObserved { setup.presentation == .visible }
  }
}
