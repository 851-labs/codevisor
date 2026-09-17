import CodevisorClient
import CodevisorProtocol
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Shared account coordinator registration")
struct CloudSharedAccountRegistrationTests {
  @Test("Trusted direct machines join automatically and existing registrations are preserved")
  func joinsOnce() async throws {
    let cloud = FakeCloudClient()
    cloud.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
    let (controller, _, store) = makeController(client: cloud)
    let machine = FakeLocalServerClient()
    #expect(await controller.prepareAccountSync(on: machine, machineId: "direct") == false)
    #expect(machine.connects.isEmpty)
    try store.saveToken("dev-token")
    await controller.bootstrap()
    #expect(await controller.prepareAccountSync(on: machine, machineId: "direct"))
    #expect(machine.connects.count == 1)
    #expect(machine.connects.first?.sessionToken == "dev-token")
    #expect(await controller.prepareAccountSync(on: machine, machineId: "direct") == false)
    #expect(machine.connects.count == 1)
    let existing = FakeLocalServerClient(
      registration: ServerCloudRegistration(connected: true, deviceId: "existing", managedBy: "external"))
    #expect(await controller.prepareAccountSync(on: existing, machineId: "existing") == false)
    #expect(existing.connects.isEmpty)
  }

  @Test("A failed registration retries on the next sync pass")
  func retriesFailure() async throws {
    let cloud = FakeCloudClient()
    cloud.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
    let (controller, _, store) = makeController(client: cloud)
    try store.saveToken("dev-token")
    await controller.bootstrap()
    let machine = FakeLocalServerClient()
    machine.connectError = URLError(.notConnectedToInternet)
    #expect(await controller.prepareAccountSync(on: machine, machineId: "direct") == false)
    machine.connectError = nil
    #expect(await controller.prepareAccountSync(on: machine, machineId: "direct"))
    #expect(machine.connects.count == 1)
  }
}
