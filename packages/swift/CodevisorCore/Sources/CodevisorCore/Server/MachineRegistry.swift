import Foundation

public struct MachineRegistry: Sendable, Codable, Equatable {
  public var selectedMachineId: String

  public init(selectedMachineId: String = CodevisorMachine.local.id) {
    self.selectedMachineId = selectedMachineId
  }

  func normalized() -> MachineRegistry {
    let keepsSelection =
      selectedMachineId == CodevisorMachine.local.id
      || selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix)
    return MachineRegistry(
      selectedMachineId: keepsSelection ? selectedMachineId : CodevisorMachine.local.id)
  }
}
