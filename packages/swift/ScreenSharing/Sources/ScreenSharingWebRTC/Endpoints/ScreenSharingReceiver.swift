import Foundation
@preconcurrency import WebRTC
import ScreenSharing

/// The viewer's end of a native session: the decoded-frame mailbox fed by the
/// remote track's renderer, and the viewer-side recovery (keyframe requests
/// on decoder loss, verification of the host's idle notices). It is the
/// `ScreenSharingViewingSession` a viewer feature renders from.
@MainActor
public final class ScreenSharingReceiver: ScreenSharingPeer, ScreenSharingViewingSession {
  public let mailbox: ScreenSharingFrameMailbox
  /// Receiver-only diagnostic frame-delivery audit (nil = disabled); closed with the peer.
  public let frameDeliveryAudit: ScreenSharingFrameDeliveryAudit?
  private let renderer: ScreenSharingPeerRenderer
  private let recovery: ScreenSharingReceiverRecovery
  private var remoteTrack: RTCVideoTrack?

  public init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions = .init(), connectivity: ScreenSharingICEConfiguration? = nil,
    frameDeliveryAudit: ScreenSharingFrameDeliveryAudit? = nil
  ) throws {
    self.frameDeliveryAudit = frameDeliveryAudit
    let staged = try ScreenSharingPeerStaging(
      configuration: configuration, metrics: metrics, options: options, connectivity: connectivity,
      frameDeliveryAudit: frameDeliveryAudit)
    let mailbox = ScreenSharingFrameMailbox()
    self.mailbox = mailbox
    renderer = ScreenSharingPeerRenderer(mailbox: mailbox, metrics: metrics, audit: frameDeliveryAudit)
    recovery = ScreenSharingReceiverRecovery(
      metrics: metrics, codecFactory: staged.codecFactory, videoRefresh: staged.videoRefresh,
      grace: options.deliveryGrace, graceExtensions: options.deliveryGraceExtensions)
    super.init(staged: staged)
    let transceiver = RTCRtpTransceiverInit()
    transceiver.direction = .recvOnly
    guard connection.addTransceiver(of: .video, init: transceiver) != nil else {
      throw ScreenSharingError.unavailable("Cannot create screen video receiver.")
    }
    codecFactory.refreshSignal.request()
  }

  // MARK: ScreenSharingViewingSession

  public var capabilities: ScreenSharingCapabilities { [.control, .clipboard, .statistics] }
  public var frames: ScreenSharingFrameMailbox { mailbox }
  public var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { controlChannel }
  public var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { clipboardChannel }
  public var failure: String? { metrics.snapshot().labels["decoderError"] }

  // MARK: Diagnostics

  /// Package-only fault injection for the standalone recovery probe. The
  /// decoder discards its VT state, then refuses deltas until a fresh keyframe.
  public func simulateDecoderLoss(
    afterFrames: Int, droppingRecoveryKeyframeFrom sender: ScreenSharingSender? = nil,
    idlingCaptureFrom idleSender: ScreenSharingSender? = nil
  ) {
    let dropCheck = sender?.codecFactory.encoderDropCheck
    let idleCapture = idleSender?.frameSender
    let idleMetrics = idleSender?.metrics
    codecFactory.recoveryCheck.arm(afterFrames: afterFrames) {
      dropCheck?.arm()
      idleCapture?.suspendCaptureDelivery()
      idleMetrics?.increment("captureDeliveryStoppedAtDecoderReset")
    }
    sender?.metrics.label("encoderRecoveryExperiment", "discard one forced output after decoder reset")
    idleMetrics?.label("sourceIdleExperiment", "capture delivery stops at decoder reset")
    metrics.label("decoderRecoveryExperiment", "discard reference state after \(afterFrames) input frames")
  }

  // MARK: Role hooks

  override func handleRefresh(_ message: ScreenSharingVideoRefreshMessage) {
    recovery.handle(message)
  }

  override func refreshChannelBecameAvailable() {
    recovery.wake()
  }

  override func remoteTrackArrived(_ track: RTCVideoTrack) {
    remoteTrack?.remove(renderer)
    remoteTrack = track
    track.add(renderer)
  }

  override func willClose() {
    codecFactory.refreshSignal.close()
    ownedWork.close(with: recovery.close())
    codecFactory.sourceIdleMonitor.stop()
    remoteTrack?.remove(renderer)
    renderer.stop()
    remoteTrack = nil
  }

  override func didClose() {
    mailbox.clear()
    frameDeliveryAudit?.close()  // later decoder/VT/RTC/GPU/presented callbacks are counted as late, never recorded
  }
}
