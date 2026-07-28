// Generic transcript disclosure chrome (chevron + measured height/opacity
// reveal), shared by tool rows, worked sections, and message roots on both
// platforms. Extracted from the macOS AssistantTurnView.
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

public struct TranscriptDisclosureContentReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
    let isExpanded: Bool
    @State private var phase: Phase
    @State private var measuredHeight: CGFloat = 0
    @State private var presentedHeight: CGFloat?
    @State private var presentedOpacity: CGFloat
    @State private var animationGeneration = 0
    private let content: Content

    private enum Phase {
        case collapsed
        case measuring
        case expanding
        case expanded
        case collapsing
    }

    public init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        _phase = State(initialValue: isExpanded ? .expanded : .collapsed)
        _presentedHeight = State(initialValue: isExpanded ? nil : 0)
        _presentedOpacity = State(initialValue: isExpanded ? 1 : 0)
        self.content = content()
    }

    public var body: some View {
        Group {
            if phase != .collapsed {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DisclosureContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                    // Scope interpolation to these presentation modifiers.
                    // The enclosing tool group, Worked section, and message
                    // root receive ordinary layout updates, never this
                    // animation transaction.
                    .animation(Motion.reveal(reduceMotion: reduceMotion)) { body in
                        body
                            .opacity(presentedOpacity)
                            .frame(height: presentedHeight, alignment: .top)
                    }
                    // Clip the height animation only. A full .clipped() also
                    // cut horizontal glyph side-bearings: SF Symbols wider
                    // than their fixed icon column (hammer.and.wrench at
                    // iOS's 16pt callout) overhang a couple of points past
                    // the content's leading edge and lost their left side.
                    .clipShape(VerticalOnlyClipShape())
                    .allowsHitTesting(phase == .expanded)
            }
        }
        .onPreferenceChange(DisclosureContentHeightKey.self) { height in
            guard height > 0 else { return }
            measuredHeight = height
            if phase == .measuring {
                expandMeasuredContent(to: height)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            setExpanded(expanded)
        }
        // Every discrete presented-height step (collapse to 0, expand to the
        // measured height, settle to natural height) changes this row's ideal
        // size entirely inside the hosting controller — AppKit may never lay
        // the pinned outer wrapper out again on its own. Tell the virtualizer
        // to remeasure so store-driven collapses (e.g. a background subagent
        // finishing inside a settled row) commit their height immediately.
        .onChange(of: presentedHeight) { _, _ in
            invalidateRowMeasurement?()
        }
    }

    private func setExpanded(_ expanded: Bool) {
        if reduceMotion {
            animationGeneration &+= 1
            phase = expanded ? .expanded : .collapsed
            presentedHeight = expanded ? nil : 0
            presentedOpacity = expanded ? 1 : 0
            return
        }

        if expanded {
            switch phase {
            case .collapsed:
                presentedHeight = 0
                presentedOpacity = 0
                phase = .measuring
            case .collapsing:
                phase = .expanding
                presentedHeight = measuredHeight > 0 ? measuredHeight : nil
                presentedOpacity = 1
                scheduleSettlement(expanded: true)
            case .measuring, .expanding, .expanded:
                break
            }
        } else {
            switch phase {
            case .measuring:
                phase = .collapsed
                presentedHeight = 0
                presentedOpacity = 0
            case .expanding, .expanded:
                phase = .collapsing
                presentedHeight = measuredHeight > 0 ? measuredHeight : presentedHeight
                presentedHeight = 0
                presentedOpacity = 0
                scheduleSettlement(expanded: false)
            case .collapsed, .collapsing:
                break
            }
        }
    }

    private func expandMeasuredContent(to height: CGFloat) {
        guard isExpanded, phase == .measuring else { return }
        phase = .expanding
        presentedHeight = height
        presentedOpacity = 1
        scheduleSettlement(expanded: true)
    }

    private func scheduleSettlement(expanded: Bool) {
        animationGeneration &+= 1
        let generation = animationGeneration
        Task { @MainActor in
            try? await Task.sleep(for: Motion.revealSettleDelay)
            guard generation == animationGeneration,
                  isExpanded == expanded else { return }
            if expanded {
                guard phase == .expanding else { return }
                phase = .expanded
                presentedHeight = nil
            } else {
                guard phase == .collapsing else { return }
                phase = .collapsed
            }
        }
    }
}

private struct DisclosureContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A clip that bounds only the vertical axis: the rect's height, extended far
/// past both horizontal edges. The reveal animates height, so that's all it
/// must mask — glyphs whose natural width overhangs a fixed icon column keep
/// their side-bearings instead of losing them at the content's leading edge.
private struct VerticalOnlyClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX - 1000,
            y: rect.minY,
            width: rect.width + 2000,
            height: rect.height
        ))
    }
}
