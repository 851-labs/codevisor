import Foundation

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
  private static let framesPerSecond = [60, 30, 30, 20]

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
      framesPerSecond: min(original.framesPerSecond, Self.framesPerSecond[level]),
      bitrate: original.bitrate)
  }
}
