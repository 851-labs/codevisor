import CodevisorClient
import CodevisorNet
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCloud

/// The app side of the tunnel control plane (docs/plans/codevisor-tunnel.md):
/// the device's derived tunnel identity, its registration in hello, and the
/// relay config each welcome delivers. The tunnel data path itself is covered
/// by packages/net and scripts/net-e2e.mjs.
@Suite("Cloud tunnel control plane")
struct CloudTunnelTests {
  private final class ConfigRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudTunnelConfig] = []
    func record(_ config: CloudTunnelConfig) { lock.withLock { recorded.append(config) } }
    var configs: [CloudTunnelConfig] { lock.withLock { recorded } }
  }

  @Test("The tunnel identity is derived from the device key: stable, distinct, valid")
  func derivedIdentity() throws {
    let store = InMemoryCloudCredentialStore(token: "session-token")
    let identity = try store.ensureAppDeviceIdentity()
    let secret = CloudTunnelIdentity.secretKeyHex(for: identity)
    #expect(secret.count == 64)
    #expect(secret == CloudTunnelIdentity.secretKeyHex(for: try store.ensureAppDeviceIdentity()))
    let endpointId = try #require(CloudTunnelIdentity.endpointId(for: identity))
    #expect(endpointId == (try netEndpointIdForSecretKey(secretKeyHex: secret)))
    #expect(endpointId.count == 64 && endpointId.allSatisfy(\.isHexDigit))

    let other = try InMemoryCloudCredentialStore(token: "t").ensureAppDeviceIdentity()
    #expect(CloudTunnelIdentity.endpointId(for: other) != endpointId)
  }

  @Test("Hello registers the tunnel endpoint and each welcome configures the tunnel")
  func welcomeConfiguresTunnel() async throws {
    let scripted = ScriptedCloudHub(machines: [])
    let relays = [CloudTunnelConfig.Relay(url: "https://relay-a.test", quicPort: 7842)]
    scripted.tunnelWelcome = (relays: relays, tunnel: "on")
    let (hub, store) = makeHub(scripted)
    let recorder = ConfigRecorder()
    await hub.setTunnelConfigHandler { recorder.record($0) }

    try await hub.waitUntilReady()
    #expect(await waitUntil { !recorder.configs.isEmpty })
    #expect(recorder.configs.first == CloudTunnelConfig(relays: relays, enabled: true))
    let identity = try store.ensureAppDeviceIdentity()
    #expect(scripted.helloTunnelEndpointId == CloudTunnelIdentity.endpointId(for: identity))
    await hub.shutdown()
  }

  @Test("Hello reports the app's release channel, so the hub can gate the tunnel by it")
  func helloReportsReleaseChannel() async throws {
    let scripted = ScriptedCloudHub(machines: [])
    let (hub, _) = makeHub(scripted, releaseChannel: CloudReleaseChannel(alpha: true))
    try await hub.waitUntilReady()
    #expect(scripted.helloReleaseChannel == "alpha")
    await hub.shutdown()

    let stableHub = ScriptedCloudHub(machines: [])
    let (stable, _) = makeHub(stableHub)
    try await stable.waitUntilReady()
    #expect(stableHub.helloReleaseChannel == "stable")
    await stable.shutdown()
  }

  @Test("A handler installed after the welcome still receives its tunnel config")
  func lateHandlerGetsReplay() async throws {
    let scripted = ScriptedCloudHub(machines: [])
    scripted.tunnelWelcome = (relays: [], tunnel: "on")
    let (hub, _) = makeHub(scripted)
    try await hub.waitUntilReady()
    let recorder = ConfigRecorder()
    await hub.setTunnelConfigHandler { recorder.record($0) }
    #expect(recorder.configs == [CloudTunnelConfig(relays: [], enabled: true)])
    await hub.shutdown()
  }

  @Test("A welcome without tunnel fields (an older hub) leaves the tunnel off")
  func olderHubDisablesTunnel() async throws {
    let scripted = ScriptedCloudHub(machines: [])
    let (hub, _) = makeHub(scripted)
    let recorder = ConfigRecorder()
    await hub.setTunnelConfigHandler { recorder.record($0) }
    try await hub.waitUntilReady()
    #expect(await waitUntil { !recorder.configs.isEmpty })
    #expect(recorder.configs.first == CloudTunnelConfig(relays: [], enabled: false))
    await hub.shutdown()
  }

  @Test("Machines decode their tunnel address, and older payloads without one")
  func machineTunnelDecoding() throws {
    let json = """
      [{"deviceId":"m1","name":"Studio","publicKey":"k","online":true,"lastSeenAt":"now",
        "tunnel":{"endpointId":"abc","relayUrl":"https://relay-a.test/","directAddrs":["10.0.0.2:41641"]}},
       {"deviceId":"m2","name":"Old","publicKey":"k2","online":false,"lastSeenAt":"then"}]
      """
    let machines = try JSONDecoder().decode([CloudMachine].self, from: Data(json.utf8))
    #expect(
      machines[0].tunnel
        == CloudTunnelInfo(
          endpointId: "abc", relayUrl: "https://relay-a.test/", directAddrs: ["10.0.0.2:41641"]))
    #expect(machines[1].tunnel == nil)
  }

  @Test("Asking for the endpoint before the first welcome waits for its config")
  func endpointWaitsForFirstConfig() async {
    // A 60 s wait: if configure failed to release the waiter, this would hang.
    let tunnel = CloudTunnelEndpoint(
      credentialStore: InMemoryCloudCredentialStore(token: "t"), trustAnchorsPem: [],
      firstConfigWait: .seconds(60))
    let waiting = Task { await tunnel.endpoint() }
    await tunnel.configure(CloudTunnelConfig(relays: [], enabled: false))
    #expect(await waiting.value == nil)
  }

  @Test("Development trust anchors come from the environment, inline first")
  func environmentTrustAnchors() throws {
    #expect(CloudTunnelEndpoint.environmentTrustAnchors([:]).isEmpty)
    #expect(CloudTunnelEndpoint.environmentTrustAnchors(["CODEVISOR_NET_CA_PEM": "PEM"]) == ["PEM"])
    let file = FileManager.default.temporaryDirectory.appending(path: "tunnel-ca-\(UUID()).pem")
    try "FILE-PEM".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(CloudTunnelEndpoint.environmentTrustAnchors(["CODEVISOR_NET_CA_FILE": file.path]) == ["FILE-PEM"])
  }
}
