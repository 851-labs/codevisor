import Observation

@MainActor
@Observable
public final class FirstLaunchSetup {
  public private(set) var presentation: FirstLaunchPresentation = .waiting
  public private(set) var wasShown = false
  private(set) var outcomes: [FirstLaunchStep: FirstLaunchStepOutcome] = [:]
  private var harnessNames: [String] = []
  private var addedProjects = 0

  @ObservationIgnored private let work: any FirstLaunchSetupWork
  @ObservationIgnored private let timing: FirstLaunchSetupTiming
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored private let elapsed: @Sendable () -> Duration
  @ObservationIgnored private var settledWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    work: any FirstLaunchSetupWork,
    timing: FirstLaunchSetupTiming = .standard,
    clock: some Clock<Duration> & Sendable = ContinuousClock()
  ) {
    self.work = work
    self.timing = timing
    sleep = { try await clock.sleep(for: $0) }
    let start = clock.now
    elapsed = { start.duration(to: clock.now) }
  }

  public func revealed(_ step: FirstLaunchStep) -> FirstLaunchStepOutcome {
    FirstLaunchReveal.revealed(outcomes)[step, default: .pending]
  }

  public var isComplete: Bool {
    FirstLaunchStep.allCases.allSatisfy { revealed($0).isComplete }
  }

  public func detailCandidates(for step: FirstLaunchStep) -> [String] {
    switch step {
    case .harnesses: FirstLaunchDetail.candidates(harnesses: revealedHarnessNames)
    case .projects: FirstLaunchDetail.candidates(projects: revealedProjectCount)
    case .server, .models: []
    }
  }

  public var revealedHarnessNames: [String] {
    revealed(.harnesses) == .done ? harnessNames : []
  }

  public var revealedProjectCount: Int {
    revealed(.projects) == .done ? addedProjects : 0
  }

  public func run() async {
    async let steps: Void = performSteps()
    await present()
    await steps
  }

  private var isSettled: Bool {
    isComplete || presentation == .handedOff
  }

  private func present() async {
    if await settles(within: timing.skipWithin) || presentation == .handedOff {
      finishPresentation()
      return
    }

    let shownAt = show()
    guard await settles(within: timing.maximumVisible), presentation != .handedOff else {
      finishPresentation()
      return
    }

    try? await sleep(remainingVisibleTime(since: shownAt))
    finishPresentation()
  }

  private func remainingVisibleTime(since shownAt: Duration) -> Duration {
    max(timing.settle, shownAt + timing.minimumVisible - elapsed())
  }

  private func show() -> Duration {
    presentation = .visible
    wasShown = true
    return elapsed()
  }

  private func finishPresentation() {
    guard presentation != .handedOff else { return }
    presentation = .dismissed
  }

  private func settles(within limit: Duration) async -> Bool {
    await FirstLaunchRace.first([
      { @MainActor in
        await self.untilSettled(); return true
      },
      { [sleep] in
        try? await sleep(limit)
        return false
      },
    ])
  }

  private func untilSettled() async {
    guard !isSettled else { return }
    await withCheckedContinuation { settledWaiters.append($0) }
  }

  private func performSteps() async {
    set(.server, .running)
    guard await work.startServer() == .ready else {
      set(.server, .skipped)
      handOff()
      return
    }

    set(.server, .done)
    async let harnesses: Void = runStep(.harnesses, within: timing.harnessesTimeout) { [work] in
      try await work.findHarnesses()
    } record: {
      self.harnessNames = $0
    }
    async let projects: Void = runStep(.projects, within: timing.projectsTimeout) { [work] in
      try await work.addRecentProjects()
    } record: {
      self.addedProjects = $0
    }
    async let models: Void = runStep(.models, within: timing.modelsTimeout) { [work] in
      try await work.loadModels()
    } record: { _ in
    }
    _ = await (harnesses, projects, models)
  }

  private func runStep<Value: Sendable>(
    _ step: FirstLaunchStep,
    within limit: Duration,
    operation: @escaping @MainActor @Sendable () async throws -> Value,
    record: @MainActor (Value) -> Void
  ) async {
    set(step, .running)
    guard let value = await finishes(within: limit, operation) else {
      set(step, .skipped)
      return
    }

    record(value)
    set(step, .done)
  }

  private func finishes<Value: Sendable>(
    within limit: Duration,
    _ operation: @escaping @MainActor @Sendable () async throws -> Value
  ) async -> Value? {
    await FirstLaunchRace.first([
      { @MainActor in try? await operation() },
      { [sleep] in
        try? await sleep(limit)
        return nil
      },
    ])
  }

  private func handOff() {
    presentation = .handedOff
    resumeSettledWaiters()
  }

  private func set(_ step: FirstLaunchStep, _ outcome: FirstLaunchStepOutcome) {
    outcomes[step] = outcome
    resumeSettledWaiters()
  }

  private func resumeSettledWaiters() {
    guard isSettled else { return }
    let waiters = settledWaiters
    settledWaiters = []
    waiters.forEach { $0.resume() }
  }
}
