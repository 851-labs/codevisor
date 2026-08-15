import SwiftUI

/// Attention marker for a chat blocked on a question or plan approval.
struct ActionRequiredIndicator: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color.opacity(0.18))
            .overlay {
                Circle().stroke(color, lineWidth: 1.25)
            }
            .frame(width: 10, height: 10)
            .accessibilityLabel("Action required")
            .help("This chat needs your response")
    }
}
