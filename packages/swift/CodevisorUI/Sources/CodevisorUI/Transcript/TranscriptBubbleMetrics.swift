import CoreGraphics

public nonisolated enum TranscriptBubbleMetrics {
  public static let oppositeSideGap: CGFloat = 40

  public static func maxWidth(inRow rowWidth: CGFloat) -> CGFloat {
    max(1, rowWidth - oppositeSideGap)
  }

  public static func contentWidth(inRow rowWidth: CGFloat, horizontalInset: CGFloat) -> CGFloat {
    max(1, maxWidth(inRow: rowWidth) - horizontalInset * 2)
  }
}
