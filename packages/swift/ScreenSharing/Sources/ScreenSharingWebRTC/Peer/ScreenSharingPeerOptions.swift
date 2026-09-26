import Foundation
import ScreenSharing

/// Every knob a sender or receiver accepts beyond its video configuration.
/// The defaults are the product's settings; everything else is a diagnostic
/// experiment the probe and the rig can select. `nil` means "the product
/// default" for the optional thresholds.
public struct ScreenSharingPeerOptions: Sendable, Equatable {
  /// Preferred codec: HEVC Main 4:4:4 on Apple silicon (851-2370 targets it only), so coloured
  /// text keeps its chroma (851-2381).
  public var codec: ScreenSharingVideoCodec = .hevc444
  /// Also offered, for a peer that can't use `codec`: an app from before 851-2381 speaks HEVC
  /// Main, one from before 851-2372 H.264 only.
  public var fallbackCodecs: [ScreenSharingVideoCodec] = [.hevc, .h264]
  /// Encoder: VideoToolbox low-latency rate control (the product) or standard.
  public var useLowLatencyRateControl = true
  public var disableLookAhead = false
  public var maximumPendingFrames = 2
  public var staticCodecRate = false
  public var completeEachFrame = false
  public var prioritizeSpeed = false
  /// A 4:4:4 keyframe is ~1 MB at 1760×1416, 20–30 deltas' worth; every frame behind it waits.
  /// Every 2 s, on tuftlord over Tailscale, that held image age at 250–540 ms (2026-09-26); the
  /// LAN rig study found the same (docs/plans/screen-sharing-rig.md, rows H → J). A viewer asks
  /// for a keyframe when it needs one (loss, refresh), so periodic ones only cost latency.
  public var keyframeIntervalSeconds = 60
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
