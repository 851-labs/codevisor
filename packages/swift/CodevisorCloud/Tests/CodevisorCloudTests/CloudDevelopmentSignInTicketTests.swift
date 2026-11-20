import CodevisorProtocol
import Foundation
import Testing

@testable import CodevisorCloud

@MainActor
@Suite("Development sign-in ticket")
struct CloudDevelopmentSignInTicketTests {
  @Test("A fresh instance signs into the development account once, then stays signed out")
  func ticketSignsInOnce() async throws {
    let ticket = try makeTicket()
    let first = makeController(client: devCloudClient(), developmentSignInTicket: ticket)
    await first.controller.bootstrap()

    #expect(first.controller.state == .signedIn(userEmail: "dev@example.com"))
    #expect(!FileManager.default.fileExists(atPath: ticket.path))

    first.controller.signOut()
    let relaunched = makeController(
      client: devCloudClient(), store: first.store, developmentSignInTicket: ticket)
    await relaunched.controller.bootstrap()
    #expect(relaunched.controller.state == .signedOut)
  }

  @Test("An instance that is already signed in uses up its ticket without signing in again")
  func signedInInstanceConsumesTicket() async throws {
    let ticket = try makeTicket()
    let client = devCloudClient()
    client.machinesResult = .success([])
    let store = InMemoryCloudCredentialStore()
    try store.saveToken("dev-token")
    let (controller, _, _) = makeController(
      client: client, store: store, developmentSignInTicket: ticket)
    await controller.bootstrap()

    #expect(client.devLoginCount == 0)
    #expect(!FileManager.default.fileExists(atPath: ticket.path))
  }

  private func devCloudClient() -> FakeCloudClient {
    let client = FakeCloudClient()
    client.discoverResult = .success(
      CloudInstanceInfo(service: "codevisor-cloud", instance: "Dev Cloud", authProviders: ["dev"])
    )
    client.devLoginResult = .success("dev-token")
    client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
    client.machinesResult = .success([testMachine("dev-1")])
    return client
  }

  private func makeTicket() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-sign-in-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ticket = directory.appendingPathComponent("macos.ticket")
    try Data().write(to: ticket)
    return ticket
  }
}
