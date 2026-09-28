import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("MachineController relay routing")
struct MachineControllerRelayRoutingTests {
  @Test("Pane recovery follows the loopback bridge and exposes connection revisions")
  func paneRecoveryRouting() async throws {
    let (controller, _, provider) = makeController()
    let cloud = makeCloudMachine(deviceId: "pane-recovery")
    provider.cloudMachines = [cloud]
    let machineId = "cloud:\(cloud.deviceId)"
    #expect(await controller.recoverHTTPConnection(forMachineId: "local") == CodevisorMachine.local.baseURL)
    let relayed = controller.httpConnectionState(forMachineId: machineId)
    #expect(relayed != controller.httpConnectionState(forMachineId: "local"))
    let bridge = URL(string: "http://127.0.0.1:54322")!
    provider.loopbackURLsByDeviceId[cloud.deviceId] = bridge
    #expect(await controller.recoverHTTPConnection(forMachineId: machineId) == bridge)
    #expect(provider.loopbackRecoveryRequests == [cloud.deviceId])
    provider.loopbackRevisionsByDeviceId[cloud.deviceId] = 1
    #expect(controller.httpConnectionState(forMachineId: machineId) != relayed)
    provider.loopbackRecoverySucceeds = false
    #expect(
      await controller.recoverHTTPConnection(forMachineId: machineId) == nil,
      "A failed probe must not return an old cached address")
  }
}
