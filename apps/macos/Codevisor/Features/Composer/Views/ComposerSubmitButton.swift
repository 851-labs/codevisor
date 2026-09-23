import CodevisorUI
import SwiftUI

/// The primary action shared by every composer state. Keeping the visual
/// treatment here makes question submission track ordinary prompt submission.
struct ComposerSubmitButton: View {
  @Environment(\.theme) private var theme
  let systemImage: String
  let isEnabled: Bool
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovered = false

  init(
    systemImage: String = "arrow.up",
    isEnabled: Bool,
    help: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.isEnabled = isEnabled
    self.help = help
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .bold))
        .scaledFrame(
          width: ComposerCardStyle.actionDiameter,
          height: ComposerCardStyle.actionDiameter,
          relativeTo: .subheadline
        )
        .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.75))
        .background(
          Circle().fill(
            // The primary action carries the app's accent on both
            // platforms; hover deepens it slightly.
            isEnabled
              ? AnyShapeStyle(theme.accent.opacity(isHovered ? 1 : 0.9))
              : AnyShapeStyle(Color.secondary.opacity(0.16))
          )
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .onHover { isHovered = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }
}
