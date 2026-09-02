// Generic transcript disclosure chrome, shared by tool rows, worked sections,
// setup phases, and message roots on both platforms.
import SwiftUI

/// The disclosure indicator owns its rotation animation. The section body has
/// a separate entrance animation, so the label and chevron never fade or move
/// with the expanded content.
public struct TranscriptDisclosureChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let expanded: Bool

    public init(expanded: Bool) {
        self.expanded = expanded
    }

    @ViewBuilder
    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 10, height: 10)
            // Scope interpolation to rotation only. A value-based animation
            // also captured position changes from the expanding parent.
            .animation(Motion.indicator(reduceMotion: reduceMotion)) { chevron in
                chevron.rotationEffect(.degrees(expanded ? 90 : 0))
            }
    }
}
