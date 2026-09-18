import Foundation
import ScreenSharing

/// Every knob a sender or receiver accepts beyond its video configuration.
/// The defaults are the product's settings; everything else is a diagnostic
/// experiment the probe and the rig can select. `nil` means "the product
/// default" for the optional thresholds.
public struct ScreenSharingPeerOptions: Sendable, Equatable {
  public var codec: ScreenSharingVideoCodec = .h264
  /// Encoder: VideoToolbox low-latency rate control (the product) or standard.
  public var useLowLatencyRateControl = true
  public var disableLookAhead = false
  public var maximumPendingFrames = 2
  public var staticCodecRate = false
  public var completeEachFrame = false
  public var prioritizeSpeed = false
  public var keyframeIntervalSeconds = 2
  /// Sender: keep the capture format instead of letting WebRTC adapt resolution.
  public var maintainSourceRate = false
  /// Sender: lets the bandwidth estimator's cap exceed the encoder's target, which
  /// stays capped at the configured bitrate. nil keeps the product's single ceiling.
  public var transportCeilingBps: Int?
  /// Sender: the idle threshold after which the latest capture is announced.
  public var sourceIdleThresholdNs: Int64?
  /// Receiver: how long a shortfall may persist before a refresh is requested, and how often the grace extends.
  public var deliveryGrace: Duration?
  public var deliveryGraceExtensions: Int?

  public init() {}
}

extension ScreenSharingVideoConfiguration {
  /// A diagnostic estimator ceiling must cover the configured bitrate and stay within reason.
  func validatingTransportCeiling(_ ceiling: Int?) throws -> Int? {
    guard let ceiling else { return nil }
    guard (bitrate...500_000_000).contains(ceiling) else {
      throw ScreenSharingError.invalid("Transport ceiling must be at least the video bitrate and at most 500 Mbps.")
    }
    return ceiling
  }
}
