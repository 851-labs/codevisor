import SwiftUI

/// A count-less notification badge for chats that changed while unopened.
struct UnreadBadge: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityLabel("Unread chat")
    }
}
