import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

extension LocalCodevisorServerTests {
  @Test("Health probes follow the port the server claimed")
  func healthProbesFollowClaimedPort() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeClaimedPort(49377, in: directory)
    let endpoint = LocalServerEndpoint(port: 49361)
    let server = LocalCodevisorServer(
      client: FakeLocalServerClient(healthResults: [.success(.ready), .success(.ready)]),
      config: CodevisorServerConfig(address: .localServer(endpoint)),
      databasePath: directory.appendingPathComponent("codevisor-server.sqlite").path
    )

    #expect(await server.currentHealth()?.ok == true)

    #expect(endpoint.port == 49377)
    #expect(server.port == 49377)
    try writeClaimedPort(49378, in: directory)
    #expect(await server.isHealthy())
    #expect(endpoint.port == 49378)
  }

  @Test("Follows a server it launched to the port that server claimed")
  func followsLaunchedServerToClaimedPort() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = LocalServerEndpoint(port: 49361)
    let client = FakeLocalServerClient(healthResults: [.failure(TestError()), .success(.ready)])
    var preferredPorts: [Int] = []
    let server = LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: true,
      config: CodevisorServerConfig(address: .localServer(endpoint)),
      entrypoint: directory.appendingPathComponent("main.js"),
      databasePath: directory.appendingPathComponent("codevisor-server.sqlite").path,
      serverEnvironmentProvider: { [:] },
      launcher: { [self] request in
        preferredPorts.append(request.port)
        try writeClaimedPort(49380, in: directory)
        client.acceptBoot(request.bootId)
        return Process()
      }
    )
    server.startupScheduler = AdvancingLocalServerScheduler().scheduler

    #expect(await server.ensureRunning() == .started)

    #expect(preferredPorts == [49361])
    #expect(endpoint.port == 49380)
  }

  @Test("Fixed addresses ignore the local port file")
  func fixedAddressesIgnoreClaimedPort() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeClaimedPort(49377, in: directory)
    let server = LocalCodevisorServer(
      client: FakeLocalServerClient(healthResults: [.success(.ready)]),
      config: CodevisorServerConfig(baseURL: URL(string: "http://127.0.0.1:49361")!),
      databasePath: directory.appendingPathComponent("codevisor-server.sqlite").path
    )

    #expect(await server.currentHealth()?.ok == true)

    #expect(server.port == 49361)
  }

  private func writeClaimedPort(_ port: Int, in directory: URL) throws {
    try Data(#"{"port":\#(port),"pid":42,"bootId":"boot"}"#.utf8)
      .write(to: directory.appendingPathComponent(LocalServerEndpoint.portFileName), options: .atomic)
  }
}
