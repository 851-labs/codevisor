import SwiftUI

public extension View {
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
