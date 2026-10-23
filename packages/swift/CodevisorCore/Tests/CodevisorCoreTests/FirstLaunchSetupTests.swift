import CodevisorTestSupport
import Testing

@testable import CodevisorCore

@MainActor
@Suite("First-launch setup screen")
struct FirstLaunchSetupTests {
  @Test("Never shows the screen when everything is ready within half a second")
  func skipsWhenReadyQuickly() async {
    let work = newInstall()
    work.harnesses.resolve(["Claude Code"])
    work.projects.resolve(["api", "web"])
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: TestClock())

    await setup.run()

    #expect(setup.presentation == .dismissed)
    #expect(!setup.wasShown)
    #expect(setup.detailCandidates(for: .projects) == ["api and web", "api +1", "2 projects"])
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
    timing.harnessesTimeout = .seconds(60)
    timing.projectsTimeout = .seconds(60)
    timing.modelsTimeout = .seconds(60)
    let setup = FirstLaunchSetup(work: work, timing: timing, clock: clock)
    let running = Task { await setup.run() }
    await show(setup, clock: clock)

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

  @Test("Hands a failed server start to the startup failure view without showing")
  func handsOffServerFailure() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    #expect(setup.presentation == .waiting)

    work.server.resolve(.failed)
    await running.value

    #expect(setup.presentation == .handedOff)
    #expect(!setup.wasShown)
    #expect(!setup.canGetStarted)
  }

  enum ServerAnswer: String, CaseIterable, Sendable {
    case notNewBeforeHalfASecond, notNewAfterHalfASecond, unreadable
  }

  @Test("Never shows when the server says this isn't a new install", arguments: ServerAnswer.allCases)
  func neverShowsOnExistingInstall(answer: ServerAnswer) async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    if answer == .notNewBeforeHalfASecond {
      work.newInstall.resolve(false)
    } else {
      await clock.waitForSleep(.milliseconds(500))
      clock.advance(by: .milliseconds(500))
      await clock.waitForSleep(.seconds(15))
      #expect(setup.presentation == .waiting)
      if answer == .unreadable { work.newInstall.fail() } else { work.newInstall.resolve(false) }
    }
    await running.value

    #expect(setup.presentation == .dismissed)
    #expect(!setup.wasShown)
    #expect(FirstLaunchStep.allCases.map { setup.outcomes[$0] } == [.running, nil, nil, nil])
  }

  @Test("Shows a new install only once the server confirms it")
  func waitsForServerBeforeShowing() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    work.server.resolve(.ready)
    work.harnesses.resolve([])
    work.projects.resolve([])
    work.models.resolve(())
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await clock.waitForSleep(.seconds(15))
    #expect(setup.presentation == .waiting)

    work.newInstall.resolve(true)
    await awaitObserved { setup.presentation == .visible }
    #expect(setup.wasShown)
    await clock.waitForSleep(.milliseconds(400))
    clock.advance(by: .milliseconds(400))
    await running.value
    #expect(setup.canGetStarted)
  }

  @Test("Gives up without showing when the server never answers")
  func givesUpWithoutServer() async {
    let clock = TestClock()
    let work = FirstLaunchFakeWork()
    let setup = FirstLaunchSetup(work: work, clock: clock)
    let running = Task { await setup.run() }
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await clock.waitForSleep(.seconds(15))
    clock.advance(by: .seconds(15))

    await awaitObserved { setup.presentation == .dismissed }
    #expect(!setup.wasShown)
    running.cancel()
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
    await show(setup, clock: clock)
    #expect(FirstLaunchStep.allCases.map(setup.revealed) == [.done, .running, .pending, .pending])

    clock.advance(by: .milliseconds(4_500))
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
    let setup = FirstLaunchSetup(work: work, clock: TestClock())
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
    await show(setup, clock: clock)

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
    let setup = FirstLaunchSetup(work: work, clock: TestClock())

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

  private func show(_ setup: FirstLaunchSetup, clock: TestClock) async {
    await clock.waitForSleep(.milliseconds(500))
    await awaitObserved { setup.outcomes[.server] == .done }
    clock.advance(by: .milliseconds(500))
    await awaitObserved { setup.presentation == .visible }
  }
}
