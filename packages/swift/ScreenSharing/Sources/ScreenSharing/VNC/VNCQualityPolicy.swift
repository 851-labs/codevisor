import Foundation

/// When Tight may use JPEG (851-2313), after TigerVNC's own AutoSelect:
/// lossless while the link is fast, JPEG at quality 8 when it is slow. The
/// bandwidth is estimated from large updates (bytes over the time they took
/// to arrive) and smoothed; two thresholds keep it from flapping.
public struct VNCQualityPolicy: Sendable, Equatable {
  public static let jpegQuality = 8
  /// Below this sustained rate the session asks for JPEG.
  public static let lossyBelowBitsPerSecond = 16_000_000.0
  /// Above this it goes back to lossless.
  public static let losslessAboveBitsPerSecond = 24_000_000.0
  /// Smaller updates time too noisily to say anything about the link.
  public static let minimumSampleBytes = 64 * 1024
  static let smoothing = 0.3
  static let samplesBeforeDeciding = 3

  public private(set) var qualityLevel: Int?
  public private(set) var bitsPerSecond: Double?
  private var samples = 0

  public init(qualityLevel: Int? = nil) { self.qualityLevel = qualityLevel }

  /// Feeds one update; returns the new quality level when it changes (`.some(nil)` is lossless).
  public mutating func observe(bytes: Int, duration: Duration) -> Int?? {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    guard bytes >= Self.minimumSampleBytes, seconds > 0 else { return nil }
    let rate = Double(bytes) * 8 / seconds
    bitsPerSecond = bitsPerSecond.map { $0 + Self.smoothing * (rate - $0) } ?? rate
    samples += 1
    guard samples >= Self.samplesBeforeDeciding, let estimate = bitsPerSecond else { return nil }
    if qualityLevel == nil, estimate < Self.lossyBelowBitsPerSecond {
      qualityLevel = Self.jpegQuality
      return .some(qualityLevel)
    }
    if qualityLevel != nil, estimate > Self.losslessAboveBitsPerSecond {
      qualityLevel = nil
      return .some(nil)
    }
    return nil
  }

  public var description: String { qualityLevel.map { "JPEG \($0)" } ?? "lossless" }
}
