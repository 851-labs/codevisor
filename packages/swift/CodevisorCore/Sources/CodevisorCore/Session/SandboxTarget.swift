import Foundation

public struct SandboxTarget: Equatable, Hashable, Sendable, Identifiable {
  public let providerId: String
  public let machineNoun: String
  public let systemImage: String

  public var id: String { providerId }
  public var pickerTitle: String { "New \(machineNoun)" }

  public static func provider(_ providerId: String) -> SandboxTarget {
    switch providerId {
    case "tart": SandboxTarget(providerId: providerId, machineNoun: "Tart VM", systemImage: "desktopcomputer")
    case "e2b": SandboxTarget(providerId: providerId, machineNoun: "E2B Sandbox", systemImage: "shippingbox")
    case "modal": SandboxTarget(providerId: providerId, machineNoun: "Modal Sandbox", systemImage: "cube")
    default: SandboxTarget(providerId: providerId, machineNoun: "\(providerId) machine", systemImage: "cloud")
    }
  }
}
