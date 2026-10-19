import CoreGraphics

public struct TranscriptSendFlightGeometry: Equatable, Sendable {
  public static let bubbleTextInsets = (horizontal: CGFloat(12), vertical: CGFloat(8))
  public static let attachmentSpacing: CGFloat = 8

  public let rowOffset: CGSize
  public let bubbleTextHeight: CGFloat

  public let textOrigin: CGPoint

  public init(editorFrame: CGRect, textRect: CGRect, bubbleFrame: CGRect) {
    let insets = Self.bubbleTextInsets
    var visibleText = textRect.intersection(editorFrame)
    if visibleText.isNull || visibleText.isEmpty {
      visibleText = CGRect(
        x: editorFrame.minX,
        y: editorFrame.minY,
        width: 0,
        height: max(0, bubbleFrame.height - insets.vertical * 2)
      )
    }
    bubbleTextHeight = max(0, bubbleFrame.height - insets.vertical * 2)
    textOrigin = CGPoint(x: bubbleFrame.minX + insets.horizontal, y: bubbleFrame.maxY - insets.vertical)
    rowOffset = CGSize(
      width: visibleText.minX - textOrigin.x,
      height: visibleText.maxY - textOrigin.y
    )
  }

  public func isSingleLine(textRect: CGRect, lineHeight: CGFloat) -> Bool {
    guard lineHeight > 0 else { return false }
    return textRect.height < lineHeight * 1.5 && bubbleTextHeight < lineHeight * 1.5
  }
}
