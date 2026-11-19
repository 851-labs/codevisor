import CodevisorCore
import Foundation

@MainActor
public final class SidebarMachineGroupingDefault {
  public enum Progress: String, Codable, Sendable {
    case oneMachine
    case settled
  }

  enum Step: Equatable {
    case awaitSecondMachine
    case groupByMachine
    case settle
    case settleUnlessAnotherDeviceDecided
  }

  enum Decision: Equatable {
    case apply(Step)
    case stop
  }

  enum FallbackRank {
    static let oneMachine = 0
    static let machineGrouping = 0
    static let settled = 1
  }

  nonisolated public static let preferenceKey = "sidebar.machineGroupingDefault"

  private weak var environment: AppEnvironment?
  private let preferences: ClientPreferences

  public init(environment: AppEnvironment, preferences: ClientPreferences = .shared) {
    self.environment = environment
    self.preferences = preferences
  }

  @discardableResult
  public static func start(environment: AppEnvironment) -> Task<Void, Never> {
    let watcher = SidebarMachineGroupingDefault(environment: environment)
    let task = Task { await watcher.run() }
    environment.cancelOnTeardown(task)
    return task
  }

  func run() async {
    var applied: Step?
    while case .apply? = await ObservedState.first(nextDecision(waitingAfter: applied)) {
      applied = applyNextStep()
    }
  }

  private func nextDecision(waitingAfter applied: Step?) -> () -> Decision? {
    var isFirstLook = true
    return {
      defer { isFirstLook = false }
      guard self.progress != .settled, self.environment != nil else { return .stop }
      guard let step = self.nextStep(), !(isFirstLook && step == applied) else { return nil }
      return .apply(step)
    }
  }

  @discardableResult
  func applyNextStep() -> Step? {
    guard let step = nextStep() else { return nil }
    apply(step)
    return step
  }

  func nextStep() -> Step? {
    let progress = progress
    guard progress != .settled, let environment else { return nil }
    guard environment.hasClientPreferencesFromReachableMachines else { return nil }
    guard let machineCount = environment.machines.accountMachineCount else { return nil }
    return Self.step(progress: progress, groupingIsChosen: groupingIsChosen, machineCount: machineCount)
  }

  static func step(progress: Progress?, groupingIsChosen: Bool, machineCount: Int) -> Step? {
    guard progress != .settled, machineCount > 0 else { return nil }
    if groupingIsChosen { return .settle }
    if machineCount == 1 { return progress == nil ? .awaitSecondMachine : nil }
    return progress == .oneMachine ? .groupByMachine : .settleUnlessAnotherDeviceDecided
  }

  private func apply(_ step: Step) {
    switch step {
    case .awaitSecondMachine:
      fallback(Progress.oneMachine, forKey: Self.preferenceKey, rank: FallbackRank.oneMachine)
    case .groupByMachine:
      fallback(SidebarGrouping.machine, forKey: SidebarGrouping.preferenceKey, rank: FallbackRank.machineGrouping)
      preferences.set(Progress.settled, forKey: Self.preferenceKey)
    case .settle:
      preferences.set(Progress.settled, forKey: Self.preferenceKey)
    case .settleUnlessAnotherDeviceDecided:
      fallback(Progress.settled, forKey: Self.preferenceKey, rank: FallbackRank.settled)
    }
  }

  private func fallback<Value: Codable>(_ value: Value, forKey key: String, rank: Int) {
    environment?.setClientPreferenceFallback(value, forKey: key, rank: rank)
  }

  private var progress: Progress? {
    preferences.valueIfPresent(forKey: Self.preferenceKey, as: Progress.self)
  }

  private var groupingIsChosen: Bool {
    preferences.valueIfPresent(forKey: SidebarGrouping.preferenceKey, as: SidebarGrouping.self) != nil
  }
}
