import CodevisorClient
import Foundation

public struct RestoringWorkspace: Equatable, Sendable {
  public let sandboxId: String
  public let vendorId: String
  public let sandboxMachineId: String?

  public init(sandboxId: String, vendorId: String, sandboxMachineId: String?) {
    self.sandboxId = sandboxId
    self.vendorId = vendorId
    self.sandboxMachineId = sandboxMachineId
  }

  static func byWorkspace(_ sandboxes: [ServerSandbox]) -> [UUID: RestoringWorkspace] {
    var restoring: [UUID: RestoringWorkspace] = [:]
    for sandbox in sandboxes where sandbox.restoresWorkspace == true && sandbox.state != "archived" {
      guard let workspaceId = sandbox.workspaceId.flatMap(UUID.init(uuidString:)) else { continue }
      restoring[workspaceId] = RestoringWorkspace(
        sandboxId: sandbox.id, vendorId: sandbox.vendor,
        sandboxMachineId: sandbox.deviceId.map { CodevisorMachine.cloudIdPrefix + $0 })
    }
    return restoring
  }
}
