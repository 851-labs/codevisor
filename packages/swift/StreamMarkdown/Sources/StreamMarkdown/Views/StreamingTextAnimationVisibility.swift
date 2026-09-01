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

/// Remembers which semantic text streams have already been presented inside
/// one mounted transcript turn. The owner seeds streams that existed before
/// the turn view mounted; a stream first claimed afterward is genuinely new
/// live output and may animate its initial content.
///
/// The presentation deliberately lives above AppKit/UIKit text coordinators.
/// Native surfaces can be recreated by navigation, disclosure, virtualization,
/// or Markdown tail reclassification without making old text new again.
@MainActor
public final class StreamingTextAnimationPresentation {
    private var presentedStreamIDs: Set<String>
    /// A projected live row reserves its one initial entrance before a native
    /// host exists. This makes arrival, rather than virtualization, decide
    /// whether first-mount content should animate.
    private var reservedInitialAnimationStreamIDs: Set<String> = []
    private var hasEstablishedBaseline: Bool
    private var visibilityGeneration: Int?
    private var settlementTokens: [String: Int] = [:]
    private var settledRestorationIDs: Set<Int> = []
    private var nextSettlementToken = 0
    public private(set) var animationsEnabled = true

    public init() {
        presentedStreamIDs = []
        hasEstablishedBaseline = false
    }

    public init(settledStreamIDs: [String]) {
        presentedStreamIDs = Set(settledStreamIDs)
        hasEstablishedBaseline = true
    }

    /// Records the streams present at the navigation/mount boundary. The
    /// builder is deliberately lazy: SwiftUI may reconstruct its value on
    /// every streamed flush, but collecting a turn's entries should happen
    /// only once for this presentation object.
    public func establishBaseline(_ streamIDs: () -> [String]) {
        guard !hasEstablishedBaseline else { return }
        presentedStreamIDs.formUnion(streamIDs())
        hasEstablishedBaseline = true
    }

    /// Returns true only for a semantic stream first seen during this mounted
    /// presentation. A later native-view remount of the same stream baselines
    /// its current contents instead of replaying their entrance animation.
    public func claimInitialAnimation(for streamID: String) -> Bool {
        if reservedInitialAnimationStreamIDs.remove(streamID) != nil {
            presentedStreamIDs.insert(streamID)
            return true
        }
        return presentedStreamIDs.insert(streamID).inserted
    }

    /// Reserves one entrance for rows whose content arrived at the visible
    /// live edge (or while application playback was suspended). A reservation
    /// survives an offscreen first mount but is consumed exactly once.
    public func reserveInitialAnimations<S: Sequence>(for streamIDs: S)
    where S.Element == String {
        for streamID in streamIDs where !presentedStreamIDs.contains(streamID) {
            reservedInitialAnimationStreamIDs.insert(streamID)
        }
    }

    /// Makes newly projected offscreen rows opaque on their first native
    /// frame. Already claimed streams are deliberately untouched so ordinary
    /// append animation can continue if their host remains warm.
    public func settleUnpresentedStreams<S: Sequence>(_ streamIDs: S)
    where S.Element == String {
        let unpresented = streamIDs.filter {
            !presentedStreamIDs.contains($0)
                && !reservedInitialAnimationStreamIDs.contains($0)
        }
        settle(Array(unpresented))
    }

    /// Applies one view-appearance boundary. Repeated body evaluations in the
    /// same generation must not settle text that arrived live afterward.
    public func updateVisibility(
        generation: Int,
        isVisible: Bool,
        settling streamIDs: () -> [String]
    ) {
        animationsEnabled = isVisible
        guard isVisible, visibilityGeneration != generation else { return }
        visibilityGeneration = generation
        settle(streamIDs())
    }

    /// Marks one asynchronous durable-history hydration as already presented.
    /// The restoration id makes this idempotent while allowing later live
    /// streams in the same turn to animate normally.
    public func settleRestoredStreams(
        _ streamIDs: () -> [String],
        restorationID: Int
    ) {
        guard settledRestorationIDs.insert(restorationID).inserted else { return }
        settle(streamIDs())
    }

    /// Changes whenever an already-mounted semantic stream must baseline its
    /// current contents again, such as after navigation or history hydration.
    public func settlementToken(for streamID: String) -> Int? {
        settlementTokens[streamID]
    }

    private func settle(_ streamIDs: [String]) {
        guard !streamIDs.isEmpty else { return }
        nextSettlementToken &+= 1
        for streamID in streamIDs {
            presentedStreamIDs.insert(streamID)
            settlementTokens[streamID] = nextSettlementToken
        }
    }
}
