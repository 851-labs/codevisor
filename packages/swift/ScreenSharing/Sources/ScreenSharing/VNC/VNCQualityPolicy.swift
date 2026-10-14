import Foundation

public struct VNCQualityPolicy: Sendable, Equatable {
  public static let jpegQuality = 8
  public static let lossyBelowBitsPerSecond = 16_000_000.0
  public static let losslessAboveBitsPerSecond = 24_000_000.0
  public static let slowLinkJPEGQuality = 4
  public static let slowLinkBelowBitsPerSecond = 2_000_000.0
  public static let slowLinkAboveBitsPerSecond = 3_000_000.0
  public static let minimumSampleBytes = 64 * 1024
  public static let minimumUpdateBytes = 4 * 1024
  static let smoothing = 0.3
  static let samplesBeforeDeciding = 3

  public private(set) var qualityLevel: Int?
  public private(set) var bitsPerSecond: Double?
  private var samples = 0
  private var pendingBytes = 0
  private var pendingSeconds = 0.0

  public init(qualityLevel: Int? = nil) { self.qualityLevel = qualityLevel }

  public mutating func observe(bytes: Int, duration: Duration) -> Int?? {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    guard bytes >= Self.minimumUpdateBytes, seconds > 0 else { return nil }
    pendingBytes += bytes
    pendingSeconds += seconds
    guard pendingBytes >= Self.minimumSampleBytes else { return nil }
    let rate = Double(pendingBytes) * 8 / pendingSeconds
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

  public var detail: String {
    guard let bitsPerSecond else { return description }
    return "\(description) · ≈\(String(format: "%.1f", bitsPerSecond / 1_000_000)) Mbit/s"
  }
}
