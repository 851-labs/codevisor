import Foundation
@preconcurrency import WebRTC
import ScreenSharing

/// The host's end of a native session: the screen video track fed by
/// `frameSender`, the encoder's bitrate/framerate ceilings, and the host-side
/// recovery (keyframe requests answered, the latest capture announced when the
/// source goes idle).
@MainActor
public final class ScreenSharingSender: ScreenSharingPeer {
  public nonisolated let frameSender: ScreenSharingFrameSender
  private let source: RTCVideoSource
  private let recovery: ScreenSharingSenderRecovery
  private let transportCeilingBps: Int?

  public init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions = .init(), connectivity: ScreenSharingICEConfiguration? = nil
  ) throws {
    transportCeilingBps = try configuration.validatingTransportCeiling(options.transportCeilingBps)
    if let ceiling = transportCeilingBps { metrics.label("transportCeiling", "\(ceiling) bps") }
    // The base needs the factory before the source exists; the source needs the factory. Resolve in order.
    let staged = try ScreenSharingPeerStaging(
      configuration: configuration, metrics: metrics, options: options, connectivity: connectivity)
    source = staged.factory.videoSource(forScreenCast: true)
    let frameSender = ScreenSharingFrameSender(
      source: source, metrics: metrics, idleMonitor: staged.codecFactory.sourceIdleMonitor)
    self.frameSender = frameSender
    frameSender.configure(configuration)
    recovery = ScreenSharingSenderRecovery(
      metrics: metrics, codecFactory: staged.codecFactory, frameSender: frameSender, videoRefresh: staged.videoRefresh)
    super.init(staged: staged)
    let track = factory.videoTrack(with: source, trackId: "screen")
    // addTrack permits the remote viewer's offer to associate this sender
    // with its video m-line. An explicit unassociated addTransceiver stays
    // separate when answering, leaving ICE connected with no media sender.
    guard let sender = connection.add(track, streamIds: ["screen"]),
      let transceiver = connection.transceivers.first(where: { $0.sender.senderId == sender.senderId })
    else {
      throw ScreenSharingError.unavailable("Cannot create screen video sender.")
    }
    var directionError: NSError?
    transceiver.setDirection(.sendOnly, error: &directionError)
    if let directionError { connection.close(); throw directionError }
    let parameters = transceiver.sender.parameters
    parameters.degradationPreference = NSNumber(
      value: (options.maintainSourceRate
        ? RTCDegradationPreference.maintainFramerateAndResolution : .maintainResolution).rawValue)
    metrics.label("sourceAdaptation", options.maintainSourceRate ? "fixed format experiment" : "maintain resolution")
    for encoding in parameters.encodings {
      encoding.maxBitrateBps = NSNumber(value: configuration.bitrate)
      encoding.maxFramerate = NSNumber(value: configuration.framesPerSecond)
    }
    transceiver.sender.parameters = parameters
    connection.setBweMinBitrateBps(
      100_000, currentBitrateBps: NSNumber(value: configuration.bitrate),
      maxBitrateBps: NSNumber(value: transportCeilingBps ?? configuration.bitrate))
    frameSender.onActivity { [weak self] in Task { @MainActor in self?.recovery.activate() } }
  }

  public func updateVideoConfiguration(_ configuration: ScreenSharingVideoConfiguration) {
    guard !closed else { return }
    frameSender.configure(configuration)
    for sender in connection.senders where sender.track?.kind == "video" {
      let parameters = sender.parameters
      for encoding in parameters.encodings {
        encoding.maxFramerate = NSNumber(value: configuration.framesPerSecond)
        encoding.maxBitrateBps = NSNumber(value: configuration.bitrate)
      }
      sender.parameters = parameters
    }
    metrics.label("captureSize", "\(configuration.width) × \(configuration.height)")
    metrics.label("captureFPS", String(configuration.framesPerSecond))
  }

  override func handleRefresh(_ message: ScreenSharingVideoRefreshMessage) {
    recovery.handle(message)
  }

  override func refreshChannelBecameAvailable() {
    recovery.flush()
  }

  override func willClose() {
    codecFactory.refreshSignal.close()
    ownedWork.close(with: recovery.close())
    codecFactory.sourceIdleMonitor.stop()
    frameSender.stop()
  }
}
