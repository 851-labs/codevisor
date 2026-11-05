import CodevisorTestSupport
import Foundation
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2LocalConnectionTests {
  private static let endpoint = String(repeating: "a", count: 64)

  private func link() throws -> ScreenSharingV2HostLink {
    let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360)
    return ScreenSharingV2HostLink(configuration: configuration, metrics: ScreenSharingMetrics()) { configuration, _ in
      RecordingTileEncoder(
        layout: ScreenSharingV2TileLayout(width: configuration.width, height: configuration.height, count: 1))
    }
  }

  @Test func aViewerInTheHostsAppReachesItsSessionInMemoryAndTradesSimulatorMessages() async throws {
    let router = ScreenSharingV2SessionRouter()
    let ticket = router.expect(endpointId: Self.endpoint, token: "token")
    #expect(router.connectLocally(token: "another") == nil)
    let host = try link()
    let viewer = try #require(router.connectLocally(token: "token"))
    let session = ScreenSharingV2ViewingSession(connection: viewer)
    defer {
      session.close()
      host.close()
    }
    var received: [ScreenSharingSimulatorMessage] = []
    let arrived = TestSignal()
    host.linkChannels.simulator.onMessage = {
      received.append($0)
      arrived.signal()
    }
    let state = TestSignal()
    var states: [ScreenSharingSimulatorMessage] = []
    session.simulator.onMessage = {
      states.append($0)
      state.signal()
    }

    async let started: Void = session.start(token: "token")
    try await host.accept(try await router.connection(ticket, timeout: .seconds(10))) { $0 == "token" ? nil : "wrong" }
    try await started

    #expect(session.simulator.send(.button(name: "home", down: true)))
    await arrived.cancellableWait()
    #expect(received == [.button(name: "home", down: true)])
    #expect(host.linkChannels.simulator.send(.rotate(.landscapeLeft)))
    await state.cancellableWait()
    #expect(states == [.rotate(.landscapeLeft)])
  }

  @Test func sessionsSharingAViewerEndpointEachGetTheConnectionWhoseHelloNamesThem() async throws {
    let router = ScreenSharingV2SessionRouter()
    let first = router.expect(endpointId: Self.endpoint, token: "first")
    let second = router.expect(endpointId: Self.endpoint, token: "second")
    let (secondHost, secondViewer) = ScreenSharingV2LocalConnection.pair(endpointId: Self.endpoint)
    let (firstHost, firstViewer) = ScreenSharingV2LocalConnection.pair(endpointId: Self.endpoint)
    let secondSession = ScreenSharingV2ViewingSession(connection: secondViewer)
    let firstSession = ScreenSharingV2ViewingSession(connection: firstViewer)
    let firstLink = try link()
    let secondLink = try link()
    defer {
      for session in [firstSession, secondSession] { session.close() }
      for link in [firstLink, secondLink] { link.close() }
    }

    async let secondStarted: Void = secondSession.start(token: "second")
    async let firstStarted: Void = firstSession.start(token: "first")
    await router.deliver(secondHost)
    await router.deliver(firstHost)
    try await secondLink.accept(try await router.connection(second, timeout: .seconds(10))) {
      $0 == "second" ? nil : "wrong session"
    }
    try await firstLink.accept(try await router.connection(first, timeout: .seconds(10))) {
      $0 == "first" ? nil : "wrong session"
    }
    try await secondStarted
    try await firstStarted
  }

  @Test func aConnectionFromAnotherEndpointOrForNoSessionIsClosed() async throws {
    let router = ScreenSharingV2SessionRouter()
    _ = router.expect(endpointId: Self.endpoint, token: "token")
    let (host, viewer) = ScreenSharingV2LocalConnection.pair(endpointId: String(repeating: "b", count: 64))
    let session = ScreenSharingV2ViewingSession(connection: viewer)
    defer { session.close() }

    let started = Task { try await session.start(token: "token") }
    await router.deliver(host)
    await #expect(throws: (any Error).self) { try await started.value }
    #expect(await host.closed() == "no screen-sharing session expects this viewer")
  }

  @Test func theHostWaitsWhileTheViewerFallsBehindAndAFrameTheViewerTakesIsAcknowledged() async throws {
    let (host, viewer) = ScreenSharingV2LocalMediaTransport.pair()
    defer {
      host.close()
      viewer.close()
    }
    let big = Data(count: ScreenSharingV2LocalMediaTransport.backlogLimit)
    try host.send(Self.tile(big, ltrToken: 7), meta: Data([1, 2]))
    #expect(host.admission().admit == false)

    guard case .frame(let frame) = await viewer.nextEvent() else { Issue.record("Expected a frame"); return }
    #expect(
      (frame.stream, frame.frame, frame.ltrToken, frame.meta, frame.payload.count) == (
        0, 0, 7, Data([1, 2]), big.count
      ))
    #expect(host.admission().admit)
    guard case .frameAcked(let ack) = await host.nextEvent() else { Issue.record("Expected an ack"); return }
    #expect((ack.stream, ack.frame) == (0, 0))

    viewer.acknowledge(ltrToken: 7, stream: 0)
    guard case .ltrAcked(0, 7) = await host.nextEvent() else { Issue.record("Expected an LTR ack"); return }
  }

  @Test func closingTheConnectionEndsBothSidesStreamsAndMedia() async throws {
    let (host, viewer) = ScreenSharingV2LocalConnection.pair(endpointId: Self.endpoint)
    let stream = try await viewer.openStream()
    let accepted = try await host.acceptStream()
    let media = await host.openMedia()

    viewer.close("viewer closed")

    #expect(await host.closed() == "viewer closed")
    #expect(try await accepted.receive() == nil)
    await #expect(throws: (any Error).self) { try await stream.send(Data([1])) }
    #expect(await media.nextEvent().map { _ in true } == nil)
    await #expect(throws: (any Error).self) { try await host.acceptStream() }
  }

  private static func tile(_ payload: Data, ltrToken: UInt64? = nil) -> ScreenSharingEncodedTile {
    ScreenSharingEncodedTile(
      tile: 0, update: ScreenSharingTileUpdate(id: 1, tiles: [0]), sourceTimestampNs: 1, capturedNs: 1,
      submittedNs: 1, encodedNs: 1, isKeyFrame: true, refresh: nil, ltrToken: ltrToken,
      accessUnit: ScreenSharingAccessUnit(payload))
  }
}

extension HardwareCodecTests {
  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingV2LocalMediaTests {
    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC on this machine."))
    func framesCrossTheInMemoryTransportAndDecodeInOrder() async throws {
      let (hostTransport, viewerTransport) = ScreenSharingV2LocalMediaTransport.pair()
      let metrics = ScreenSharingMetrics()
      let encoder = try ScreenSharingVideoToolboxTileEncoder(
        configuration: try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360), metrics: metrics)
      let host = ScreenSharingV2Host(
        transport: hostTransport, encoder: encoder, metrics: metrics,
        initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: ManualScheduler())
      let viewer = ScreenSharingV2Viewer(transport: viewerTransport, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      defer {
        host.stop()
        viewer.stop()
      }

      for index in 1...3 {
        host.push(try TestPixels.frame(shade: UInt8(index * 40), timestampNs: Int64(index) * 1_000))
        await decoded.arrivals.cancellableWait(for: index)
      }

      #expect(decoded.sourceTimestamps == [1_000, 2_000, 3_000])
    }
  }
}
