import SwiftUI

struct ErrorUnreadBadge: View {
  let color: Color
  var subject = "chat"

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .accessibilityLabel("Unread \(subject) error")
      .help("This \(subject) ended with an error")
  }
}
