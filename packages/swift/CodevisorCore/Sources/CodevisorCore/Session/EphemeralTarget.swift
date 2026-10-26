import Foundation

public struct EphemeralTarget: Equatable, Hashable, Sendable, Identifiable {
  public let providerId: String
  public let machineNoun: String
  public let systemImage: String

  public var id: String { providerId }
  public var pickerTitle: String { "New \(machineNoun)" }

  public static func provider(_ providerId: String) -> EphemeralTarget {
    switch providerId {
    case "tart": EphemeralTarget(providerId: providerId, machineNoun: "Tart VM", systemImage: "desktopcomputer")
    case "e2b": EphemeralTarget(providerId: providerId, machineNoun: "E2B Sandbox", systemImage: "shippingbox")
    case "modal": EphemeralTarget(providerId: providerId, machineNoun: "Modal Sandbox", systemImage: "cube")
    default: EphemeralTarget(providerId: providerId, machineNoun: "\(providerId) machine", systemImage: "cloud")
    }
  }
}
