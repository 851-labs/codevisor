import SwiftUI

struct SetupRequestCardSurface: ViewModifier {
  let inBotConversation: Bool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private var cardStyle = ComposerCardStyle()

  init(inBotConversation: Bool) {
    self.inBotConversation = inBotConversation
  }

  func body(content: Content) -> some View {
    content
      .containerShape(containerShape)
      .buttonBorderShape(inBotConversation ? .automatic : cardStyle.buttonBorderShape)
      .background {
        if inBotConversation {
          UserBubbleBackground(color: .bubbleBackground)
        } else {
          cardStyle.shape.fill(Color.cardBackgroundColor)
        }
      }
  }

  private var containerShape: RoundedRectangle {
    inBotConversation ? UserBubbleBackground.shape(for: dynamicTypeSize) : cardStyle.containerShape
  }
}
