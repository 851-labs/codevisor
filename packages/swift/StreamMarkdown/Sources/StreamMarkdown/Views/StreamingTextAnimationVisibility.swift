import Foundation
import Observation
import SwiftUI

/// One visible chat surface's animation lifecycle. A session can appear in
/// several windows at once, so this scope belongs to the view, not the model.
/// Each appearance creates a new generation after buffered events have been
/// flushed; existing text settles in that generation before live animation
/// resumes.
@MainActor
@Observable
public final class StreamingTextAnimationVisibility {
    private let presentationID = UUID()
    private var activeEntranceAnimationSourceIDs: Set<UUID> = []
    public private(set) var generation = 0
    public private(set) var isVisible: Bool

    /// True while any mounted row on this presentation surface is still
    /// revealing streamed content. Transcript rows live in independent native
    /// hosts, so this surface-scoped aggregate is the only reliable place for
    /// sibling activity rows to observe their animation state.
    public var hasActiveEntranceAnimation: Bool {
        isVisible && !activeEntranceAnimationSourceIDs.isEmpty
    }

    /// Uniquely identifies one appearance of one chat surface. Unlike the
    /// numeric generation alone, this cannot collide across windows.
    public var presentationKey: String {
        "\(presentationID.uuidString):\(generation)"
    }

    public init(initiallyVisible: Bool = true) {
        isVisible = initiallyVisible
    }

    public func appear() {
        guard !isVisible else { return }
        generation &+= 1
        activeEntranceAnimationSourceIDs.removeAll()
        isVisible = true
    }

    public func disappear() {
        activeEntranceAnimationSourceIDs.removeAll()
        isVisible = false
    }

    /// Registers one mounted row's entrance-animation state. A set is used
    /// instead of a boolean because several Markdown chunks can overlap while
    /// a provider flush is being presented.
    public func setEntranceAnimationActive(_ active: Bool, sourceID: UUID) {
        guard isVisible else {
            activeEntranceAnimationSourceIDs.remove(sourceID)
            return
        }
        if active {
            activeEntranceAnimationSourceIDs.insert(sourceID)
        } else {
            activeEntranceAnimationSourceIDs.remove(sourceID)
        }
    }
}

private struct StreamingTextAnimationVisibilityKey: EnvironmentKey {
    static let defaultValue: StreamingTextAnimationVisibility? = nil
}

public extension EnvironmentValues {
    var streamingTextAnimationVisibility: StreamingTextAnimationVisibility? {
        get { self[StreamingTextAnimationVisibilityKey.self] }
        set { self[StreamingTextAnimationVisibilityKey.self] = newValue }
    }
}

private struct StreamingTextAnimationActivityReporter: ViewModifier {
    @Environment(\.streamingTextAnimationVisibility) private var visibility
    @State private var sourceID = UUID()
    @State private var isActive = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(StreamingMarkdownEntranceAnimationPreferenceKey.self) { active in
                isActive = active
                visibility?.setEntranceAnimationActive(active, sourceID: sourceID)
            }
            .onAppear {
                visibility?.setEntranceAnimationActive(isActive, sourceID: sourceID)
            }
            .onChange(of: visibility?.presentationKey) {
                visibility?.setEntranceAnimationActive(isActive, sourceID: sourceID)
            }
            .onDisappear {
                visibility?.setEntranceAnimationActive(false, sourceID: sourceID)
            }
    }
}

private struct StreamingTextAnimationEphemeralGate: ViewModifier {
    @Environment(\.streamingTextAnimationVisibility) private var visibility

    func body(content: Content) -> some View {
        let isSuppressed = visibility?.hasActiveEntranceAnimation == true
        content
            // Virtual rows must retain stable geometry while their sibling
            // Markdown rows animate. Removing this content collapsed the row
            // to its 1pt safety frame; restoring it then painted into that
            // clipped frame until another measurement pass happened.
            .opacity(isSuppressed ? 0 : 1)
            .allowsHitTesting(!isSuppressed)
            .accessibilityHidden(isSuppressed)
            .animation(nil, value: isSuppressed)
    }
}

public extension View {
    /// Publishes animation preferences from one native transcript row into the
    /// presentation-wide aggregate shared by all of that transcript's rows.
    func reportsStreamingTextAnimationActivity() -> some View {
        modifier(StreamingTextAnimationActivityReporter())
    }

    /// Hides transient progress UI while streamed content is visibly entering
    /// without changing its virtual row's measured geometry.
    func suppressedDuringStreamingTextEntrance() -> some View {
        modifier(StreamingTextAnimationEphemeralGate())
    }
}
