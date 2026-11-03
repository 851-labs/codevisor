import SwiftUI

struct LivePreviewPiPCloseButton: View {
  let help: String
  let label: String
  let isHovering: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .circle)
    .help(help)
    .accessibilityLabel(label)
    .padding(8)
    .opacity(isHovering ? 1 : 0)
    .scaleEffect(isHovering ? 1 : 0.9)
  }
}
