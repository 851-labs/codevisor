import CodevisorClient
import Foundation

public struct SandboxMachine: Sendable {
  public let name: String
  public let client: any CodevisorServerClienting

  public init(name: String, client: any CodevisorServerClienting) {
    self.name = name
    self.client = client
  }

  @MainActor
  public static func reachable(in machines: MachineController) -> [SandboxMachine] {
    machines.chatMachines
      .filter { machines.availability(for: $0.id) == .ready }
      .map { SandboxMachine(name: $0.name, client: machines.client(for: $0.id)) }
  }

  @MainActor
  public static func offlineNames(in machines: MachineController) -> [String] {
    machines.chatMachines
      .filter { machines.availability(for: $0.id) != .ready }
      .map(\.name)
  }
}
