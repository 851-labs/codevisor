import SwiftUI

struct PaneChatUnavailableView: View {
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Text("This chat no longer exists")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let action {
        Button("Reset Tab", action: action)
      }
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
