import CodevisorUI
import SwiftUI

/// An active-mode pill in the composer toolbar (plan/goal). Hovering the chip
/// swaps the mode icon for an ✕ remove button in the same slot; hovering the
/// ✕ itself adds the circular hover wash (matching the pane tabs' close
/// button). Replaces the always-visible toggle buttons — the modes are turned
/// on via the /plan and /goal commands.
struct ModeChip: View {
    @Environment(\.theme) private var theme
    let label: String
    let systemImage: String
    var isRemoveDisabled: Bool = false
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var isRemoveHovered = false

    private var showsRemoveGlyph: Bool { isHovered && !isRemoveDisabled }

    var body: some View {
        HStack(spacing: 4) {
            removeButton
            Text(label)
        }
        .foregroundStyle(AnyShapeStyle(theme.windowBackground))
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.82)))
        .opacity(isRemoveDisabled ? 0.5 : 1)
        .onHover { hovering in
            // Instant swap: animating here rebuilds AppKit hover tracking
            // mid-hover, which oscillates the state and flickers.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isHovered = hovering
                if !hovering { isRemoveHovered = false }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label) mode on")
    }

    /// Always a button (so it stays reachable by assistive tech); only the
    /// glyph is hover-driven — the mode icon at rest, ✕ while the chip is
    /// hovered, with the tabs' circular wash while the ✕ itself is hovered.
    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: showsRemoveGlyph ? "xmark" : systemImage)
                .font(
                    showsRemoveGlyph
                        ? .system(size: Typography.IconSize.compact, weight: .bold)
                        : .system(size: 11, weight: .semibold)
                )
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(
                        theme.windowBackground.opacity(isRemoveHovered && showsRemoveGlyph ? 0.22 : 0)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isRemoveDisabled)
        .onHover { hovering in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isRemoveHovered = hovering }
        }
        .help("Turn off \(label.lowercased()) mode")
        .accessibilityLabel("Turn off \(label.lowercased()) mode")
    }
}
