import Foundation
import ScreenSharing

public enum ScreenSharingProductProfile {
  public static let codec = ScreenSharingVideoCodec.hevc444
  public static let fallbackCodecs: [ScreenSharingVideoCodec] = [.hevc, .h264]
  public static let bitrateCeiling = 45_000_000
  public static let captureBox = (width: 2560.0, height: 1440.0)
  public static let keyframeIntervalSeconds = 60
  public static let maximumPendingFrames = 3
  public static let fullQualityBitrate = 6_000_000
  public static let adaptiveQualityWarmUp: TimeInterval = 5
  public static let fieldTrials = [
    "WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0", "WebRTC-Video-Pacing": "factor:10",
    "WebRTC-FrameDropper": "Disabled",
  ]

  public static func captureConfiguration(width: Int, height: Int) throws -> ScreenSharingVideoConfiguration {
    let size = captureSize(width: width, height: height)
    return try ScreenSharingVideoConfiguration(width: size.width, height: size.height, bitrate: bitrateCeiling)
  }

  private static func captureSize(width: Int, height: Int) -> (width: Int, height: Int) {
    let scale = min(1, captureBox.width / Double(width), captureBox.height / Double(height))
    return (max(64, Int(Double(width) * scale) / 2 * 2), max(64, Int(Double(height) * scale) / 2 * 2))
  }
}
