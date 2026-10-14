import SwiftUI

struct UnreadBadge: View {
  let color: Color

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 10, height: 10)
      .accessibilityLabel("Unread")
  }
}
