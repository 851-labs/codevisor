import CoreGraphics

/// Where a send starts and ends, in one top-left-origin coordinate space
/// (the window overlay the flight draws in).
///
/// The bubble's last line of text starts exactly on the composer's last line
/// of glyphs, so the text appears to peel out of the composer as a bubble.
public struct TranscriptSendFlightGeometry: Equatable, Sendable {
  /// The user bubble's text padding, shared by both platforms' bubbles.
  public static let bubbleTextInsets = (horizontal: CGFloat(12), vertical: CGFloat(8))

  /// Starting translation of the flying bubble relative to its final slot.
  public let rowOffset: CGSize
  /// The bubble's text height (one line when the message fits on one).
  public let bubbleTextHeight: CGFloat

  /// The bottom-leading corner of the bubble's text at its final slot: the
  /// point the flight's scale pivots on, so it stays on the composer glyph.
  public let textOrigin: CGPoint

  /// - Parameters:
  ///   - editorFrame: The composer editor's visible frame.
  ///   - textRect: The editor's laid-out glyphs, in the same space. Clipped
  ///     to the editor, so a scrolled draft aligns on its visible last line.
  ///   - bubbleFrame: The destination bubble background.
  public init(editorFrame: CGRect, textRect: CGRect, bubbleFrame: CGRect) {
    let insets = Self.bubbleTextInsets
    var visibleText = textRect.intersection(editorFrame)
    if visibleText.isNull || visibleText.isEmpty {
      // An empty draft (attachments only) has no glyphs: start from the
      // editor's first line instead.
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

  /// Whether the composer's glyphs and the bubble's text are both a single
  /// line, so they wrap identically and can crossfade in place.
  public func isSingleLine(textRect: CGRect, lineHeight: CGFloat) -> Bool {
    guard lineHeight > 0 else { return false }
    return textRect.height < lineHeight * 1.5 && bubbleTextHeight < lineHeight * 1.5
  }
}
