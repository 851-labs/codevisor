import CodevisorCore
import Foundation

public enum PluginSignInRoute {
  case chatMachine
  case localMac(any CodevisorServerClienting)
  case unavailable

  @MainActor
  public static func forChat(on machineId: String, machines: MachineController) -> PluginSignInRoute {
    forChat(on: machineId, statusByMachineId: machines.statusByMachineId) {
      machines.client(for: CodevisorMachine.local.id)
    }
  }

  static func forChat(
    on machineId: String,
    statusByMachineId: [String: MachineStatus],
    localMac: () -> any CodevisorServerClienting
  ) -> PluginSignInRoute {
    if codevisorMachineIsThisMac(machineId, statusByMachineId: statusByMachineId) { return .chatMachine }
    if relaysSignInThroughCloud(machineId, statusByMachineId: statusByMachineId) { return .chatMachine }
    #if os(macOS)
      return .localMac(localMac())
    #else
      return .unavailable
    #endif
  }

  private static func relaysSignInThroughCloud(
    _ machineId: String,
    statusByMachineId: [String: MachineStatus]
  ) -> Bool {
    CodevisorMachine.cloudDeviceId(forMachineId: machineId) != nil || statusByMachineId[machineId]?.cloudDeviceId != nil
  }
}

enum PluginSignInError: LocalizedError {
  case needsMac(plugin: String)
  case notOnThisMac(plugin: String)

  var errorDescription: String? {
    switch self {
    case let .needsMac(plugin):
      "Sign in to \(plugin) from Codevisor on your Mac. The sign-in then works on your other machines too."
    case let .notOnThisMac(plugin):
      "\(plugin) isn't on this Mac. Turn it on here to sign in, and the sign-in reaches your other machines too."
    }
  }
}

extension ServerMcpServer {
  func isSamePlugin(as other: ServerMcpServer) -> Bool {
    if let catalogId, catalogId == other.catalogId { return true }
    return name == other.name
  }
}
