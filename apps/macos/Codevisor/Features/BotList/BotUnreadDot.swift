import SwiftUI

struct BotUnreadDot: View {
  private static let diameter: CGFloat = 10

  let isVisible: Bool

  var body: some View {
    Circle()
      .fill(isVisible ? Color.accentColor : .clear)
      .frame(width: Self.diameter, height: Self.diameter)
      .accessibilityLabel(isVisible ? "Unread" : "")
      .accessibilityHidden(!isVisible)
  }
}
