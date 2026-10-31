import CoreVideo
import ScreenSharing

public enum ScreenSharingV2Profile {
  public static let codec = ScreenSharingVideoCodec.hevc
  public static let capturePixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  public static let decodedPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  public static let captureBox = (width: 2560.0, height: 1440.0)
  public static let framesPerSecond = 60
  public static let bitrateCeiling = 45_000_000
  public static let minimumBitrate = 1_000_000
  public static let tileCount = 1
  public static let initialEstimateKbps: UInt32 = 100_000

  public static var frameIntervalUs: UInt32 { UInt32(1_000_000 / framesPerSecond) }

  public static func captureConfiguration(width: Int, height: Int) throws -> ScreenSharingVideoConfiguration {
    let size = captureSize(width: width, height: height)
    return try ScreenSharingVideoConfiguration(
      width: size.width, height: size.height, framesPerSecond: framesPerSecond, bitrate: bitrateCeiling)
  }

  public static func encoderBitrate(ceilingKbps: UInt64) -> Int {
    let ceiling = Int(clamping: ceilingKbps * 1000)
    return min(bitrateCeiling, max(minimumBitrate, ceiling))
  }

  private static func captureSize(width: Int, height: Int) -> (width: Int, height: Int) {
    let scale = min(1, captureBox.width / Double(width), captureBox.height / Double(height))
    return (max(64, Int(Double(width) * scale) / 2 * 2), max(64, Int(Double(height) * scale) / 2 * 2))
  }
}
