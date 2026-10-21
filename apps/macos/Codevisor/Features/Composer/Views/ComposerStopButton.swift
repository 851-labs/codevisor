import SwiftUI

struct ComposerStopButton: View {
  let isCancelling: Bool
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    if isCancelling {
      ProgressView()
        .controlSize(.small)
        .frame(width: 26, height: 26)
        .help("Stopping…")
    } else {
      Button(action: action) {
        Image(systemName: "stop.fill")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 26, height: 26)
          .background(Circle().fill(isHovered ? Color.primary.opacity(0.06) : .clear))
          .overlay(
            Circle()
              .strokeBorder(Color.secondary.opacity(isHovered ? 0.55 : 0.35), lineWidth: 1)
          )
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(isHovered ? .primary : .secondary)
      .onHover { isHovered = $0 }
      .help("Stop")
      .accessibilityLabel("Stop")
    }
  }
}
