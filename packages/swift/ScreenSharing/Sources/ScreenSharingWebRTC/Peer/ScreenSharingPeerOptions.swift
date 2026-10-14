import Foundation
import ScreenSharing

public struct ScreenSharingPeerOptions: Sendable, Equatable {
  public var codec: ScreenSharingVideoCodec = .hevc444
  public var fallbackCodecs: [ScreenSharingVideoCodec] = [.hevc, .h264]
  public var useLowLatencyRateControl = true
  public var disableLookAhead = false
  public var maximumPendingFrames = 3
  public var staticCodecRate = false
  public var completeEachFrame = false
  public var prioritizeSpeed = false
  public var keyframeIntervalSeconds = 60
  public var maintainSourceRate = true
  public var transportCeilingBps: Int?
  public var sourceIdleThresholdNs: Int64?
  public var deliveryGrace: Duration?
  public var deliveryGraceExtensions: Int?

  public init() {}
}

extension ScreenSharingVideoConfiguration {
  func validatingTransportCeiling(_ ceiling: Int?) throws -> Int? {
    guard let ceiling else { return nil }
    guard (bitrate...500_000_000).contains(ceiling) else {
      throw ScreenSharingError.invalid("Transport ceiling must be at least the video bitrate and at most 500 Mbps.")
    }
    return ceiling
  }
}
