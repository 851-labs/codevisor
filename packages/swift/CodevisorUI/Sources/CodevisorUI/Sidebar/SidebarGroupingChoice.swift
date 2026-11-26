import CodevisorCore
import SwiftUI

@MainActor
public struct SidebarGroupingChoice {
  private let machineCount: AccountMachineCount
  private let preferences: ClientPreferences

  public init(environment: AppEnvironment, preferences: ClientPreferences = .shared) {
    self.init(machineCount: environment.accountMachineCount, preferences: preferences)
  }

  init(machineCount: AccountMachineCount, preferences: ClientPreferences) {
    self.machineCount = machineCount
    self.preferences = preferences
  }

  public var effective: SidebarGrouping {
    saved ?? Self.automatic(machineCount: machineCount.lastKnown)
  }

  public var selection: Binding<SidebarGrouping> {
    Binding(get: { effective }, set: save)
  }

  public func isSelected(_ grouping: SidebarGrouping) -> Binding<Bool> {
    Binding(get: { effective == grouping }, set: { _ in save(grouping) })
  }

  public func save(_ grouping: SidebarGrouping) {
    preferences.set(grouping, forKey: SidebarGrouping.preferenceKey)
  }

  static func automatic(machineCount: Int) -> SidebarGrouping {
    machineCount >= 2 ? .machine : .flat
  }

  private var saved: SidebarGrouping? {
    guard preferences.hasValue(forKey: SidebarGrouping.preferenceKey) else { return nil }
    return preferences.value(forKey: SidebarGrouping.preferenceKey, default: SidebarGrouping.flat)
  }
}
