import CodevisorClient
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Moving a directly paired machine onto the account")
struct CloudDirectMachineAdoptionTests {
  @Test("Registers the machine as external under its name with the account session, then refreshes the list")
  func adoptsAsExternalMachine() async throws {
    let client = FakeCloudClient()
    client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
    let (controller, _, store) = makeController(client: client)
    try store.saveToken("dev-token")
    await controller.bootstrap()
    let refreshesBefore = client.machineTokens.count
    let machine = FakeLocalServerClient()

    let deviceId = try await controller.adoptDirectMachine(using: machine, name: "Studio")

    #expect(deviceId == "adopted-device-1")
    #expect(machine.externalConnects.map(\.sessionToken) == ["dev-token"])
    #expect(machine.externalConnects.map(\.managedBy) == ["external"])
    #expect(machine.externalConnects.map(\.machineName) == ["Studio"])
    #expect(client.machineTokens.count == refreshesBefore + 1)
  }

  @Test("Refuses while signed out, touching nothing")
  func refusesWhileSignedOut() async throws {
    let (controller, _, _) = makeController(client: FakeCloudClient())
    let machine = FakeLocalServerClient()

    await #expect(throws: CloudAccountClientError.missingToken) {
      try await controller.adoptDirectMachine(using: machine, name: "Studio")
    }
    #expect(machine.externalConnects.isEmpty)
  }
}
