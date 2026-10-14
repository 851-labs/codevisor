import Foundation

public struct ScreenSharingDynamicResolution: Sendable, Equatable {
  public static let oneXBelowBitsPerSecond = 15_000_000.0
  public static let twoXAboveBitsPerSecond = 25_000_000.0

  public private(set) var scale: Int?

  public init() {}

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

  public static func label(enabled: Bool, scale: Int?, backingScale: CGFloat, slowLink: Bool) -> String {
    guard enabled else { return "fixed size" }
    guard let scale else { return "dynamic" }
    return scale == 1 && backingScale >= 2 && slowLink ? "dynamic · 1× (slow link)" : "dynamic · \(scale)×"
  }
}
