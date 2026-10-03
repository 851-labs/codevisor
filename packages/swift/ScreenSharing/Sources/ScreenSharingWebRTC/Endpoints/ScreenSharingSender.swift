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
  private let recovery: ScreenSharingSenderRecovery

  /// Builds the connection, its channels and the video sender on the transport's queue; the
  /// caller's actor only waits.
  public init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions = .init(), connectivity: ScreenSharingICEConfiguration? = nil
  ) async throws {
    let transportCeilingBps = try configuration.validatingTransportCeiling(options.transportCeilingBps)
    if let ceiling = transportCeilingBps { metrics.label("transportCeiling", "\(ceiling) bps") }
    metrics.label("sourceAdaptation", options.maintainSourceRate ? "never adapt" : "maintain resolution")
    let (staged, frameSender) = try await ScreenSharingPeerStaging.make(
      configuration: configuration, metrics: metrics, options: options, connectivity: connectivity
    ) { factory, connection, codecFactory, transport in
      let source = factory.videoSource(forScreenCast: true)
      let frameSender = ScreenSharingFrameSender(
        source: source, metrics: metrics, idleMonitor: codecFactory.sourceIdleMonitor, releaseQueue: transport.queue)
      frameSender.configure(configuration)
      let track = factory.videoTrack(with: source, trackId: "screen")
      transport.retain(track)
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
      if let directionError { throw directionError }
      let parameters = transceiver.sender.parameters
      parameters.degradationPreference = NSNumber(
        value: (options.maintainSourceRate
          ? RTCDegradationPreference.maintainFramerateAndResolution : .maintainResolution).rawValue)
      for encoding in parameters.encodings {
        encoding.maxBitrateBps = NSNumber(value: configuration.bitrate)
        encoding.maxFramerate = NSNumber(value: configuration.framesPerSecond)
      }
      transceiver.sender.parameters = parameters
      connection.setBweMinBitrateBps(
        100_000, currentBitrateBps: NSNumber(value: configuration.bitrate),
        maxBitrateBps: NSNumber(value: transportCeilingBps ?? configuration.bitrate))
      return frameSender
    }
    self.frameSender = frameSender
    recovery = ScreenSharingSenderRecovery(
      metrics: metrics, codecFactory: staged.codecFactory, frameSender: frameSender, videoRefresh: staged.videoRefresh)
    super.init(staged: staged)
    frameSender.onActivity { [weak self] in Task { @MainActor in self?.recovery.activate() } }
  }

  /// The source format changes now (the capture's next frames must match it); the encoder's
  /// ceilings are applied on the transport's queue, in order with any earlier change.
  public func updateVideoConfiguration(_ configuration: ScreenSharingVideoConfiguration) {
    guard !closed else { return }
    frameSender.configure(configuration)
    let framesPerSecond = configuration.framesPerSecond
    let bitrate = configuration.bitrate
    transport.run { connection in
      for sender in connection.senders where sender.track?.kind == "video" {
        let parameters = sender.parameters
        for encoding in parameters.encodings {
          encoding.maxFramerate = NSNumber(value: framesPerSecond)
          encoding.maxBitrateBps = NSNumber(value: bitrate)
        }
        sender.parameters = parameters
      }
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
    // Releases the source on the transport's queue, ahead of the connection's teardown.
    frameSender.stop()
  }
}
