import Foundation
import Observation

@MainActor
@Observable
public final class AccountMachineCount {
  public static let preferenceKey = "machines.lastKnownAccountMachineCount"

  public private(set) var lastKnown: Int
  private let machines: MachineController
  private let preferences: ClientPreferences
  @ObservationIgnored private var isFollowing = false
  @ObservationIgnored private var observation: UInt64 = 0

  public init(machines: MachineController, preferences: ClientPreferences) {
    self.machines = machines
    self.preferences = preferences
    lastKnown = preferences.value(forKey: Self.preferenceKey, default: 0)
  }

  public func follow() {
    guard !isFollowing else { return }
    isFollowing = true
    update()
  }

  func update() {
    observation &+= 1
    let current = withObservationTracking {
      machines.accountMachineCount
    } onChange: { [weak self, observation] in
      Task { @MainActor in self?.observedChange(during: observation) }
    }
    guard let current, current != lastKnown else { return }

    lastKnown = current
    preferences.set(current, forKey: Self.preferenceKey)
  }

  private func observedChange(during observed: UInt64) {
    guard observed == observation else { return }
    update()
  }
}
