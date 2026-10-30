import CodevisorClient
import Foundation

public enum SandboxPower: String, Equatable, Sendable {
  case paused
  case waking
}

public struct SandboxMachinePower: Equatable, Sendable {
  public let sandboxId: String
  public let power: SandboxPower

  public init(sandboxId: String, power: SandboxPower) {
    self.sandboxId = sandboxId
    self.power = power
  }

  static func byDevice(_ sandboxes: [ServerSandbox]) -> [String: SandboxMachinePower] {
    var powers: [String: SandboxMachinePower] = [:]
    for sandbox in sandboxes {
      guard let deviceId = sandbox.deviceId, let power = sandbox.power.flatMap(SandboxPower.init) else { continue }
      powers[deviceId] = SandboxMachinePower(sandboxId: sandbox.id, power: power)
    }
    return powers
  }
}
