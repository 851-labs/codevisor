import Observation

@MainActor
@Observable
public final class FirstLaunchSetup {
  public private(set) var presentation: FirstLaunchPresentation = .visible
  public private(set) var canGetStarted = false
  private(set) var outcomes: [FirstLaunchStep: FirstLaunchStepOutcome] = [:]
  private var foundNames: [FirstLaunchStep: [String]] = [:]
  private var visibleCounts: [FirstLaunchStep: Int] = [:]
  private var isNewInstall: Bool?
  private var isWaitingOnUser = false
  private var userWaits = 0

  @ObservationIgnored private let timing: FirstLaunchSetupTiming
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored private var changeWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    timing: FirstLaunchSetupTiming = .standard,
    clock: some Clock<Duration> & Sendable = ContinuousClock()
  ) {
    self.timing = timing
    sleep = { try await clock.sleep(for: $0) }
  }

  public func revealed(_ step: FirstLaunchStep) -> FirstLaunchStepOutcome {
    FirstLaunchReveal.revealed(displayedOutcomes)[step, default: .pending]
  }

  public var isComplete: Bool {
    FirstLaunchStep.allCases.allSatisfy { revealed($0).isComplete }
  }

  public func detailCandidates(for step: FirstLaunchStep) -> [String] {
    guard revealed(step) != .skipped else { return [] }
    return FirstLaunchDetail.candidates(for: step, names: visibleNames(for: step))
  }

  public func visibleNames(for step: FirstLaunchStep) -> [String] {
    Array(foundNames[step, default: []].prefix(visibleCount(step)))
  }

  public func getStarted() {
    guard canGetStarted, presentation == .visible else { return }
    presentation = .dismissed
    changed()
  }

  public func localDataFailed() {
    set(.server, .failed)
  }

  public func retryLocalData() {
    set(.server, .running)
  }

  public func run(_ work: any FirstLaunchSetupWork) async {
    async let steps: Void = performSteps(work)
    async let harnesses: Void = revealNames(of: .harnesses)
    async let projects: Void = revealNames(of: .projects)
    await present()
    _ = await (steps, harnesses, projects)
  }

  private var displayedOutcomes: [FirstLaunchStep: FirstLaunchStepOutcome] {
    var displayed = outcomes
    for step in [FirstLaunchStep.harnesses, .projects] where outcomes[step] == .done && isCounting(step) {
      displayed[step] = .running
    }
    return displayed
  }

  private var isSettled: Bool {
    isComplete || presentation == .handedOff || isNewInstall == false
  }

  private func present() async {
    guard await confirmsNewInstall() else { return }

    guard await settles(within: timing.maximumVisible) else {
      offerGetStarted()
      return
    }
    guard presentation != .handedOff else { return }

    try? await sleep(timing.settle)
    offerGetStarted()
  }

  private func offerGetStarted() {
    guard presentation == .visible else { return }
    canGetStarted = true
  }

  private func confirmsNewInstall() async -> Bool {
    if !hasServerAnswer {
      let answered = await becomes(within: timing.serverAnswerTimeout) { self.hasServerAnswer }
      if !answered { handOff() }
    }
    guard presentation == .visible else { return false }
    guard isNewInstall == true else {
      presentation = .notNeeded
      changed()
      return false
    }
    return true
  }

  private var hasServerAnswer: Bool {
    isNewInstall != nil || presentation != .visible
  }

  private func elapses(_ limit: Duration) async {
    while !Task.isCancelled {
      let waitsBefore = userWaits
      try? await sleep(limit)
      guard isWaitingOnUser || userWaits != waitsBefore else { return }

      await waitUntil { !self.isWaitingOnUser }
    }
  }

  private func setWaitingOnUser(_ isWaiting: Bool) {
    guard isWaitingOnUser != isWaiting else { return }

    isWaitingOnUser = isWaiting
    if isWaiting { userWaits += 1 }
    changed()
  }

  private func settles(within limit: Duration) async -> Bool {
    await becomes(within: limit) { self.isSettled }
  }

  private func becomes(within limit: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    await FirstLaunchRace.first([
      { @MainActor in
        await self.waitUntil(condition)
        return true
      },
      { @MainActor in
        await self.elapses(limit)
        return false
      },
    ])
  }

  private func performSteps(_ work: any FirstLaunchSetupWork) async {
    set(.server, .running)
    let start = await work.startServer { self.setWaitingOnUser($0) }
    setWaitingOnUser(false)
    guard start == .ready else {
      set(.server, .skipped)
      handOff()
      return
    }

    isNewInstall = await askIfNewInstall(work)
    changed()
    guard isNewInstall == true, presentation == .visible else { return }

    set(.server, .done)
    async let harnesses: Void = runStep(.harnesses, within: timing.harnessesTimeout) { [work] in
      try await work.findHarnesses()
    } record: {
      self.record($0, for: .harnesses)
    }
    async let projects: Void = runStep(.projects, within: timing.projectsTimeout) { [work] in
      try await work.addRecentProjects {
        self.record($0, for: .projects)
      } waitingOnUser: {
        self.setWaitingOnUser($0)
      }
    } record: {
      self.record($0, for: .projects)
    }
    async let models: Void = runStep(.models, within: timing.modelsTimeout) { [work] in
      try await work.loadModels()
    } record: { _ in
    }
    _ = await (harnesses, projects, models)
  }

  private func askIfNewInstall(_ work: any FirstLaunchSetupWork) async -> Bool? {
    while presentation == .visible, !Task.isCancelled {
      if let answer = try? await work.isNewInstall() { return answer }
      try? await sleep(timing.serverAnswerRetry)
    }
    return nil
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
      { @MainActor in
        await self.elapses(limit)
        return nil
      },
    ])
  }

  private func revealNames(of step: FirstLaunchStep) async {
    var catchUpPace: Duration?
    while !isRevealFinished(step), !Task.isCancelled {
      guard mayReveal(step) else {
        await waitUntil { self.isRevealFinished(step) || self.mayReveal(step) }
        continue
      }
      guard presentation == .visible else {
        revealAll(step)
        continue
      }

      if outcomes[step] == .done, catchUpPace == nil {
        catchUpPace = min(timing.revealPace, timing.catchUp / max(1, target(step) - visibleCount(step)))
      }
      try? await sleep(catchUpPace ?? timing.revealPace)
      revealOneMore(step)
    }
  }

  private func isRevealFinished(_ step: FirstLaunchStep) -> Bool {
    presentation == .handedOff || isNewInstall == false || outcomes[step] == .skipped
      || (outcomes[step] == .done && !isCounting(step))
  }

  private func mayReveal(_ step: FirstLaunchStep) -> Bool {
    isCounting(step) && revealed(step) != .pending
  }

  private func isCounting(_ step: FirstLaunchStep) -> Bool {
    visibleCount(step) < target(step)
  }

  private func target(_ step: FirstLaunchStep) -> Int {
    foundNames[step, default: []].count
  }

  private func visibleCount(_ step: FirstLaunchStep) -> Int {
    visibleCounts[step, default: 0]
  }

  private func revealAll(_ step: FirstLaunchStep) {
    setVisibleCount(target(step), for: step)
  }

  private func revealOneMore(_ step: FirstLaunchStep) {
    setVisibleCount(min(target(step), visibleCount(step) + 1), for: step)
  }

  private func setVisibleCount(_ count: Int, for step: FirstLaunchStep) {
    visibleCounts[step] = count
    changed()
  }

  private func record(_ names: [String], for step: FirstLaunchStep) {
    guard names.count > target(step) else { return }
    foundNames[step] = names
    changed()
  }

  private func handOff() {
    presentation = .handedOff
    changed()
  }

  private func set(_ step: FirstLaunchStep, _ outcome: FirstLaunchStepOutcome) {
    outcomes[step] = outcome
    changed()
  }

  func waitUntil(_ condition: @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled {
      await withCheckedContinuation { changeWaiters.append($0) }
    }
  }

  func changed() {
    let waiters = changeWaiters
    changeWaiters = []
    waiters.forEach { $0.resume() }
  }
}
