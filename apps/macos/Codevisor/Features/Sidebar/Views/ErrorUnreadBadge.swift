import SwiftUI

/// Higher-priority unread marker for an activity epoch that ended abnormally.
struct ErrorUnreadBadge: View {
  let color: Color

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .accessibilityLabel("Unread chat error")
      .help("This chat ended with an error")
  }
}
