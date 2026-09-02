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
                .frame(width: 26, height: 26)
                .foregroundStyle(isEnabled ? theme.windowBackground : Color.secondary.opacity(0.75))
                .background(
                    Circle().fill(
                        isEnabled
                            ? Color.primary.opacity(isHovered ? 0.92 : 0.82)
                            : Color.secondary.opacity(0.16)
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
