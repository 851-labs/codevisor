import CodevisorUI
import SwiftUI

struct ComposerChipRemoveButton: View {
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: Typography.IconSize.compact, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(Circle().fill(.black.opacity(0.78)))
        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }
}
