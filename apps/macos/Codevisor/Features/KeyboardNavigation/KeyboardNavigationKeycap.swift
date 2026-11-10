import SwiftUI

struct KeyboardNavigationKeycap: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: "arrow.right.to.line")
        .font(.system(size: 15, weight: .semibold))
      Text("tab")
        .font(.system(size: 13, weight: .medium))
    }
    .foregroundStyle(.primary.opacity(0.8))
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 84, height: 58, alignment: .bottomLeading)
    .background(keyShape.fill(.background.shadow(.drop(color: .black.opacity(0.18), radius: 0, y: 3))))
    .overlay(keyShape.strokeBorder(.quaternary))
    .accessibilityHidden(true)
  }

  private var keyShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
  }
}
