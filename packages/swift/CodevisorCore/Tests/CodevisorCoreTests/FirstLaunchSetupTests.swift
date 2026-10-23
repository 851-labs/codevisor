import CodevisorTestSupport
import Testing

@testable import CodevisorCore

@MainActor
@Suite("First-launch setup screen")
struct FirstLaunchSetupTests {
  @Test("Shows Starting Codevisor from the first frame, before the server answers")
  func showsBeforeServerAnswers() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    #expect(setup.presentation == .visible)
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.running, .pending, .pending, .pending])

    let running = Task { await setup.run() }
    await clock.waitForSleep(.seconds(15))
    #expect(setup.presentation == .visible)
    #expect(setup.revealed(.server) == .running)

    work.server.resolve(.failed)
    await running.value
  }

  @Test("Carries on once the server confirms a new install")
  func carriesOnForNewInstall() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.harnesses.resolve([])
    work.projects.resolve([])
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await clock.waitForSleep(.seconds(15))
    #expect(setup.revealed(.server) == .running)

    work.newInstall.resolve(true)
    await awaitObserved { setup.revealed(.server) == .done }
    await clock.waitForSleep(.milliseconds(400))
    clock.advance(by: .milliseconds(400))
    await running.value

    #expect(setup.presentation == .visible)
    #expect(setup.canGetStarted)
  }

  @Test("Leaves without Get Started when the server says this isn't a new install")
  func leavesForExistingInstall() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await clock.waitForSleep(.seconds(15))
    #expect(setup.presentation == .visible)

    work.newInstall.resolve(false)
    await running.value

    #expect(setup.presentation == .notNeeded)
    #expect(!setup.canGetStarted)
    #expect(FirstLaunchStep.allCases.map { setup.outcomes[$0] } == [.running, nil, nil, nil])
  }

  @Test("Hands off to the startup view when the server doesn't answer within fifteen seconds")
  func handsOffWithoutServerAnswer() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await clock.waitForSleep(.seconds(15))
    clock.advance(by: .seconds(15))

    await awaitObserved { setup.presentation == .handedOff }
    #expect(!setup.canGetStarted)
    running.cancel()
    await running.value
  }

  @Test("Keeps asking through unreadable answers, then hands off after fifteen seconds")
  func keepsAskingThroughErrors() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.newInstall.fail()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await clock.waitForSleep(.milliseconds(500), count: 2)
    #expect(setup.presentation == .visible)
    #expect(setup.revealed(.server) == .running)

    await clock.waitForSleep(.seconds(15))
    clock.advance(by: .seconds(15))
    await awaitObserved { setup.presentation == .handedOff }
    #expect(!setup.canGetStarted)
    running.cancel()
    await running.value
  }

  @Test("Hands a failed server start to the startup failure view")
  func handsOffServerFailure() async {
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: TestClock())
    let running = Task { await setup.run() }

    work.server.resolve(.failed)
    await running.value

    #expect(setup.presentation == .handedOff)
    #expect(!setup.canGetStarted)
  }

  @Test("Offers Get Started once the last check lands, and only dismisses when pressed")
  func offersGetStartedWhenDone() async {
    let clock = TestClock()
    let work = readyExceptHarnesses()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await confirmed(setup)
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
    #expect(setup.revealed(.projects) == .done)
    #expect(setup.detailCandidates(for: .projects).isEmpty)
    setup.getStarted()
    #expect(setup.presentation == .dismissed)
  }

  @Test("Offers Get Started at fifteen seconds while slow work keeps going")
  func offersGetStartedAtCap() async {
    let clock = TestClock()
    let work = newInstall()
    var timing = FirstLaunchSetupTiming.standard
    timing.serverAnswerTimeout = .seconds(20)
    timing.harnessesTimeout = .seconds(60)
    timing.projectsTimeout = .seconds(60)
    timing.modelsTimeout = .seconds(60)
    let setup = FirstLaunchSetup(work: work, timing: timing, clock: clock)
    let running = Task { await setup.run() }
    await confirmed(setup)

    await clock.waitForSleep(.seconds(15))
    clock.advance(by: .seconds(15))
    await awaitObserved { setup.canGetStarted }

    #expect(setup.revealed(.harnesses) == .running)
    setup.getStarted()
    #expect(setup.presentation == .dismissed)
    work.harnesses.resolve([])
    work.projects.resolve([])
    work.models.resolve(())
    await running.value
  }

  @Test("Skips steps that run past their time limits, keeping one spinner at a time")
  func skipsSlowSteps() async {
    let clock = TestClock()
    let work = newInstall()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    for limit in [Duration.seconds(5), .seconds(10), .seconds(12)] {
      await clock.waitForSleep(limit)
    }
    await confirmed(setup)
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .running, .pending, .pending])

    clock.advance(by: .seconds(5))
    await awaitObserved { setup.revealed(.harnesses) == .skipped }
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .skipped, .running, .pending])

    clock.advance(by: .seconds(5))
    await awaitObserved { setup.revealed(.projects) == .skipped }
    #expect(setup.revealed(.models) == .running)

    clock.advance(by: .seconds(2))
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
    let work = newInstall()
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, timing: .instant, clock: TestClock())
    let running = Task { await setup.run() }

    work.projects.resolve(["api", "web"])
    await awaitObserved { setup.outcomes[.projects] == .done && setup.outcomes[.models] == .done }
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .running, .pending, .pending])
    #expect(setup.detailCandidates(for: .projects).isEmpty)

    work.harnesses.resolve(["Claude Code", "Codex"])
    await running.value
    #expect(setup.visibleNames(for: .harnesses) == ["Claude Code", "Codex"])
    #expect(setup.visibleNames(for: .projects) == ["api", "web"])
    #expect(setup.revealed(.models) == .done)
  }

  @Test("Lists added projects one at a time from real progress, only once projects is the current step")
  func listsProjectsOneAtATime() async {
    let clock = TestClock()
    let work = newInstall()
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await confirmed(setup)

    work.reportProjectsAdded(["api", "web"])
    work.harnesses.resolve(["Codex"])
    await clock.waitForSleep(.milliseconds(140))
    #expect(setup.visibleNames(for: .projects).isEmpty)
    clock.advance(by: .milliseconds(140))
    await awaitObserved { setup.revealed(.harnesses) == .done }

    for count in 1...2 {
      await clock.waitForSleep(.milliseconds(140), count: count + 1)
      clock.advance(by: .milliseconds(140))
      await awaitObserved { setup.visibleNames(for: .projects).count == count }
    }
    #expect(setup.visibleNames(for: .projects) == ["api", "web"])
    #expect(setup.revealed(.projects) == .running)

    work.projects.resolve(["api", "web", "docs", "site"])
    await clock.waitForSleep(.milliseconds(140), count: 4)
    clock.advance(by: .milliseconds(140))
    await awaitObserved { setup.visibleNames(for: .projects) == ["api", "web", "docs"] }
    await clock.waitForSleep(.milliseconds(140), count: 5)
    clock.advance(by: .milliseconds(140))
    await awaitObserved { setup.revealed(.projects) == .done }
    #expect(
      setup.detailCandidates(for: .projects) == [
        "api, web, docs, and site", "api, web, docs +1", "api, web +2", "api +3", "4 projects",
      ])

    await clock.waitForSleep(.milliseconds(400))
    clock.advance(by: .milliseconds(400))
    await running.value
  }

  @Test("Treats a failed step as a skip")
  func skipsFailedStep() async {
    let work = newInstall()
    work.harnesses.resolve(["Codex"])
    work.projects.fail()
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, timing: .instant, clock: TestClock())

    await setup.run()

    #expect(setup.revealed(.projects) == .skipped)
    #expect(setup.revealed(.models) == .done)
  }

  private func newInstall() -> FirstLaunchFakeWork {
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.newInstall.resolve(true)
    return work
  }

  private func readyExceptHarnesses() -> FirstLaunchFakeWork {
    let work = newInstall()
    work.projects.resolve([])
    work.models.resolve(())
    return work
  }

  private func confirmed(_ setup: FirstLaunchSetup) async {
    await awaitObserved { setup.outcomes[.server] == .done }
  }
}

extension FirstLaunchSetupTiming {
  fileprivate static var instant: Self {
    var timing = Self.standard
    timing.revealPace = .zero
    timing.catchUp = .zero
    timing.settle = .zero
    return timing
  }
}
