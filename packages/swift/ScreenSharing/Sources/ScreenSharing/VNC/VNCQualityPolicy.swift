import Foundation

/// When Tight may use JPEG (851-2313), after TigerVNC's own AutoSelect:
/// lossless while the link is fast, JPEG at quality 8 when it is slow, and
/// quality 4 when it is very slow (851-2329: a ~1 Mbit/s route to a VPS, where
/// quality 4 cut bytes per update 2.6× and doubled the drag rate). The
/// bandwidth is estimated from large updates (bytes over the time they took
/// to arrive: only while the reader waited for the network, 851-2331) and
/// smoothed; two thresholds keep it from flapping.
public struct VNCQualityPolicy: Sendable, Equatable {
  public static let jpegQuality = 8
  /// Below this sustained rate the session asks for JPEG.
  public static let lossyBelowBitsPerSecond = 16_000_000.0
  /// Above this it goes back to lossless.
  public static let losslessAboveBitsPerSecond = 24_000_000.0
  public static let slowLinkJPEGQuality = 4
  /// Below this sustained rate the session asks for the lower JPEG quality…
  public static let slowLinkBelowBitsPerSecond = 2_000_000.0
  /// …and above this it goes back to `jpegQuality`.
  public static let slowLinkAboveBitsPerSecond = 3_000_000.0
  /// Bytes per sample: updates are pooled until they add up to this (851-2329:
  /// on a slow link most updates are 6–24 KB, so single updates rarely qualify).
  public static let minimumSampleBytes = 64 * 1024
  /// Samples smaller than this are mostly one packet's latency, not bandwidth.
  public static let minimumUpdateBytes = 4 * 1024
  static let smoothing = 0.3
  static let samplesBeforeDeciding = 3

  public private(set) var qualityLevel: Int?
  public private(set) var bitsPerSecond: Double?
  private var samples = 0
  private var pendingBytes = 0
  private var pendingSeconds = 0.0

  public init(qualityLevel: Int? = nil) { self.qualityLevel = qualityLevel }

  /// Feeds one update; returns the new quality level when it changes (`.some(nil)` is lossless).
  public mutating func observe(bytes: Int, duration: Duration) -> Int?? {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    guard bytes >= Self.minimumUpdateBytes, seconds > 0 else { return nil }
    pendingBytes += bytes
    pendingSeconds += seconds
    guard pendingBytes >= Self.minimumSampleBytes else { return nil }
    let rate = Double(pendingBytes) * 8 / pendingSeconds
    // A sample counts by its size (851-2331): over WebSocket, samples come from
    // large updates that span several messages (typically the first full
    // frame), so one big frame can settle the quality.
    let weight = pendingBytes / Self.minimumSampleBytes
    pendingBytes = 0
    pendingSeconds = 0
    bitsPerSecond = bitsPerSecond.map { $0 + Self.smoothing * (rate - $0) } ?? rate
    samples += weight
    guard samples >= Self.samplesBeforeDeciding, let estimate = bitsPerSecond else { return nil }
    let next = Self.level(for: estimate, current: qualityLevel)
    guard next != qualityLevel else { return nil }
    qualityLevel = next
    return .some(next)
  }

  /// Each boundary has two thresholds, so an estimate between them keeps the current level.
  static func level(for estimate: Double, current: Int?) -> Int? {
    if estimate > losslessAboveBitsPerSecond { return nil }
    if estimate < slowLinkBelowBitsPerSecond { return slowLinkJPEGQuality }
    switch current {
    case nil: return estimate < lossyBelowBitsPerSecond ? jpegQuality : nil
    case slowLinkJPEGQuality?: return estimate > slowLinkAboveBitsPerSecond ? jpegQuality : slowLinkJPEGQuality
    default: return current
    }
  }

  public var description: String { qualityLevel.map { "JPEG \($0)" } ?? "lossless" }

  /// The level and the link estimate it rests on, for Connection Details (e.g. "JPEG 4 · ≈0.8 Mbit/s").
  public var detail: String {
    guard let bitsPerSecond else { return description }
    return "\(description) · ≈\(String(format: "%.1f", bitsPerSecond / 1_000_000)) Mbit/s"
  }
}
