import ACPKit
import Foundation
import Testing
import CodevisorClient
import CodevisorProtocol
import CodevisorTestSupport
@testable import CodevisorCloud

@Suite("CloudChannelTransport")
struct CloudChannelTransportTests {
  private actor StubChannelHost: CloudChannelHosting {
    private(set) var closes: [(channelId: String, reason: CloudChannelCloseReason)] = []

    func send(channelId: String, plaintext: Data) throws -> Int {
      plaintext.count
    }

    func grantCredit(channelId: String, bytes: Int) throws {}

    private(set) var unanswered: [String] = []
    nonisolated let closed = TestSignal()

    func reportUnanswered(channelId: String) {
      unanswered.append(channelId)
    }

    func closeChannel(_ channelId: String, reason: CloudChannelCloseReason) {
      closes.append((channelId, reason))
      closed.signal()
    }
  }

  private final class StubTransport: CloudChannelTransport, Sendable {
    let machineDeviceId = "stub-machine"
    let host = StubChannelHost()
    let opened = TestSignal()

    func openChannel(
      channelType: String,
      params: JSONValue?,
      compressed: Bool,
      onMessage: @escaping @Sendable (Data) -> Void,
      onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
      CloudRelayChannel(id: UUID().uuidString, host: host)
    }

    func openFlowControlledChannel(
      channelType: String,
      params: JSONValue?,
      compressed: Bool,
      onMessage: @escaping @Sendable (Data, Int) -> Void,
      onCredit: @escaping @Sendable (Int) -> Void,
      onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
      onCredit(1_000_000)
      defer { opened.signal() }
      return CloudRelayChannel(id: UUID().uuidString, host: host)
    }
  }

  @Test("A request with no reply by the deadline reports its channel unanswered")
  func silentRequestReportsUnanswered() async throws {
    let stub = StubTransport()
    let clock = TestClock()
    let transport = CloudRelayRequestTransport(endpoint: stub, sleep: clock.sleep)
    let request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/capabilities")!)
    let fetch = Task { try await transport.data(for: request) }

    await clock.waitForSleep(CloudRelayRequestTransport.defaultTimeout)
    clock.advance(by: CloudRelayRequestTransport.defaultTimeout)
    await #expect(throws: CloudRelayTransportError.timedOut) { _ = try await fetch.value }
    let unanswered = await stub.host.unanswered
    let closed = await stub.host.closes.map(\.channelId)
    #expect(unanswered.count == 1)
    #expect(closed == unanswered)
  }

  @Test("A relayed socket reports an unanswered open before closing its channel")
  func relayedSocketReportsUnanswered() async throws {
    let stub = StubTransport()
    let socket = CloudRelayWebSocketTransport(endpoint: stub).connect(
      URLRequest(url: URL(string: "wss://cloud-relay.invalid/v1/events/socket")!),
      maximumMessageSize: 1 << 20
    )
    await stub.opened.wait()
    socket.markUnanswered()
    socket.cancel(with: .goingAway, reason: nil)

    await stub.host.closed.wait()
    #expect(await stub.host.unanswered.count == 1)
  }
}
