import SwiftUI

/// Animation ownership shared by every virtual Markdown row on one retained
/// transcript surface. Row hosts are free to remount or change renderer while
/// semantic stream claims and response-wide pacing remain stable.
@MainActor
public final class StreamingTextAnimationRegistry {
    public let presentation = StreamingTextAnimationPresentation()
    private var coordinators: [String: StreamingContentAnimationCoordinator] = [:]
    private var knownProjectedStreamIDs: Set<String> = []
    private var hasObservedProjection = false
    private var isPlaybackSuspended = false
    /// UIKit may publish its first post-foreground projection only after the
    /// scene becomes active. Protect that single delta from offscreen
    /// baselining just as if it had been observed during suspension.
    private var preservesNextProjectionDelta = false

    public init() {}

    public func coordinator(for semanticStreamID: String) -> StreamingContentAnimationCoordinator {
        if let coordinator = coordinators[semanticStreamID] { return coordinator }
        let coordinator = StreamingContentAnimationCoordinator()
        if isPlaybackSuspended { coordinator.suspendPlayback() }
        coordinators[semanticStreamID] = coordinator
        return coordinator
    }

    public func retireCoordinator(for semanticStreamID: String) {
        coordinators.removeValue(forKey: semanticStreamID)?.reset()
    }

    /// Observes the complete active Markdown row set before a virtualizer can
    /// mount any of it. The first snapshot is navigation state and therefore
    /// starts opaque. Later rows animate only at the followed live edge;
    /// offscreen arrivals are already presented when scrolling reaches them.
    public func observeProjectedStreams<S: Sequence>(
        _ streamIDs: S,
        animatesNewStreams: Bool,
        initialProjectionIsPending: Bool = false
    ) where S.Element == String {
        let current = Set(streamIDs)
        guard hasObservedProjection else {
            // An asynchronously projected transcript first configures its
            // native surface with an empty active-row placeholder. Waiting
            // here makes the first authoritative projection the navigation
            // baseline instead of mistaking already-present text for live
            // output when that projection arrives.
            guard !initialProjectionIsPending else { return }
            hasObservedProjection = true
            knownProjectedStreamIDs.formUnion(current)
            presentation.settleUnpresentedStreams(current)
            return
        }

        let newlyProjected = current.subtracting(knownProjectedStreamIDs)
        knownProjectedStreamIDs.formUnion(current)
        guard !newlyProjected.isEmpty else {
            if preservesNextProjectionDelta { preservesNextProjectionDelta = false }
            return
        }

        let preservesSuspendedArrival = isPlaybackSuspended || preservesNextProjectionDelta
        preservesNextProjectionDelta = false
        if animatesNewStreams || preservesSuspendedArrival {
            presentation.reserveInitialAnimations(for: newlyProjected)
        } else {
            presentation.settleUnpresentedStreams(newlyProjected)
        }
    }

    /// Freezes presentation time without disabling or settling the streams.
    /// Provider/model state may continue advancing while the application is
    /// backgrounded; every coordinator resumes from the same visual instant.
    public func suspendPlayback() {
        guard !isPlaybackSuspended else { return }
        isPlaybackSuspended = true
        preservesNextProjectionDelta = false
        for coordinator in coordinators.values { coordinator.suspendPlayback() }
    }

    public func resumePlayback() {
        guard isPlaybackSuspended else { return }
        isPlaybackSuspended = false
        preservesNextProjectionDelta = true
        for coordinator in coordinators.values { coordinator.resumePlayback() }
    }
}

private struct StreamingTextAnimationRegistryKey: EnvironmentKey {
    static let defaultValue: StreamingTextAnimationRegistry? = nil
}

public extension EnvironmentValues {
    var streamingTextAnimationRegistry: StreamingTextAnimationRegistry? {
        get { self[StreamingTextAnimationRegistryKey.self] }
        set { self[StreamingTextAnimationRegistryKey.self] = newValue }
    }
}
