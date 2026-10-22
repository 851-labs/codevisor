import Foundation
import Testing

@testable import CodevisorClient

@Suite("LocalServerEndpoint")
struct LocalServerEndpointTests {
  @Test("Adopts the port the server claimed and ignores missing or damaged files")
  func adoptsClaimedPort() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-endpoint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(LocalServerEndpoint.portFileName)
    let endpoint = LocalServerEndpoint(port: 49361)

    #expect(!endpoint.adoptClaimedPort(fromDataDirectory: directory))
    for damaged in ["{", #"{"port":0}"#, #"{"port":70000}"#, #"{"port":"49363"}"#] {
      try Data(damaged.utf8).write(to: file)
      #expect(!endpoint.adoptClaimedPort(fromDataDirectory: directory))
    }
    #expect(endpoint.port == 49361)

    try Data(#"{"port":49363,"pid":42,"bootId":"boot"}"#.utf8).write(to: file)
    #expect(endpoint.adoptClaimedPort(fromDataDirectory: directory))
    #expect(!endpoint.adoptClaimedPort(fromDataDirectory: directory))
    #expect(endpoint.baseURL == URL(string: "http://127.0.0.1:49363"))
    #expect(
      endpoint.mcpOAuthCallbackURL == URL(string: "http://127.0.0.1:49363/v1/mcps/oauth/callback"))
  }

  @Test("Local configs and machines follow the endpoint; fixed addresses stay put")
  func localAddressesFollowEndpoint() {
    let endpoint = LocalServerEndpoint(port: 49361)
    let local = CodevisorMachine(id: "local", name: "Mac", address: .localServer(endpoint), kind: "local")
    let config = local.serverConfig
    var pinned = config
    pinned.baseURL = URL(string: "http://studio:49361")!

    endpoint.update(port: 49370)

    #expect(local.baseURL == URL(string: "http://127.0.0.1:49370"))
    #expect(config.baseURL == URL(string: "http://127.0.0.1:49370"))
    #expect(config == CodevisorServerConfig(address: .localServer(endpoint)))
    #expect(pinned.address == .fixed(URL(string: "http://studio:49361")!))
    #expect(ServerAddress.localServer(endpoint) != .localServer(LocalServerEndpoint(port: 49370)))
    #expect(ServerAddress.localServer(endpoint) != .fixed(endpoint.baseURL))
    #expect(CodevisorMachine.local.address == .localServer(.shared))
  }
}
