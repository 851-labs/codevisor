import Foundation
import Observation
import QuartzCore
import SwiftUI

/// Provider-neutral streamed-text presentation for native Markdown surfaces.
///
/// Text is already present in the text storage and therefore participates in
/// layout, selection, copying, and accessibility immediately. Only glyph
/// painting is delayed: each newly rendered word-like range fades from
/// transparent to opaque on this timeline.
enum StreamingTextAnimationSpec {
    static let fadeDuration: TimeInterval = 0.150
    /// Color emoji are assembled from one or more Unicode scalars. Provider
    /// chunks can append a variation selector, skin tone, or ZWJ component to
    /// the trailing grapheme after its base scalar has arrived. Keep that
    /// grapheme pending for a few frames, then reveal the completed glyph in
    /// one paint instead of alpha-blending several transient glyph shapes.
    static let emojiStabilizationDelay: TimeInterval = 0.050
    static let minimumTargetQueueLead: TimeInterval = 0.055
    static let defaultTargetQueueLead: TimeInterval = 0.100
    static let maximumTargetQueueLead: TimeInterval = 0.350
    static let fastestSegmentDelay: TimeInterval = 0.008
    static let minimumSlowestSegmentDelay: TimeInterval = 0.032
    static let maximumSlowestSegmentDelay: TimeInterval = 0.120
    static let minimumStartupQueueLead: TimeInterval = 0.020
    static let maximumStartupQueueLead: TimeInterval = 0.100
    static let minimumArrivalSampleGap: TimeInterval = 0.010
    static let maximumArrivalSampleGap: TimeInterval = 0.900
    static let initialChunkBaseLead: TimeInterval = 0.050
    static let initialChunkCharacterLead: TimeInterval = 0.0008
    static let maximumInitialChunkLead: TimeInterval = 0.150
    static let gapSmoothingAlpha = 0.35
    static let jitterSmoothingAlpha = 0.25
    static let queueLeadRiseAlpha = 0.55
    static let queueLeadFallAlpha = 0.12
    static let jitterMultiplier = 1.5
    static let fadeCurveX1 = 0.37
    static let fadeCurveY1 = 0.55
    static let fadeCurveX2 = 0.86
    static let fadeCurveY2 = 0.88

    static func clampedTargetQueueLead(_ lead: TimeInterval) -> TimeInterval {
        min(maximumTargetQueueLead, max(minimumTargetQueueLead, lead))
    }

    /// Uses the shape of the first live update as a provider-neutral cold-start
    /// estimate. Later source arrivals replace it with measured gap and jitter.
    static func initialTargetQueueLead(forCharacterCount count: Int) -> TimeInterval {
        clampedTargetQueueLead(
            min(
                maximumInitialChunkLead,
                initialChunkBaseLead + Double(max(0, count)) * initialChunkCharacterLead
            ))
    }

    static func startupQueueLead(forTargetQueueLead targetQueueLead: TimeInterval) -> TimeInterval {
        min(
            maximumStartupQueueLead,
            max(minimumStartupQueueLead, targetQueueLead * 0.35)
        )
    }

    static func slowestSegmentDelay(forTargetQueueLead targetQueueLead: TimeInterval) -> TimeInterval {
        min(
            maximumSlowestSegmentDelay,
            max(minimumSlowestSegmentDelay, targetQueueLead * 0.45)
        )
    }

