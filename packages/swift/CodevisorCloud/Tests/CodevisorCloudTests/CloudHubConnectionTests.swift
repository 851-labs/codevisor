import Foundation
import Testing
import ACPKit
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

@Suite("CloudHubConnection")
struct CloudHubConnectionTests {
  @Test("Connects with hello and adopts the welcome's machine list")
  func helloWelcome() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let (hub, _) = makeHub(scripted)

    try await hub.waitUntilReady()
    #expect(scripted.sawHello)
    #expect(scripted.appPublicKey?.isEmpty == false)
    let machines = await hub.machines
    #expect(machines.map(\.deviceId) == [machine.deviceId])
    await hub.shutdown()
  }

  @Test("A hub snapshots credentials instead of rereading them per channel")
  func credentialsAreReadOnce() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let memory = InMemoryCloudCredentialStore(token: "session-token")
    try memory.saveAppDeviceId("app-device")
    try memory.saveAppSecretKey(Data(repeating: 7, count: 32))
    let store = CountingCredentialStore(base: memory)
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
      readyTimeout: .seconds(2)
    )

    try await hub.waitUntilReady()
    for _ in 0..<4 {
      _ = try await hub.openChannel(
        machineDeviceId: machine.deviceId,
        machinePublicKey: machine.publicKey,
        channelType: "test",
        params: nil,
        onMessage: { _ in },
        onClosed: { _ in }
      )
    }

    let counts = store.readCounts
    #expect(counts.token == 1)
    #expect(counts.deviceId == 1)
    #expect(counts.secretKey == 1)
    await hub.shutdown()
  }

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
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(3)
    )

    try await hub.waitUntilReady()
    first.socket.disconnect()
    #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count == 2 })
    try await hub.waitUntilReady()

    let counts = store.readCounts
    #expect(counts.token == 1)
    #expect(counts.deviceId == 1)
    #expect(counts.secretKey == 1)
    await hub.shutdown()
  }

  @Test("Channel opens park while a known machine is offline")
  func offlineMachineParksChannelOpen() async throws {
    let machine = ScriptedRelayMachine()
    var offlinePresence = machine.presence
    offlinePresence.online = false
    let scripted = ScriptedCloudHub(machines: [offlinePresence])
    let (hub, _) = makeHub(scripted)

    try await hub.waitUntilReady()
    let openTask = Task {
      try await hub.openChannel(
        machineDeviceId: machine.deviceId,
        machinePublicKey: machine.publicKey,
        channelType: "test",
        params: nil,
        onMessage: { _ in },
        onClosed: { _ in }
      )
    }

    try await Task.sleep(for: .milliseconds(25))
    #expect(scripted.relayEnvelopes.isEmpty)

    var onlinePresence = offlinePresence
    onlinePresence.online = true
    scripted.presenceToApp(onlinePresence)
    _ = try await openTask.value
    #expect(await waitUntil { scripted.relayEnvelopes.count == 1 })
    await hub.shutdown()
  }

  @Test("The welcome roster and presence pushes fire the machines-changed handler")
  func machinesChangedHandlerFires() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let (hub, _) = makeHub(scripted)
    let recorder = MachineListRecorder()
    await hub.setMachinesChangedHandler { recorder.record($0) }

    try await hub.waitUntilReady()
    // The welcome roster is a change from empty.
    #expect(
      await waitUntil {
        recorder.snapshots.contains { $0.map(\.deviceId) == [machine.deviceId] }
      }
    )

    // A machine signed in elsewhere arrives as a presence push — the
    // handler must see it appended, never waiting for a poll.
    scripted.presenceToApp(testMachine("just-signed-in"))
    #expect(
      await waitUntil {
        recorder.snapshots.contains { list in
          list.contains { $0.deviceId == "just-signed-in" }
        }
      }
    )
    await hub.shutdown()
  }

  @Test("An offline presence closes that machine's channels")
  func offlinePresenceClosesChannels() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let (hub, _) = makeHub(scripted)
    let recorder = Recorder()

    _ = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { _ in },
      onClosed: { recorder.recordClose($0) }
    )
    #expect(await waitUntil { scripted.relayEnvelopes.count == 1 })

    // The machine's hub socket dropped: its in-memory channel state is
    // gone, so the app must tear down its side rather than wait forever.
    var offlinePresence = machine.presence
    offlinePresence.online = false
    scripted.presenceToApp(offlinePresence)

    #expect(await waitUntil { recorder.closes == [nil] })
    #expect(await hub.machines.first?.online == false)
    await hub.shutdown()
  }

  @Test("A machine-reset closes that machine's channels without marking it offline")
  func machineResetClosesChannels() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let (hub, _) = makeHub(scripted)
    let recorder = Recorder()

    _ = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { _ in },
      onClosed: { recorder.recordClose($0) }
    )
    #expect(await waitUntil { scripted.relayEnvelopes.count == 1 })

    // The machine re-hello'd: its channel state is fresh, so existing
    // channels are dead even though the machine stays online.
    scripted.machineResetToApp(machineId: machine.deviceId)

    #expect(await waitUntil { recorder.closes == [nil] })
    #expect(await hub.machines.first?.online == true)

    // The machine is still online, so a fresh open dispatches immediately
    // instead of parking for a presence flip.
    _ = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { _ in },
      onClosed: { _ in }
    )
    #expect(await waitUntil { scripted.relayEnvelopes.count == 2 })
    await hub.shutdown()
  }

  @Test("A channel-scoped machine-offline error does not poison machine presence")
  func channelScopedOfflineErrorOnlyClosesItsChannel() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let (hub, _) = makeHub(scripted)
    let recorder = Recorder()

    let first = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { _ in },
      onClosed: { recorder.recordClose($0) }
    )
    #expect(await waitUntil { scripted.relayEnvelopes.count == 1 })

    scripted.errorToApp(
      code: "machine-offline",
      message: "machine is not connected",
      machineId: machine.deviceId,
      channelId: first.id
    )
    #expect(await waitUntil { recorder.closes == [nil] })
    #expect(await hub.machines.first?.online == true)

    _ = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { _ in },
      onClosed: { _ in }
    )
    #expect(await waitUntil { scripted.relayEnvelopes.count == 2 })
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
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2),
      heartbeatInterval: .milliseconds(20),
      heartbeatTimeout: .milliseconds(20)
    )

    try await hub.waitUntilReady()
    #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count >= 2 })
    try await hub.waitUntilReady()
    await hub.shutdown()
  }

  @Test("Keepalive pongs record the relay RTT")
  func keepaliveMeasuresRtt() async throws {
    let scripted = ScriptedCloudHub()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
      readyTimeout: .seconds(2),
      heartbeatInterval: .milliseconds(20),
      heartbeatTimeout: .seconds(2)
    )

    try await hub.waitUntilReady()
    #expect(await hub.lastRttMillis == nil)
    #expect(await waitUntil { await hub.lastRttMillis != nil })
    let rtt = try #require(await hub.lastRttMillis)
    #expect(rtt >= 0)
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
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2)
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
    #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count >= 2 })
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
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2)
    )

    try await hub.waitUntilReady()
    await hub.reconnect()
    #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count >= 2 })
    try await hub.waitUntilReady()
    await hub.shutdown()
  }

  @Test("Fatal hub close codes stop reconnecting")
  func fatalCloseCode() async throws {
    let scripted = ScriptedCloudHub()
    scripted.socket.closeCodeOnDisconnect = URLSessionWebSocketTask.CloseCode(rawValue: 4200)!
    let (hub, _) = makeHub(scripted)
    try await hub.waitUntilReady()
    scripted.socket.disconnect()

    // Once the fatal close is observed, openChannel fails fast instead of
    // retrying forever.
    #expect(
      await waitUntil {
        do {
          try await hub.waitUntilReady()
          return false
        } catch let error as CloudHubConnectionError {
          return error == .rejected(closeCode: 4200)
        } catch {
          return false
        }
      })
    await hub.shutdown()
  }

  @Test("Missing token is fatal (hub outlived its sign-in)")
  func missingTokenFatal() async throws {
    let scripted = ScriptedCloudHub()
    let store = InMemoryCloudCredentialStore()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
      readyTimeout: .seconds(2)
    )
    await #expect(throws: CloudHubConnectionError.notSignedIn) {
      try await hub.waitUntilReady()
    }
    await hub.shutdown()
  }

  @Test("The connect URL carries the session token on the /connect path")
  func connectURL() async throws {
    let scripted = ScriptedCloudHub()
    let transport = FakeWebSocketTransport { _ in scripted.socket }
    let store = InMemoryCloudCredentialStore(token: "session-token")
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2)
    )
    try await hub.waitUntilReady()
    #expect(transport.requests.first?.absoluteString == "wss://cloud.example.com/connect?token=session-token")
    await hub.shutdown()
  }

  @Test("Tokens with query-hostile characters are strictly percent-encoded")
  func connectURLEncodesToken() async throws {
    // Session tokens are base64 with "+", "/" and "=". URLComponents
    // leaves those literal, but the hub decodes the query per the WHATWG
    // standard where "+" is a space — the token must arrive fully encoded
    // or the hub authenticates the wrong session (see the app joining a
    // stale cookie's account instead of its own).
    let scripted = ScriptedCloudHub()
    let transport = FakeWebSocketTransport { _ in scripted.socket }
    let store = InMemoryCloudCredentialStore(token: "a+b/c=.d+e=")
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: store,
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: transport,
      readyTimeout: .seconds(2)
    )
    try await hub.waitUntilReady()
    #expect(
      transport.requests.first?.absoluteString
        == "wss://cloud.example.com/connect?token=a%2Bb%2Fc%3D.d%2Be%3D"
    )
    await hub.shutdown()
  }
}

/// Thread-safe capture of every machine list the changed handler delivers.
private final class MachineListRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[CloudMachine]] = []

  var snapshots: [[CloudMachine]] { lock.withLock { recorded } }

  func record(_ machines: [CloudMachine]) {
    lock.withLock { recorded.append(machines) }
  }
}
