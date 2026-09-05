import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("MachineController relay routing")
struct MachineControllerRelayRoutingTests {
  @Test("serverConfig(for:) follows a configured machine onto cloud fallback")
  func configuredServerConfigRouting() throws {
    let (controller, _, provider) = makeController()
    let remote = try controller.addRemote(host: "http://10.0.0.5:4152")
    let cloud = makeCloudMachine(deviceId: "configured-device")
    let loopback = URL(string: "http://127.0.0.1:54322")!
    provider.cloudMachines = [cloud]
    provider.loopbackURLsByDeviceId[cloud.deviceId] = loopback
    controller.adoptCloudLinkForTesting(machineId: remote.id, deviceId: cloud.deviceId)
    controller.connection(for: remote.id).status = MachineStatus(
      isReachable: true,
      label: "Remote — via Codevisor Cloud",
      cloudDeviceId: cloud.deviceId,
      route: .relay,
      serverId: "remote"
    )

    let config = controller.serverConfig(for: remote.id)

    #expect(config.baseURL == loopback)
    #expect(config.requestTransport != nil)
    #expect(config.webSocketTransport != nil)
    #expect(provider.configRequests.contains(cloud.deviceId))
  }

  @Test("effectiveHTTPBaseURL keeps a configured machine on its active direct route")
  func effectiveBaseURLDirectMachine() async throws {
    let (controller, _, provider) = makeController()
    let machine = try controller.addRemote(host: "http://10.0.0.5:4152")
    let cloud = makeCloudMachine(deviceId: "configured-direct")
    provider.cloudMachines = [cloud]
    provider.loopbackURLsByDeviceId[cloud.deviceId] = URL(
      string: "http://127.0.0.1:50504"
    )!
    controller.adoptCloudLinkForTesting(machineId: machine.id, deviceId: cloud.deviceId)
    controller.connection(for: machine.id).status = MachineStatus(
      isReachable: true,
      label: "Remote",
      cloudDeviceId: cloud.deviceId,
      route: .direct,
      serverId: "remote"
    )

    let url = await controller.effectiveHTTPBaseURL(forMachineId: machine.id)
    #expect(url == machine.baseURL)
  }

  @Test("effectiveHTTPBaseURL follows a configured machine onto its cloud bridge")
  func effectiveBaseURLConfiguredMachineRelayFallback() async throws {
    let (controller, _, provider) = makeController()
    let remote = try controller.addRemote(host: "http://10.0.0.5:4152")
    let cloud = makeCloudMachine(deviceId: "configured-relay")
    provider.cloudMachines = [cloud]
    controller.adoptCloudLinkForTesting(machineId: remote.id, deviceId: cloud.deviceId)
    controller.connection(for: remote.id).status = MachineStatus(
      isReachable: true,
      label: "Remote — via Codevisor Cloud",
      cloudDeviceId: cloud.deviceId,
      route: .relay,
      serverId: "remote"
    )

    // The configured fallback must wait for the same raw TCP bridge used
    // by a cloud-only machine instead of leaking back to its dead direct
    // origin while the listener starts.
    let clock = AdvancingServerUpdateScheduler()
    clock.onSleep = {
      provider.loopbackURLsByDeviceId[cloud.deviceId] = URL(
        string: "http://127.0.0.1:50506"
      )!
    }

    let url = await controller.effectiveHTTPBaseURL(forMachineId: remote.id, scheduler: clock.scheduler)

    #expect(url == URL(string: "http://127.0.0.1:50506"))
    #expect(url != remote.baseURL)
  }
}