    /// Chooses the delay after revealing one word-like range. Character
    /// backlog, rather than provider/model identity, controls playback: a deep
    /// queue accelerates and a thin queue preserves the measured jitter lead.
    static func segmentDelay(
        revealedCharacterCount: Int,
        backlogCharacterCount: Int,
        targetQueueLead: TimeInterval
    ) -> TimeInterval {
        guard backlogCharacterCount > 0 else { return fastestSegmentDelay }
        let desired =
            targetQueueLead
            * Double(max(1, revealedCharacterCount))
            / Double(backlogCharacterCount)
        return min(
            slowestSegmentDelay(forTargetQueueLead: targetQueueLead),
            max(fastestSegmentDelay, desired)
        )
    }
}

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
        animatesNewStreams: Bool
    ) where S.Element == String {
        let current = Set(streamIDs)
        guard hasObservedProjection else {
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

/// One timeline is shared by every prose surface inside a single
/// `StreamingMarkdownView`. This keeps words in adjacent Markdown blocks on
/// one cadence instead of restarting the delay at every paragraph.
@MainActor
final class StreamingTextAnimationTimeline {
    private struct SourceObservation {
        var text = ""
        var lastArrivalTime: TimeInterval?
    }

    private var scheduledFades: [StreamingTextFadeMetadata] = []
    private var latestAnimationEndTime: TimeInterval?
    private var smoothedArrivalGap: TimeInterval?
    private var smoothedArrivalJitter: TimeInterval = 0
    private var sourceObservations: [String: SourceObservation] = [:]
    private(set) var targetQueueLead = StreamingTextAnimationSpec.defaultTargetQueueLead
    private var activityObserver: ((Bool) -> Void)?
    private var activityEndTask: Task<Void, Never>?
    private var reportedActive = false
    private var observerGeneration = 0
    private var suspensionStartTime: TimeInterval?

    var isSuspended: Bool { suspensionStartTime != nil }

    /// Converts the system clock into the presentation clock. While suspended,
    /// all provider updates share the frozen instant and accumulate behind the
    /// same reveal playhead.
    func presentationTime(at time: TimeInterval) -> TimeInterval {
        suspensionStartTime ?? time
    }

    @discardableResult
    func suspend(at now: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard suspensionStartTime == nil else { return false }
        discardExpired(at: now)
        suspensionStartTime = now
        activityEndTask?.cancel()
        activityEndTask = nil
        reportActivity(false)
        return true
    }

    @discardableResult
    func resume(at now: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard let suspensionStartTime else { return false }
        let duration = max(0, now - suspensionStartTime)
        self.suspensionStartTime = nil
        for fade in scheduledFades { fade.startTime += duration }
        for sourceID in Array(sourceObservations.keys) {
            guard let lastArrivalTime = sourceObservations[sourceID]?.lastArrivalTime else {
                continue
            }
            sourceObservations[sourceID]?.lastArrivalTime = lastArrivalTime + duration
        }
        refreshActivity(at: now)
        return true
    }

    /// Enqueues one provider batch and rebalances only words that have not
    /// started fading. The queue behaves like a small media jitter buffer: a
    /// thin reserve slows down, backlog speeds up, and recent provider gaps
    /// adjust the target lead. Started words never move, so cadence changes
    /// cannot make opacity jump.
    func scheduleSegments(
        characterCounts: [Int],
        revealStyles: [StreamingTextRevealStyle]? = nil,
        at now: TimeInterval
    ) -> [StreamingTextFadeMetadata] {
        guard !characterCounts.isEmpty else { return [] }
        precondition(revealStyles.map { $0.count == characterCounts.count } ?? true)
        let now = presentationTime(at: now)
        discardExpired(at: now)
        let additions = characterCounts.enumerated().map { index, count in
            let revealStyle = revealStyles?[index] ?? .faded
            return StreamingTextFadeMetadata(
                startTime: .infinity,
                characterCount: max(1, count),
                revealStyle: revealStyle,
                minimumStartTime: revealStyle == .atomic
                    ? now + StreamingTextAnimationSpec.emojiStabilizationDelay
                    : nil
            )
        }
        scheduledFades.append(contentsOf: additions)
        rebalancePending(at: now)
        return additions
    }

    /// Extends the small composition window for a trailing emoji whose
    /// grapheme changed before it became visible. Once an emoji is on screen
    /// it is never hidden again.
    func restabilizeAtomicSegment(
        _ metadata: StreamingTextFadeMetadata,
        at now: TimeInterval
    ) {
        let now = presentationTime(at: now)
        guard metadata.revealStyle == .atomic, metadata.startTime > now else { return }
        metadata.minimumStartTime = max(
            metadata.minimumStartTime ?? now,
            now + StreamingTextAnimationSpec.emojiStabilizationDelay
        )
        rebalancePending(at: now)
    }

    /// Records one semantic source revision. Calls from multiple native
    /// Markdown surfaces deduplicate by source id and full document text, so
    /// renderer churn cannot masquerade as a provider arrival. Only append-only
    /// live changes teach the generic gap/jitter estimator.
    func observeSource(
        _ text: String,
        sourceID: String,
        at now: TimeInterval
    ) {
        let now = presentationTime(at: now)
        var observation = sourceObservations[sourceID] ?? SourceObservation()
        guard observation.text != text else { return }

        // Compare source code units rather than grapheme clusters so adding a
        // modifier to the trailing emoji remains an append-only observation.
        let isAppendOnly = text.utf8.starts(with: observation.text.utf8)
        let deltaCharacterCount =
            isAppendOnly
            ? max(0, text.utf16.count - observation.text.utf16.count)
            : 0
        let previousArrivalTime = observation.lastArrivalTime
        observation.text = text
        observation.lastArrivalTime = isAppendOnly ? now : nil
        sourceObservations[sourceID] = observation

        guard isAppendOnly, deltaCharacterCount > 0 else { return }
        guard let previousArrivalTime else {
            targetQueueLead = StreamingTextAnimationSpec.initialTargetQueueLead(
                forCharacterCount: deltaCharacterCount
            )
            rebalancePending(at: now)
            return
        }

        let gap = now - previousArrivalTime
        guard gap >= StreamingTextAnimationSpec.minimumArrivalSampleGap else { return }
        guard gap <= StreamingTextAnimationSpec.maximumArrivalSampleGap else {
            smoothedArrivalGap = nil
            smoothedArrivalJitter = 0
            targetQueueLead = StreamingTextAnimationSpec.initialTargetQueueLead(
                forCharacterCount: deltaCharacterCount
            )
            rebalancePending(at: now)
            return
        }

        let previousGap = smoothedArrivalGap
        let nextGap: TimeInterval
        if let previousGap {
            nextGap =
                previousGap
                + StreamingTextAnimationSpec.gapSmoothingAlpha * (gap - previousGap)
            let deviation = abs(gap - previousGap)
            smoothedArrivalJitter +=
                StreamingTextAnimationSpec.jitterSmoothingAlpha
                * (deviation - smoothedArrivalJitter)
        } else {
            nextGap = gap
            smoothedArrivalJitter = 0
        }
        smoothedArrivalGap = nextGap

        let observedLead = StreamingTextAnimationSpec.clampedTargetQueueLead(
            nextGap + StreamingTextAnimationSpec.jitterMultiplier * smoothedArrivalJitter
        )
        let alpha =
            observedLead > targetQueueLead
            ? StreamingTextAnimationSpec.queueLeadRiseAlpha
            : StreamingTextAnimationSpec.queueLeadFallAlpha
        targetQueueLead += alpha * (observedLead - targetQueueLead)
        targetQueueLead = StreamingTextAnimationSpec.clampedTargetQueueLead(targetQueueLead)
        rebalancePending(at: now)
    }

    /// Records already-presented text without treating a mount, navigation, or
    /// Reduce Motion transition as a provider arrival sample.
    func baselineSource(_ text: String, sourceID: String) {
        sourceObservations[sourceID] = SourceObservation(
            text: text,
            lastArrivalTime: nil
        )
    }

    /// Adds a whole native Markdown block to the same visual cadence as the
    /// streamed glyphs. Callers wait for the timeline to become idle before
    /// inserting the block, then wait again before mounting later content.
    func scheduleBlockEntrance(at now: TimeInterval = CACurrentMediaTime()) {
        _ = scheduleSegments(
            characterCounts: [1],
            at: presentationTime(at: now)
        )
    }

    /// Removes fades whose rendered words were replaced, finalized, or
    /// baselined. Settling their metadata also makes any still-mounted native
    /// surface show those glyphs immediately.
    func discard(
        _ metadata: [StreamingTextFadeMetadata],
        at now: TimeInterval = CACurrentMediaTime()
    ) {
        guard !metadata.isEmpty else { return }
        let now = presentationTime(at: now)
        let identities = Set(metadata.map(ObjectIdentifier.init))
        for fade in metadata {
            fade.startTime = now - StreamingTextAnimationSpec.fadeDuration
        }
        scheduledFades.removeAll { identities.contains(ObjectIdentifier($0)) }
        refreshActivity(at: now)
    }

    /// Suspends through the current animation tail. Newly scheduled work can
    /// extend that tail while this method sleeps, so the deadline is checked
    /// again after every wakeup.
    func waitUntilIdle() async throws {
        await Task.yield()
        while true {
            try Task.checkCancellation()
            if isSuspended {
                try await Task.sleep(for: .milliseconds(16))
                continue
            }
            let now = CACurrentMediaTime()
            guard let latestAnimationEndTime, latestAnimationEndTime > now else { return }
            try await Task.sleep(for: .seconds(latestAnimationEndTime - now))
        }
    }

    func reset() {
        let now = presentationTime(at: CACurrentMediaTime())
        for fade in scheduledFades {
            fade.startTime = now - StreamingTextAnimationSpec.fadeDuration
        }
        scheduledFades = []
        latestAnimationEndTime = nil
        smoothedArrivalGap = nil
        smoothedArrivalJitter = 0
        sourceObservations = [:]
        targetQueueLead = StreamingTextAnimationSpec.defaultTargetQueueLead
        activityEndTask?.cancel()
        activityEndTask = nil
        reportActivity(false)
    }

    /// Lets the SwiftUI layer mirror the exact lifetime of the native glyph
    /// fade. The transcript uses that signal to avoid claiming it is waiting
    /// while commentary text is still visibly entering.
    func observeActivity(_ observer: ((Bool) -> Void)?) {
        observerGeneration &+= 1
        activityObserver = observer
        guard observer != nil else {
            activityEndTask?.cancel()
            activityEndTask = nil
            reportedActive = false
            return
        }

        let now = presentationTime(at: CACurrentMediaTime())
        guard !isSuspended else {
            reportedActive = false
            deliverActivity(false)
            return
        }
        let active = isAnimationActive(at: now)
        reportedActive = active
        deliverActivity(active)
        if active, let latestAnimationEndTime {
            scheduleActivityEnd(at: latestAnimationEndTime, now: now)
        }
    }

    func isAnimationActive(at time: TimeInterval) -> Bool {
        latestAnimationEndTime.map { $0 > time } ?? false
    }

    private func rebalancePending(at now: TimeInterval) {
        let started = scheduledFades.filter { $0.startTime <= now }
        let pending = scheduledFades.filter { $0.startTime > now }
        guard !pending.isEmpty else {
            refreshActivity(at: now)
            return
        }

        let lastStarted = started.map(\.startTime).max()
        let earliestPending = pending.lazy
            .map(\.startTime)
            .filter(\.isFinite)
            .min()
        let firstStart: TimeInterval
        if let lastStarted {
            firstStart = max(now, lastStarted + StreamingTextAnimationSpec.fastestSegmentDelay)
        } else if let earliestPending {
            // A second provider update can arrive during the initial reserve.
            // Keep the original playback deadline instead of pushing it back
            // on every pre-roll update.
            firstStart = max(now, earliestPending)
        } else {
            firstStart =
                now
                + StreamingTextAnimationSpec.startupQueueLead(
                    forTargetQueueLead: targetQueueLead
                )
        }
        var start = firstStart
        var backlogCharacterCount = pending.reduce(0) { $0 + $1.characterCount }
        for fade in pending {
            if let minimumStartTime = fade.minimumStartTime {
                start = max(start, minimumStartTime)
            }
            fade.startTime = start
            start += StreamingTextAnimationSpec.segmentDelay(
                revealedCharacterCount: fade.characterCount,
                backlogCharacterCount: backlogCharacterCount,
                targetQueueLead: targetQueueLead
            )
            backlogCharacterCount -= fade.characterCount
        }
        refreshActivity(at: now)
    }

    private func discardExpired(at now: TimeInterval) {
        scheduledFades.removeAll {
            $0.animationEndTime <= now
        }
    }

    private func refreshActivity(at now: TimeInterval) {
        discardExpired(at: now)
        latestAnimationEndTime =
            scheduledFades
            .map(\.animationEndTime)
            .max()
        guard activityObserver != nil else { return }
        guard !isSuspended else {
            activityEndTask?.cancel()
            activityEndTask = nil
            reportActivity(false)
            return
        }
        let active = latestAnimationEndTime.map { $0 > now } ?? false
        reportActivity(active)
        if active, let latestAnimationEndTime {
            scheduleActivityEnd(at: latestAnimationEndTime, now: now)
        } else {
            activityEndTask?.cancel()
            activityEndTask = nil
        }
    }

    private func scheduleActivityEnd(at endTime: TimeInterval, now: TimeInterval) {
        activityEndTask?.cancel()
        let delay = max(0, endTime - now)
        activityEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let currentTime = CACurrentMediaTime()
            if self.isAnimationActive(at: currentTime), let latestAnimationEndTime = self.latestAnimationEndTime {
                self.scheduleActivityEnd(at: latestAnimationEndTime, now: currentTime)
            } else {
                self.discardExpired(at: currentTime)
                self.latestAnimationEndTime = nil
                self.activityEndTask = nil
                self.reportActivity(false)
            }
        }
    }

    private func reportActivity(_ active: Bool) {
        guard reportedActive != active else { return }
        reportedActive = active
        deliverActivity(active)
    }

    private func deliverActivity(_ active: Bool) {
        guard let observer = activityObserver else { return }
        let generation = observerGeneration
        // Segment scheduling runs inside a representable update. Deferring the
        // state write avoids mutating SwiftUI state during that render pass.
        Task { @MainActor [weak self] in
            guard let self,
                self.observerGeneration == generation,
                self.reportedActive == active,
                self.activityObserver != nil
            else { return }
            observer(active)
        }
    }
}

/// Per-text-surface inputs. The timeline is message-wide while the identity
/// and reconciler live with the native text view that owns a rendered block.
