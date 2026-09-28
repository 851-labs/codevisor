import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Device approval on the account")
struct CloudDeviceApprovalControllerTests {
  private let hostedLink = CloudDeviceApprovalLink(
    serverURL: URL(string: "https://cloud.codevisor.dev")!, userCode: "ABCD-EFGH")

  @Test("Approves and denies with the account's session token")
  func sendsWithToken() async throws {
    let (controller, client, _) = await makeSignedIn(machines: [])
    try await controller.approveDevice(hostedLink)
    try await controller.denyDevice(hostedLink)
    #expect(client.deviceDecisions.map(\.decision) == ["approve", "deny"])
    #expect(client.deviceDecisions.allSatisfy { $0.userCode == "ABCD-EFGH" && $0.token == "t" })
  }

  @Test("Never sends the session to a cloud other than the account's own")
  func refusesOtherOrigin() async throws {
    let (controller, client, _) = await makeSignedIn(machines: [])
    let foreign = CloudDeviceApprovalLink(
      serverURL: URL(string: "https://cloud.attacker.example")!, userCode: "ABCD-EFGH")
    let mismatch = CloudDeviceApprovalError.differentServer(
      machineHost: "cloud.attacker.example", accountHost: "cloud.codevisor.dev")
    #expect(controller.deviceApprovalServerMismatch(for: foreign) == mismatch)
    await #expect(throws: mismatch) { try await controller.approveDevice(foreign) }
    #expect(client.deviceDecisions.isEmpty)
  }

  @Test("Signed out, approval asks for sign-in instead of sending anything")
  func requiresSignIn() async throws {
    let (controller, client, _) = makeController()
    #expect(controller.deviceApprovalServerMismatch(for: hostedLink) == nil)
    await #expect(throws: CloudDeviceApprovalError.signInRequired) { try await controller.approveDevice(hostedLink) }
    #expect(client.deviceDecisions.isEmpty)
  }
}
