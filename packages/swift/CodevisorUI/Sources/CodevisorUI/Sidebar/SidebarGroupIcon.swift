import CodevisorCore
import SwiftUI

public enum SidebarGroupIcon: Equatable, Sendable {
  case system(String)
  case sandboxVendor(String)

  @MainActor
  public static func machine(_ serverId: String, in machines: MachineController) -> Self {
    if let profile = machines.sandboxProfile(forMachineId: serverId) { return .sandboxVendor(profile.vendor) }
    return .system(machines.machine(for: serverId)?.icon.systemImage ?? "questionmark.circle")
  }

  public var image: Image {
    switch self {
    case let .system(name): Image(systemName: name)
    case let .sandboxVendor(vendor): CodevisorSymbol.sandboxVendor(vendor)
    }
  }
}
