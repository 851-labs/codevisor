import CodevisorUI
import SwiftUI

struct ComposerSubmitButton: View {
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
            isEnabled
              ? AnyShapeStyle(Color.accentColor.opacity(isHovered ? 1 : 0.9))
              : AnyShapeStyle(Color.secondary.opacity(0.16))
          )
        )
        .contentShape([.interaction, .focusEffect], Circle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .onHover { isHovered = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }
}
