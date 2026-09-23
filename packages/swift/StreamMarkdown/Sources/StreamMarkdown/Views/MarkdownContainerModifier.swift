import SwiftUI

public extension View {
  /// Declares that this markdown is drawn inside a bordered container (a
  /// card) whose content column is inset `padding` points from the border on
  /// each side. Everything inside then stays within that border:
  ///
  /// - Renderers that lay out at the transcript row width (prepared text,
  ///   tables) are handed the container's narrower column instead of the
  ///   full row, so they never lay out wider than the card.
  /// - A table wider than the column scrolls inside the card: its scroll
  ///   viewport may reach into the card's padding, up to the inner edge of
  ///   the border, but never past it into the transcript gutter.
  ///
  /// Apply it to the markdown itself, inside the container's padding.
  func markdownContainer(padding: CGFloat, borderWidth: CGFloat = 1) -> some View {
    modifier(MarkdownContainerModifier(padding: padding, borderWidth: borderWidth))
  }
}

private struct MarkdownContainerModifier: ViewModifier {
  let padding: CGFloat
  let borderWidth: CGFloat
  @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth

  func body(content: Content) -> some View {
    let bleedLimit = max(0, padding - borderWidth)
    content
      .environment(\.streamMarkdownTextLayoutWidth, rowLayoutWidth.map { max(1, $0 - padding * 2) })
      .transformEnvironment(\.markdownTableBleedLimit) { limit in
        limit = min(limit, bleedLimit)
      }
  }
}
