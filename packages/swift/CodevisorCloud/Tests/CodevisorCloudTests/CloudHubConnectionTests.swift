import Observation
import CodevisorTestSupport
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

    // A presence transition for a known machine updates it in place.
    var offline = machine.presence
    offline.online = false
    scripted.presenceToApp(offline)
    #expect(await waitUntil { recorder.snapshots.last?.first?.online == false })
    #expect(recorder.snapshots.last?.map(\.deviceId) == [machine.deviceId, "just-signed-in"])
    await hub.shutdown()
  }

  @Test("An answered keepalive keeps the hub socket past the pong deadline")
  func answeredKeepaliveKeepsSocket() async throws {
    let scripted = ScriptedCloudHub()
    // The test answers the ping itself, once the pong deadline is armed.
    scripted.respondsToPing = false
    let transport = FakeWebSocketTransport { _ in scripted.socket }
    let clock = TestClock()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
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
    #expect(await waitUntil { scripted.socket.sentTexts.contains(#"{"t":"ping"}"#) })
    await clock.waitForSleep(.seconds(10))
    scripted.socket.pushJSON(#"{"t":"pong"}"#)
    await scripted.socket.drain()
    await clock.waitForSleep(.seconds(30), count: 2)

    // The pong disarmed the deadline: only the next heartbeat is pending,
    // so advancing past the deadline cannot tear the socket down.
    #expect(clock.pendingCount == 1)
    clock.advance(by: .seconds(10))
    #expect(scripted.socket.cancelled.value == 0)
    #expect(transport.requests.count == 1)
    await hub.shutdown()
  }

  @Test("Fatal hub close codes stop reconnecting")
  func fatalCloseCode() async throws {
    let scripted = ScriptedCloudHub()
    scripted.socket.closeCodeOnDisconnect = URLSessionWebSocketTask.CloseCode(rawValue: 4200)!
    let (hub, _) = makeHub(scripted)
    try await hub.waitUntilReady()
    scripted.socket.disconnect()

    await scripted.socket.cancelled.wait()
    await #expect(throws: CloudHubConnectionError.rejected(closeCode: 4200)) {
      try await hub.waitUntilReady()
    }
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
      readyTimeout: .seconds(2),
      sleep: TestClock().sleep,
      reconnectDelay: { _ in .seconds(1) }
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
      readyTimeout: .seconds(2),
      sleep: TestClock().sleep,
      reconnectDelay: { _ in .seconds(1) }
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
      readyTimeout: .seconds(2),
      sleep: TestClock().sleep,
      reconnectDelay: { _ in .seconds(1) }
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
@Observable
private final class MachineListRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[CloudMachine]] = []

  var snapshots: [[CloudMachine]] { lock.withLock { recorded } }

  func record(_ machines: [CloudMachine]) {
    lock.withLock { recorded.append(machines) }
  }
}
