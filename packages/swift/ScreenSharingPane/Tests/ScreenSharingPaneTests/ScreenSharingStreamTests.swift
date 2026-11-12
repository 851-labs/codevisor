import CodevisorClient
import CodevisorCloud
import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharing
import ScreenSharingV2
import Testing

@testable import ScreenSharingPane

@MainActor
@Suite("Touch viewer over engine v2", .timeLimit(.minutes(1)))
struct ScreenSharingStreamTests {
  @Test("A Mac that lists engine v2 is viewed over v2 with the viewer's address and chroma")
  func viewsOverV2() async {
    let harness = StreamHarness(engines: ["v2"], chroma: .subsampled)
    let stream = harness.start()
    await awaitObserved { harness.sessions.count == 1 }
    await harness.presentVideo(on: stream)

    let starts = await harness.transport.starts
    #expect(starts.map(\.operation) == [.start])
    #expect(starts[0].engine == "v2")
    #expect(starts[0].media == StreamHarness.viewerMedia && starts[0].chroma == "420")
    #expect(harness.sessions[0].tokens == ["grant token"])
    #expect(stream.session === harness.sessions[0] && stream.control != nil)
    stream.stop()
  }

  @Test("A Mac that doesn't list engine v2 ends the stream with an update message, without starting")
  func endsWithoutV2() async {
    let harness = StreamHarness(engines: nil)
    let stream = harness.start()
    await awaitObserved { stream.phase != .connecting }

    #expect(stream.phase == .failed(ScreenSharingStream.v2Unavailable))
    #expect(await harness.transport.starts.isEmpty && harness.v2Grants.isEmpty)
  }

  enum Failure: CaseIterable, Sendable { case connect, hostRefuses, start }

  @Test("A first v2 attempt that fails before video ends the stream with a message", arguments: Failure.allCases)
  func endsWhenTheFirstAttemptFails(_ failure: Failure) async {
    let harness = StreamHarness(engines: ["v2"], v2StartStatus: failure == .hostRefuses ? "failed" : "connecting")
    harness.connectFails = failure == .connect
    harness.startFails = failure == .start
    let stream = harness.start()
    await awaitObserved { stream.phase != .connecting }

    let message = failure == .hostRefuses ? "This Mac can't share its screen right now." : ScreenSharingStream.v2Failed
    #expect(stream.phase == .failed(message))
    let starts = await harness.transport.starts
    #expect(starts.map(\.operation) == [.start] && starts[0].engine == "v2")
  }

  @Test("A v2 stream that shows no video within 24 s ends with a message")
  func endsWithoutVideo() async {
    let harness = StreamHarness(engines: ["v2"])
    let stream = harness.start()
    await awaitObserved { harness.sessions.count == 1 }
    for _ in 0..<3 {
      await harness.clock.waitForSleep(ScreenSharingStream.heartbeatInterval)
      harness.clock.advance(by: ScreenSharingStream.heartbeatInterval)
    }
    await awaitObserved { stream.phase != .connecting }

    #expect(stream.phase == .failed(ScreenSharingStream.missingVideo))
    #expect(harness.sessions.count == 1 && harness.sessions[0].closed)
  }

  @Test("A host notice, such as a capture restart, pauses the wait for v2 video")
  func waitsForVideoWhileTheHostExplains() async {
    let harness = StreamHarness(engines: ["v2"], heartbeatNotice: "Restarting screen capture…")
    let stream = harness.start()
    await awaitObserved { harness.sessions.count == 1 }
    for beat in 1...4 {
      await harness.clock.waitForSleep(ScreenSharingStream.heartbeatInterval, count: beat)
      harness.clock.advance(by: ScreenSharingStream.heartbeatInterval)
    }
    await harness.clock.waitForSleep(ScreenSharingStream.heartbeatInterval, count: 5)

    #expect(await harness.transport.starts.map(\.engine) == ["v2"])
    #expect(harness.sessions.count == 1 && !harness.sessions[0].closed)
    stream.stop()
  }

  @Test("A start whose relay channel closes with no reason is sent again on a fresh channel, without an error")
  func retriesARelayInterruptedStart() async {
    let harness = StreamHarness(engines: ["v2"])
    await harness.transport.failNextStart(with: CloudRelayTransportError.channelClosed(nil))
    let stream = harness.start()
    await harness.clock.waitForSleep(.milliseconds(500))
    #expect(stream.phase == .connecting)
    harness.clock.advance(by: .milliseconds(500))
    await harness.presentVideo(on: stream)

    #expect(stream.phase == .streaming)
    #expect(await harness.transport.starts.map(\.operation) == [.start, .start])
    stream.stop()
  }

  @Test("A start the Mac rejects over the relay ends the stream at once")
  func endsWhenTheRelayRejectsTheStart() async {
    let harness = StreamHarness(engines: ["v2"])
    await harness.transport.failNextStart(with: CloudRelayTransportError.channelClosed(.rejected))
    let stream = harness.start()
    await awaitObserved { stream.phase != .connecting }

    #expect(stream.phase == .failed(CloudRelayTransportError.channelClosed(.rejected).localizedDescription))
    #expect(await harness.transport.starts.count == 1)
    #expect(harness.clock.pendingCount == 0)
  }

