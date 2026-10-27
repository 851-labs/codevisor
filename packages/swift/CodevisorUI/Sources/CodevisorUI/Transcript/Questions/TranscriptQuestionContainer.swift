import SwiftUI

public struct TranscriptQuestionContainer<Content: View>: View {
  #if os(iOS)
    private static var maxWidth: CGFloat { 560 }
  #else
    private static var maxWidth: CGFloat { 620 }
  #endif

  private let inBotConversation: Bool
  private let content: Content

  public init(inBotConversation: Bool, @ViewBuilder content: () -> Content) {
    self.inBotConversation = inBotConversation
    self.content = content()
  }

  public var body: some View {
    HStack(spacing: 0) {
      content
        .padding(ComposerCardStyle.contentPadding)
        .modifier(TranscriptInlineCardSurface(inBotConversation: inBotConversation))
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent question")
  }
}
