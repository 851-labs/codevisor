import Foundation

/// How many remote pixels per point Dynamic Resolution asks for (851-2340):
/// the window's backing scale (2 on a Retina display), unless the link is too
/// slow for four times the pixels. Two thresholds keep it from flapping; until
/// the link is measured it trusts the display.
public struct ScreenSharingDynamicResolution: Sendable, Equatable {
  /// Below this measured rate a Retina pane drops to 1× pixels.
  public static let oneXBelowBitsPerSecond = 15_000_000.0
  /// Above this it goes back to 2×.
  public static let twoXAboveBitsPerSecond = 25_000_000.0

  public private(set) var scale: Int?

  public init() {}

  /// The scale for this backing scale and link; updates the remembered tier.
  public mutating func scale(backingScale: CGFloat, bitsPerSecond: Double?) -> Int {
    guard backingScale >= 2 else {
      scale = 1
      return 1
    }
    let next: Int
    switch (scale, bitsPerSecond) {
    case (_, nil): next = scale ?? 2
    case (2?, let rate?): next = rate < Self.oneXBelowBitsPerSecond ? 1 : 2
    case (1?, let rate?): next = rate > Self.twoXAboveBitsPerSecond ? 2 : 1
    case (_, let rate?): next = rate < Self.oneXBelowBitsPerSecond ? 1 : 2
    }
    scale = next
    return next
  }

  /// "2× · dynamic" / "1× · dynamic, slow link" / "fixed", for Connection Details.
  public static func label(enabled: Bool, scale: Int?, backingScale: CGFloat, slowLink: Bool) -> String {
    guard enabled else { return "fixed size" }
    guard let scale else { return "dynamic" }
    return scale == 1 && backingScale >= 2 && slowLink ? "dynamic · 1× (slow link)" : "dynamic · \(scale)×"
  }
}
