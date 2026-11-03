import StreamMarkdown
import SwiftUI

struct PluginAppCardStyle: ViewModifier {
  @Environment(\.markdownBlockChrome) private var chrome
  @Environment(\.markdownTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let isFilled: Bool

  func body(content: Content) -> some View {
    let shape = self.shape
    content
      .background(isFilled ? fill : .clear, in: shape)
      .clipShape(shape)
      .overlay {
        if isFilled { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
      }
      .contentShape(shape)
  }

  private var shape: RoundedRectangle {
    guard chrome.drawsFrame else { return UserBubbleBackground.shape(for: dynamicTypeSize) }
    return RoundedRectangle(cornerRadius: Self.cardCornerRadius)
  }

  private var fill: Color {
    chrome.drawsFrame ? theme.codeBackground : Color.bubbleBackground
  }

  private static var cardCornerRadius: CGFloat { 8 }
}

extension View {
  func pluginAppCard(filled: Bool = true) -> some View {
    modifier(PluginAppCardStyle(isFilled: filled))
  }
}
