import CodevisorUI
import SwiftUI

enum ComposerCircleActionEmphasis {
    case primary
    case secondary
}

private struct ComposerCircleActionLabelModifier: ViewModifier {
    let emphasis: ComposerCircleActionEmphasis
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch emphasis {
        case .primary:
            content
                .font(.subheadline.weight(.bold))
                .scaledFrame(width: 30, height: 30, relativeTo: .subheadline)
                .foregroundStyle(
                    isEnabled ? Color(.systemBackground) : Color.secondary.opacity(0.75)
                )
                .background(
                    Circle().fill(
                        isEnabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.16)
                    )
                )
                .expandedHitTarget(base: 30)
        case .secondary:
            content
                .font(.caption.weight(.bold))
                .scaledFrame(width: 30, height: 30, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .expandedHitTarget(base: 30)
        }
    }
}

extension View {
    func composerCircleActionLabel(
        _ emphasis: ComposerCircleActionEmphasis,
        isEnabled: Bool = true
    ) -> some View {
        modifier(ComposerCircleActionLabelModifier(emphasis: emphasis, isEnabled: isEnabled))
    }
}
