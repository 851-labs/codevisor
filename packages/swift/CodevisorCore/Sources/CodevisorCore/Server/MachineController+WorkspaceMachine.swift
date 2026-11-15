import CodevisorClient
import Foundation

public enum WorkspaceMachine: Equatable, Sendable {
  case listed(CodevisorMachine)
  case removed
  case unknown
}

extension MachineController {
  public func workspaceMachine(for machineId: String) -> WorkspaceMachine {
    if let machine = machine(for: machineId) { return .listed(machine) }
    guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: machineId),
      let cloudProvider, cloudProvider.isCloudSignedIn, cloudProvider.isCloudRosterVerified,
      !cloudProvider.cloudMachines.contains(where: { $0.deviceId == deviceId })
    else { return .unknown }

    return .removed
  }
}
