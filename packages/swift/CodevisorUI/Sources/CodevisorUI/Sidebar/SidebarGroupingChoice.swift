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
    saved ?? Self.automatic(machineCount: machines.chatMachines.count)
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
    preferences.valueIfPresent(forKey: SidebarGrouping.preferenceKey)
  }
}
