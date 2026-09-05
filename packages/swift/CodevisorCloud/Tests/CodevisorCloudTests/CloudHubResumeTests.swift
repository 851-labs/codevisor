import Observation
import CodevisorTestSupport
import Foundation
import Testing
import ACPKit
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

/// Session resume, app side: held channels ride out a socket swap when the
/// hub honours the resume token, and degrade to the plain teardown when it
/// does not (or nobody answers within the suspension deadline).
@Suite("CloudHubConnection resume")
struct CloudHubResumeTests {
  @Observable
  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedMessages: [Data] = []
    private var closeReasons: [CloudChannelCloseReason?] = []

    var messages: [Data] { lock.withLock { receivedMessages } }
    var closes: [CloudChannelCloseReason?] { lock.withLock { closeReasons } }

    func record(_ data: Data) { lock.withLock { receivedMessages.append(data) } }
    func recordClose(_ reason: CloudChannelCloseReason?) {
      lock.withLock { closeReasons.append(reason) }
    }
  }

  private func makeResumableHub(
    _ scripted: ScriptedCloudHub,
    suspension: Duration = .seconds(70),
    clock: TestClock
  ) -> CloudHubConnection {
    scripted.issueResumeTokens = true
    return CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: FakeWebSocketTransport { _ in scripted.makeSocket() },
      readyTimeout: .seconds(2),
      resumeSuspensionTimeout: suspension,
      sleep: clock.sleep,
      reconnectDelay: { _ in .seconds(1) }
    )
  }

  @Test("Held channels survive a socket swap when the hub resumes the session")
  func channelsSurviveResume() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    scripted.onRelay = { [weak scripted] envelope in
      guard let scripted, let appKey = scripted.appPublicKey else { return }
      _ = try? machine.receive(envelope.frame, payload: envelope.payload, appPublicKey: appKey)
    }
    let clock = TestClock()
    let hub = makeResumableHub(scripted, clock: clock)
    let recorder = Recorder()

    let channel = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    try await channel.sendJSON(["n": 1])
    #expect(await waitUntil { machine.channel(channel.id)?.messages.count == 1 })

    // The socket dies mid-session. Channels suspend instead of failing.
    let firstSocket = scripted.currentSocket
    firstSocket.disconnect()
    await clock.waitForSleep(.seconds(1))
    #expect(await !hub.isWelcomed)
    // A suspended send fails fast WITHOUT burning a seq.
    await #expect(throws: CloudHubConnectionError.disconnected) {
      try await channel.sendJSON(["lost": true])
    }

    // The run loop reconnects, presents the token, and the hub resumes.
    await clock.waitForSleep(.seconds(1))
    clock.advance(by: .seconds(1))
    try await hub.waitUntilReady()
    #expect(recorder.closes.isEmpty)

    // The channel keeps flowing with a gapless seq counter.
    try await channel.sendJSON(["n": 2])
    #expect(await waitUntil { machine.channel(channel.id)?.messages.count == 2 })
    scripted.relayToApp(
      machineId: machine.deviceId,
      sealed: try machine.sealData(channelId: channel.id, payload: Data("still here".utf8))
    )
    #expect(await waitUntil { recorder.messages.count == 1 })
    await hub.shutdown()
  }

  @Test("A refused resume lands a fresh identity and fails held channels")
  func freshWelcomeFailsHeldChannels() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    scripted.onRelay = { [weak scripted] envelope in
      guard let scripted, let appKey = scripted.appPublicKey else { return }
      _ = try? machine.receive(envelope.frame, payload: envelope.payload, appPublicKey: appKey)
    }
    let clock = TestClock()
    let hub = makeResumableHub(scripted, clock: clock)
    let recorder = Recorder()

    _ = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    scripted.acceptResume = false
    scripted.currentSocket.disconnect()

    // The reconnect gets a fresh identity → held channels die at welcome.
    await clock.waitForSleep(.seconds(1))
    clock.advance(by: .seconds(1))
    try await hub.waitUntilReady()
    #expect(await waitUntil { recorder.closes == [nil] })
    await hub.shutdown()
  }

  @Test("The suspension deadline bounds a resume nobody answers")
  func suspensionDeadline() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    scripted.issueResumeTokens = true
    // The first connect reaches the scripted hub; every reconnect after
    // that lands a black-hole socket that never answers the hello.
    let connects = Counter()
    let clock = TestClock()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: FakeWebSocketTransport { _ in
        connects.next() == 1 ? scripted.makeSocket() : FakeWebSocketConnection()
      },
      readyTimeout: .seconds(2),
      resumeSuspensionTimeout: .seconds(70),
      sleep: clock.sleep,
      reconnectDelay: { _ in .seconds(1) }
    )
    let recorder = Recorder()

    _ = try await hub.openChannel(
      machineDeviceId: machine.deviceId,
      machinePublicKey: machine.publicKey,
      channelType: "test",
      params: nil,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    scripted.currentSocket.disconnect()

    await clock.waitForSleep(.seconds(70))
    #expect(recorder.closes.isEmpty)
    clock.advance(by: .seconds(70))

    // Nobody welcomes within the deadline → held channels finally fail.
    #expect(await waitUntil { recorder.closes == [nil] })
    await hub.shutdown()
  }

  @Observable

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
      lock.withLock {
        value += 1
        return value
      }
    }
  }
}
