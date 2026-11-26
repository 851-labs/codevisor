import Foundation
import Observation

@MainActor
@Observable
public final class AccountMachineCount {
  public static let preferenceKey = "machines.lastKnownAccountMachineCount"

  public private(set) var lastKnown: Int
  private let machines: MachineController
  private let preferences: ClientPreferences

  public init(machines: MachineController, preferences: ClientPreferences) {
    self.machines = machines
    self.preferences = preferences
    lastKnown = preferences.value(forKey: Self.preferenceKey, default: 0)
  }

  public func follow() {
    let current = withObservationTracking {
      machines.accountMachineCount
    } onChange: { [weak self] in
      Task { @MainActor in self?.follow() }
    }
    guard let current, current != lastKnown else { return }

    lastKnown = current
    preferences.set(current, forKey: Self.preferenceKey)
  }
}
