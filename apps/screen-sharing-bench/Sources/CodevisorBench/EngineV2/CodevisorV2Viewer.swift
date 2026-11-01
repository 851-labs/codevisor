import AppKit
import CodevisorNet
import ScreenSharing
import ScreenSharingV2

@MainActor
final class CodevisorV2Viewer {
  private static let connectRetry = Duration.milliseconds(250)
  private static let firstFrameTimeout = Duration.seconds(20)
  private static let firstFramePoll = Duration.milliseconds(20)

  private let endpoint: NetEndpointHandle
  private let connection: NetConnectionHandle
  private let transport: ScreenSharingIrohMediaTransport
  private let viewer: ScreenSharingV2Viewer
  private let surface: V2Surface

  static func run(
    in window: ViewerWindow, host: String, port: UInt16, presentation: V2Presentation,
    until deadline: ContinuousClock.Instant, signals: BenchSignalFiles
  ) async throws -> CodevisorV2ViewResult {
    let signaling = try await SignalingSocket.connect(host: host, port: port, until: deadline, retry: connectRetry)
    let address = try await receive(signaling)
    let viewer = try await CodevisorV2Viewer(host: host, address: address, presentation: presentation)
    window.show(viewer.surface.view)
    defer { viewer.stop() }

    try await viewer.waitForFirstFrame()
    try signals.markReady("presenting")
    await BenchSession.hold(signaling, until: deadline, signals: signals)
    return viewer.result(host: host, presentation: presentation)
  }

  private init(host: String, address: V2EndpointMessage, presentation: V2Presentation) async throws {
    let endpoint = try await V2Endpoint.bind()
    let connection = try await endpoint.connect(
      addr: address.addr(reachingHost: host), alpn: mediaAlpn(), cancel: nil)
    let transport = ScreenSharingIrohMediaTransport(
      session: await connection.openMediaSession(config: ScreenSharingIrohMediaTransport.sessionConfig))
    let viewer = ScreenSharingV2Viewer(transport: transport, metrics: ScreenSharingMetrics())
    viewer.frames.retainsLatest = true
    do {
      surface = try V2Surface(presentation, mailbox: viewer.frames, metrics: viewer.metrics)
    } catch {
      viewer.stop()
      connection.close(code: 0, reason: "viewer setup failed")
      await endpoint.close()
      throw error
    }
    self.endpoint = endpoint
    self.connection = connection
    self.transport = transport
    self.viewer = viewer
    viewer.start()
  }

  private func waitForFirstFrame() async throws {
    let limit = ContinuousClock.now + Self.firstFrameTimeout
    while viewer.metrics.counter("presentationCallbacks") == 0 {
      guard ContinuousClock.now < limit else { throw SignalingError.timedOut("waiting for the first frame") }

      try await Task.sleep(for: Self.firstFramePoll)
    }
  }

  private func result(host: String, presentation: V2Presentation) -> CodevisorV2ViewResult {
    CodevisorV2ViewResult(
      host: host, presentation: presentation, metrics: viewer.metrics, droppedFrames: viewer.frames.droppedFrames,
      media: V2MediaStatistics.dictionary(transport.session.stats()),
      paths: connection.paths().map { "\($0.isRelay ? "relay" : "direct") \($0.remote) \($0.rttMs) ms" })
  }

  private func stop() {
    surface.stop()
    viewer.stop()
    connection.close(code: 0, reason: "done")
  }

  @concurrent
  private static func receive(_ connection: SignalingConnection) async throws -> V2EndpointMessage {
    try connection.receive(V2EndpointMessage.self)
  }
}
