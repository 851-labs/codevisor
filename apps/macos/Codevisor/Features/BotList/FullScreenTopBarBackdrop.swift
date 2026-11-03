import SwiftUI

struct FullScreenTopBarBackdrop: View {
  private static let fadeDuration: TimeInterval = 0.2

  let isVisible: Bool

  var body: some View {
    Rectangle()
      .fill(.bar)
      .frame(height: BotConversationHeader.height)
      .opacity(isVisible ? 1 : 0)
      .animation(.easeInOut(duration: Self.fadeDuration), value: isVisible)
      .allowsHitTesting(false)
  }
}
