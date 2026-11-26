import CodevisorCore
import SwiftUI

@MainActor
public struct SidebarGroupingChoice {
  private let machines: MachineController
  private let preferences: ClientPreferences

  public init(machines: MachineController, preferences: ClientPreferences = .shared) {
    self.machines = machines
    self.preferences = preferences
  }

  public var effective: SidebarGrouping {
    saved ?? Self.automatic(machineCount: machines.chatMachineCount)
  }

  public var selection: Binding<SidebarGrouping> {
    Binding(get: { effective }, set: save)
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
