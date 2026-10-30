import CodevisorUI
import SwiftUI

struct ComposerNavigationButton: View {
  let systemImage: String
  let help: String
  let accessibilityLabel: String
  var weight: Font.Weight = .semibold
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: weight))
        .scaledFrame(
          width: ComposerCardStyle.actionDiameter,
          height: ComposerCardStyle.actionDiameter,
          relativeTo: .subheadline
        )
        .foregroundStyle(Color.primary)
        .background(Circle().fill(Color.secondary.opacity(isHovered ? 0.22 : 0.16)))
        .contentShape([.interaction, .focusEffect], Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }
}
