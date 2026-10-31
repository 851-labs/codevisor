import CodevisorNet
import CoreGraphics
import ScreenSharing
import ScreenSharingV2

@MainActor
final class ShareV2Host {
  private let displayID: CGDirectDisplayID
  private let metrics = ScreenSharingMetrics()
  private let capture = ScreenSharingCapture(pixelFormat: ScreenSharingV2Profile.capturePixelFormat)
  private let configuration: ScreenSharingVideoConfiguration
  private let endpoint: NetEndpointHandle
  private var connection: NetConnectionHandle?
  private var transport: ScreenSharingIrohMediaTransport?
  private var host: ScreenSharingV2Host?
  private var captureError: (any Error)?

  init(displayID: CGDirectDisplayID) async throws {
    self.displayID = displayID
    let mode = CGDisplayCopyDisplayMode(displayID)
    configuration = try ScreenSharingV2Profile.captureConfiguration(
      width: mode?.pixelWidth ?? CGDisplayPixelsWide(displayID),
      height: mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID))
    endpoint = try await V2Endpoint.bind()
  }

  var address: V2EndpointMessage { V2EndpointMessage(endpoint.addr()) }

  func accept(until deadline: ContinuousClock.Instant) async throws {
    guard let connection = try await V2Accept.connection(on: endpoint, until: deadline) else {
      throw SignalingError.closed
    }

    self.connection = connection
    let transport = ScreenSharingIrohMediaTransport(
      session: await connection.openMediaSession(config: ScreenSharingIrohMediaTransport.sessionConfig))
    let encoder = try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, metrics: metrics)
    let host = ScreenSharingV2Host(transport: transport, encoder: encoder, metrics: metrics)
    self.transport = transport
    self.host = host
    host.start()
    await startCapture(into: host)
  }

  func finish(viewer: String) async -> ShareV2Result {
    let statistics = transport.map { V2MediaStatistics.dictionary($0.session.stats()) } ?? [:]
    try? await capture.stop()
    host?.stop()
    connection?.close(code: 0, reason: "done")
    await endpoint.close()
    return ShareV2Result(
      viewer: viewer, display: ShareDisplay(displayID), configuration: configuration, captureError: captureError,
      metrics: metrics.snapshot(), media: statistics)
  }

  private func startCapture(into host: ScreenSharingV2Host) async {
    do {
      try await capture.start(displayID: displayID, configuration: configuration, sink: host, metrics: metrics)
    } catch {
      captureError = error
    }
  }
}
