import Foundation

/// Text-first congestion policy. A sustained two-second shortage lowers one
/// step; fifteen seconds of headroom restores one step. Missing estimates do
/// not change quality, and no decision depends on a wall clock.
///
/// Shortage is measured against `fullQualityBitrate`, what the top level
/// needs, not the configured ceiling: a sender's bandwidth estimate rarely
/// climbs far above what it actually sends, so against a generous ceiling a
/// healthy link looked short and the host sat at 30 fps (851-2372). The first
/// `warmUp` seconds of estimates are ignored while the estimator ramps up.
public struct ScreenSharingAdaptiveQuality {
  public private(set) var level = 0
  private let original: ScreenSharingVideoConfiguration
  private let reference: Double
  private let warmUp: TimeInterval
  private var firstSample: TimeInterval?
  private var candidate: Int?
  private var candidateSince: TimeInterval = 0
  private static let scale = [1.0, 1.0, 0.75, 0.5]
  private static let rate = [1.0, 0.5, 0.3, 0.15]

  /// `fullQualityBitrate` nil: the configured bitrate (the original behaviour).
  public init(configuration: ScreenSharingVideoConfiguration, fullQualityBitrate: Int? = nil, warmUp: TimeInterval = 0)
  {
    original = configuration
    reference = Double(min(configuration.bitrate, fullQualityBitrate ?? configuration.bitrate))
    self.warmUp = warmUp
  }

  public mutating func update(availableBitrate: Double?, now: TimeInterval) -> ScreenSharingVideoConfiguration? {
    guard let availableBitrate, availableBitrate.isFinite, availableBitrate > 0, now.isFinite else {
      candidate = nil; return nil
    }
    // A clock that jumps backwards restarts the warm-up rather than stalling it.
    if let first = firstSample, now >= first {} else { firstSample = now }
    guard now - (firstSample ?? now) >= warmUp else { return nil }
    let fraction = availableBitrate / reference
    let next: Int
    if level < 3, fraction < Self.rate[level] * 0.65 {
      next = level + 1
    } else if level > 0, fraction > Self.rate[level - 1] * 0.9 {
      next = level - 1
    } else {
      candidate = nil; return nil
    }
    if candidate != next || now < candidateSince {
      candidate = next; candidateSince = now; return nil
    }
    guard now - candidateSince >= (next > level ? 2 : 15) else { return nil }
    level = next; candidate = nil
    let scale = Self.scale[level]
    return try? ScreenSharingVideoConfiguration(
      width: max(64, Int(Double(original.width) * scale) / 2 * 2),
      height: max(64, Int(Double(original.height) * scale) / 2 * 2),
      framesPerSecond: min(original.framesPerSecond, level == 0 ? 60 : level == 3 ? 20 : 30),
      bitrate: original.bitrate)
  }
}