  @Test("A v2 stream lost after video reconnects over v2")
  func reconnectsOverV2() async {
    let harness = StreamHarness(engines: ["v2"])
    let stream = harness.start()
    await awaitObserved { harness.sessions.count == 1 }
    await harness.presentVideo(on: stream)
    harness.sessions[0].onConnectionChanged?("failed")
    await awaitObserved { stream.phase == .reconnecting }
    await harness.clock.waitForSleep(.seconds(1))
    harness.clock.advance(by: .seconds(1))
    await awaitObserved { harness.sessions.count == 2 }

    let starts = await harness.transport.starts
    #expect(starts.map(\.operation) == [.start, .restart])
    #expect(starts.map(\.engine) == ["v2", "v2"])
    stream.stop()
  }
}

@MainActor
@Observable
final class StreamHarness {
  nonisolated static let viewerMedia = ServerScreenSharingMediaAddress(
    endpointId: String(repeating: "a", count: 64), relayUrl: nil, directAddrs: ["192.168.1.2:4433"])
  nonisolated static let grant = ServerScreenSharingMediaGrant(
    endpointId: String(repeating: "b", count: 64), relayUrl: nil, directAddrs: [], token: "grant token")

  let transport: StreamTransport
  let clock = TestClock()
  private(set) var sessions: [FakeViewingSession] = []
  private(set) var v2Grants: [ServerScreenSharingMediaGrant] = []
  var connectFails = false
  var startFails = false
  private let chroma: ScreenSharingV2Chroma

  init(
    engines: [String]?, v2StartStatus: String = "connecting", heartbeatNotice: String? = nil,
    chroma: ScreenSharingV2Chroma = .full
  ) {
    transport = StreamTransport(engines: engines, v2StartStatus: v2StartStatus, heartbeatNotice: heartbeatNotice)
    self.chroma = chroma
  }

  func start() -> ScreenSharingStream {
    let chroma = chroma
    let v2 = ScreenSharingV2Connector(
      address: { Self.viewerMedia },
      connect: { [unowned self] grant in
        v2Grants.append(grant)
        if connectFails { throw ScreenSharingError.unavailable("No route to the Mac in this test.") }
        return makeSession(startFails: startFails)
      },
      chroma: { chroma })
    var sponsor = ScreenSharingStreamSponsor(
      workspaceId: UUID(), paneId: UUID(), client: CodevisorServerClient(config: .init(requestTransport: transport)),
      v2: v2)
    sponsor.clock = clock
    let stream = ScreenSharingStream(displayId: "display", sponsor: sponsor)
    stream.start()
    return stream
  }

  func presentVideo(on stream: ScreenSharingStream) async {
    await awaitObserved { stream.session != nil && sessions.last?.tokens.isEmpty == false }
    stream.presentedFirstFrame()
  }

  private func makeSession(startFails: Bool) -> FakeViewingSession {
    let session = FakeViewingSession(startFails: startFails)
    sessions.append(session)
    return session
  }
}

actor StreamTransport: ServerRequestTransport {
  private let engines: [String]?
  private let v2StartStatus: String
  private let heartbeatNotice: String?
  private(set) var requests: [ServerScreenSharingRequest] = []
  private var startFailure: (any Error)?

  init(engines: [String]?, v2StartStatus: String, heartbeatNotice: String? = nil) {
    self.engines = engines
    self.v2StartStatus = v2StartStatus
    self.heartbeatNotice = heartbeatNotice
  }

  var starts: [ServerScreenSharingRequest] { requests.filter { [.start, .restart].contains($0.operation) } }

  func failNextStart(with error: any Error) { startFailure = error }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let payload = try JSONDecoder().decode(ServerScreenSharingRequest.self, from: request.httpBody ?? Data())
    requests.append(payload)
    var reply: ServerScreenSharingReply
    switch payload.operation {
    case .capabilities:
      reply = .init(status: "available", displays: [.init(id: "display", name: "Display", width: 1920, height: 1080)])
      reply.engines = engines
    case .start, .restart:
      if let failure = startFailure {
        startFailure = nil
        throw failure
      }
      reply = .init(status: v2StartStatus)
      if v2StartStatus == "connecting" { reply.media = StreamHarness.grant }
    case .heartbeat:
      reply = .init(status: heartbeatNotice == nil ? "viewing" : "connecting", message: heartbeatNotice)
    case .stop, .setScale:
      reply = .init(status: "stopped")
    }
    return (
      try JSONEncoder().encode(reply),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

@MainActor
@Observable
final class FakeViewingSession: ScreenSharingV2StartableSession {
  let capabilities: ScreenSharingCapabilities = [.control]
  var presentsTiles = false
  let frames = ScreenSharingFrameMailbox()
  let metrics = ScreenSharingMetrics()
  let controlChannel: ScreenSharingLocalChannel<ScreenSharingControlMessage>
  private let host: ScreenSharingLocalChannel<ScreenSharingControlMessage>
  var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { controlChannel }
  var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { nil }
  var failure: String? { nil }
  var onConnectionChanged: ((String) -> Void)?
  private let startFails: Bool
  private(set) var tokens: [String] = []
  private(set) var closed = false

  init(startFails: Bool) {
    self.startFails = startFails
    (controlChannel, host) = ScreenSharingLocalChannel<ScreenSharingControlMessage>.pair()
  }

  func start(token: String) async throws {
    tokens.append(token)
    if startFails { throw ScreenSharingError.unavailable("The Mac refused the token in this test.") }
  }

  func statistics() async -> [String: String] { [:] }

  func close() {
    closed = true
    controlChannel.close()
    host.close()
  }
}
