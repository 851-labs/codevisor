import CodevisorClient
import Foundation

@MainActor
public protocol CloudMachineProviding: AnyObject {
  var isCloudSignedIn: Bool { get }
  var cloudMachines: [CloudMachine] { get }
  var isCloudRosterVerified: Bool { get }
  func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig?
  func relayServerConfig(forDeviceId deviceId: String) -> CodevisorServerConfig?
  func loopbackBaseURL(for machine: CloudMachine) -> URL?
  func loopbackRevision(for machine: CloudMachine) -> UInt64
  func recoverLoopbackBridge(for machine: CloudMachine) async -> Bool
  func registerLocalMachineIfNeeded()
  func prepareAccountSync(on client: any CodevisorServerClienting, machineId: String) async -> Bool
  func tunnelMediaRoute(for machine: CloudMachine) async -> CloudTunnelMediaRoute?
  func adoptDirectMachine(using client: any CodevisorServerClienting, name: String) async throws -> String
}

public extension CloudMachineProviding {
  func relayServerConfig(forDeviceId deviceId: String) -> CodevisorServerConfig? { nil }
  func loopbackBaseURL(for machine: CloudMachine) -> URL? { nil }
  func loopbackRevision(for machine: CloudMachine) -> UInt64 { 0 }
  func recoverLoopbackBridge(for machine: CloudMachine) async -> Bool { false }
  func registerLocalMachineIfNeeded() {}
  func prepareAccountSync(on client: any CodevisorServerClienting, machineId: String) async -> Bool { false }
  func tunnelMediaRoute(for machine: CloudMachine) async -> CloudTunnelMediaRoute? { nil }
  func adoptDirectMachine(using _: any CodevisorServerClienting, name _: String) async throws -> String {
    throw CloudAccountClientError.missingToken
  }
}

extension CodevisorMachine {
  public static func cloud(from machine: CloudMachine) -> CodevisorMachine {
    CodevisorMachine(
      id: "\(cloudIdPrefix)\(machine.deviceId)",
      name: machine.name,
      baseURL: cloudPlaceholderBaseURL,
      kind: "cloud"
    )
  }
}
