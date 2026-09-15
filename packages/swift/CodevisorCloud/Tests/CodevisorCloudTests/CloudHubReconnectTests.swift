import CodevisorTestSupport
import Foundation
import Testing
import CodevisorClient
@testable import CodevisorCloud

@Suite("CloudHub reconnect scheduling")
struct CloudHubReconnectTests {
  @Test("Hub reconnects reuse the credential snapshot")
  func reconnectUsesCredentialSnapshot() async throws {
    let first = ScriptedCloudHub()
    let second = ScriptedCloudHub()
    let sockets = SocketQueue([first.socket, second.socket])
    let transport = FakeWebSocketTransport { _ in sockets.next() }
    let memory = InMemoryCloudCredentialStore(token: "session-token")
    try memory.saveAppDeviceId("app-device")
    try memory.saveAppSecretKey(Data(repeating: 7, count: 32))
    let store = CountingCredentialStore(base: memory)
    let clock = TestClock()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(3),
      sleep: clock.sleep,
      reconnectDelay: { _ in .seconds(1) }
    )

    try await hub.waitUntilReady()
    first.socket.disconnect()
    await clock.waitForSleep(.seconds(1))
    #expect(transport.requests.count == 1)
    clock.advance(by: .seconds(1))
    #expect(await waitUntil { transport.requests.count == 2 })
    try await hub.waitUntilReady()

    let counts = store.readCounts
    #expect(counts.token == 1)
    #expect(counts.deviceId == 1)
    #expect(counts.secretKey == 1)
    await hub.shutdown()
  }

  @Test("A missing heartbeat pong replaces a half-open socket")
  func heartbeatTimeoutReconnects() async throws {
    let first = ScriptedCloudHub()
    first.respondsToPing = false
    let second = ScriptedCloudHub()
    let sockets = SocketQueue([first.socket, second.socket])
    let transport = FakeWebSocketTransport { _ in sockets.next() }
    let store = InMemoryCloudCredentialStore(token: "session-token")
    let clock = TestClock()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2),
      heartbeatInterval: .seconds(30),
      heartbeatTimeout: .seconds(10),
      sleep: clock.sleep,
      reconnectDelay: { _ in .seconds(1) }
    )

    try await hub.waitUntilReady()
    await clock.waitForSleep(.seconds(30))
    clock.advance(by: .seconds(30))
    await clock.waitForSleep(.seconds(10))
    #expect(transport.requests.count == 1)
    clock.advance(by: .seconds(10))
    await clock.waitForSleep(.seconds(1))
    #expect(transport.requests.count == 1)
    clock.advance(by: .seconds(1))
    #expect(await waitUntil { transport.requests.count == 2 })
    try await hub.waitUntilReady()
    await hub.shutdown()
  }

  @Test("An outbound send failure replaces the hub socket")
  func sendFailureReconnects() async throws {
    let machine = ScriptedRelayMachine()
    let first = ScriptedCloudHub(machines: [machine.presence])
    let second = ScriptedCloudHub(machines: [machine.presence])
    let sockets = SocketQueue([first.socket, second.socket])
    let transport = FakeWebSocketTransport { _ in sockets.next() }
    let store = InMemoryCloudCredentialStore(token: "session-token")
    let clock = TestClock()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2),
      sleep: clock.sleep,
      reconnectDelay: { _ in .seconds(1) }
    )

    try await hub.waitUntilReady()
    first.socket.failsSends = true
    _ = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { _ in },
      onClosed: { _ in }
    )
    await clock.waitForSleep(.seconds(1))
    #expect(transport.requests.count == 1)
    clock.advance(by: .seconds(1))
    #expect(await waitUntil { transport.requests.count >= 2 })
    try await hub.waitUntilReady()
    await hub.shutdown()
  }

  @Test("Lifecycle reconnect immediately replaces the current socket")
  func lifecycleReconnect() async throws {
    let first = ScriptedCloudHub()
    let second = ScriptedCloudHub()
    let sockets = SocketQueue([first.socket, second.socket])
    let transport = FakeWebSocketTransport { _ in sockets.next() }
    let store = InMemoryCloudCredentialStore(token: "session-token")
    let clock = TestClock()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2),
      sleep: clock.sleep,
      reconnectDelay: { _ in .seconds(1) }
    )

    try await hub.waitUntilReady()
    await hub.reconnect()
    await clock.waitForSleep(.seconds(1))
    #expect(transport.requests.count == 1)
    clock.advance(by: .seconds(1))
    #expect(await waitUntil { transport.requests.count >= 2 })
    try await hub.waitUntilReady()
    await hub.shutdown()
  }
}
