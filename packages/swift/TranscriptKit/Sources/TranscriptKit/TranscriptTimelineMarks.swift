import CoreGraphics

public struct TranscriptTimelineMarks: Sendable, Equatable, Hashable {
  public let startsLine: Bool
  public let endsLine: Bool
  public let railAbove: Bool
  public let railBelow: Bool

  public init(startsLine: Bool, endsLine: Bool, railAbove: Bool, railBelow: Bool) {
    self.startsLine = startsLine
    self.endsLine = endsLine
    self.railAbove = railAbove
    self.railBelow = railBelow
  }

  public static let gutterWidth: CGFloat = 26
  public static let linePadding: CGFloat = 6
  public static let railWidth: CGFloat = 1.5
  public static let railX: CGFloat = 9
  public static let nodeCenterY: CGFloat = linePadding + 8
  public static let nodeClearance: CGFloat = 2.5
  public static let dotDiameter: CGFloat = 5
}
