import CoreGraphics
import ScreenSharing
import ScreenSharingWebRTC

@MainActor
final class ShareHost {
  let displayID: CGDirectDisplayID
  private let metrics = ScreenSharingMetrics()
  private let capture = ScreenSharingCapture()
  private let sender: ScreenSharingSender
  private var configuration: ScreenSharingVideoConfiguration
  private var captureTask: Task<Void, Never>?
  private var qualityTask: Task<Void, Never>?
  private var capturing = false
  private var captureError: (any Error)?
  private var connectedNs: Int64?
  private var codec: ScreenSharingVideoCodec?

  init(displayID: CGDirectDisplayID) async throws {
    self.displayID = displayID
    let mode = CGDisplayCopyDisplayMode(displayID)
    configuration = try ScreenSharingProductProfile.captureConfiguration(
      width: mode?.pixelWidth ?? CGDisplayPixelsWide(displayID),
      height: mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID))
    sender = try await ScreenSharingSender(configuration: configuration, metrics: metrics)
    sender.onConnectionChanged = { [weak self] state in self?.connectionChanged(state) }
  }

  func answer(_ offer: String) async throws -> String {
    try await sender.accept(ScreenSharingDescription(kind: "offer", sdp: offer))
    let answer = try await sender.makeDescription(offer: false)
    codec = ScreenSharingVideoCodec.negotiated(inDescription: answer.sdp)
    if let codec { capture.pixelFormat = codec.capturePixelFormat }
    return answer.sdp
  }

  func finish(viewer: String) async -> ShareResult {
    let statistics = await sender.statistics()
    qualityTask?.cancel()
    await captureTask?.value
    try? await capture.stop()
    sender.close()
    _ = await sender.awaitClosed()
    return ShareResult(
      viewer: viewer, display: ShareDisplay(displayID), codec: codec, configuration: configuration,
      connectedNs: connectedNs,
      captureError: captureError, metrics: metrics.snapshot(), statistics: statistics)
  }

  private func connectionChanged(_ state: String) {
    guard state == "connected", captureTask == nil else { return }

    connectedNs = ScreenSharingMetrics.nowNs
    captureTask = Task { await startCapture() }
  }

  private func startCapture() async {
    do {
      try await capture.start(
        displayID: displayID, configuration: configuration, sink: sender.frameSender, metrics: metrics)
      capturing = true
      qualityTask = Task { await runQualityLoop() }
    } catch {
      captureError = error
    }
  }

  private func runQualityLoop() async {
    await ScreenSharingQualityLoop.run(
      base: { [weak self] in self?.configuration },
      isViewing: { [weak self] in self?.capturing ?? false },
      statistics: { [weak self] in await self?.sender.statistics() ?? [:] },
      apply: { [weak self] configuration, level in await self?.apply(configuration, level: level) ?? false })
  }

  private func apply(_ adjusted: ScreenSharingVideoConfiguration, level: Int) async -> Bool {
    sender.updateVideoConfiguration(adjusted)
    do {
      try await capture.update(configuration: adjusted)
    } catch {
      captureError = error
      return false
    }
    metrics.label("adaptiveQualityLevel", String(level))
    return true
  }
}
