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
    return Task { await watcher.run() }
  }

  func run() async {
    var applied: Step?
    while await ObservedState.first(nextStep(waitingAfter: applied)) != nil {
      applied = applyNextStep()
    }
  }

  private func nextStep(waitingAfter applied: Step?) -> () -> Step? {
    var isFirstLook = true
    return {
      defer { isFirstLook = false }
      let step = self.nextStep()
      return isFirstLook && step == applied ? nil : step
    }
  }

  @discardableResult
  func applyNextStep() -> Step? {
    guard let step = nextStep() else { return nil }
    apply(step)
    return step
  }

  func nextStep() -> Step? {
    guard let environment, environment.hasSyncedClientPreferences else { return nil }
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
      preferences.set(Progress.oneMachine, forKey: Self.preferenceKey)
    case .groupByMachine:
      preferences.set(SidebarGrouping.machine, forKey: SidebarGrouping.preferenceKey)
      preferences.set(Progress.settled, forKey: Self.preferenceKey)
    case .settle:
      preferences.set(Progress.settled, forKey: Self.preferenceKey)
    case .settleUnlessAnotherDeviceDecided:
      environment?.setClientPreferenceFallback(Progress.settled, forKey: Self.preferenceKey)
    }
  }

  private var progress: Progress? {
    preferences.valueIfPresent(forKey: Self.preferenceKey, as: Progress.self)
  }

  private var groupingIsChosen: Bool {
    preferences.valueIfPresent(forKey: SidebarGrouping.preferenceKey, as: SidebarGrouping.self) != nil
  }
}
