import SwiftUI

struct HomeSidebarUnreadDot: View {
  @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 10

  let isVisible: Bool

  var body: some View {
    Circle()
      .fill(isVisible ? Color.blue : .clear)
      .frame(width: diameter, height: diameter)
      .accessibilityLabel(isVisible ? "Unread" : "")
      .accessibilityHidden(!isVisible)
  }
}
