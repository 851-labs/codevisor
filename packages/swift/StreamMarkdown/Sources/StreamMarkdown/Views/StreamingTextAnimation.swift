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

/// One visible chat surface's animation lifecycle. A session can appear in
/// several windows at once, so this scope belongs to the view, not the model.
/// Each appearance creates a new generation after buffered events have been
/// flushed; existing text settles in that generation before live animation
/// resumes.
@MainActor
@Observable
public final class StreamingTextAnimationVisibility {
    private let presentationID = UUID()
    public private(set) var generation = 0
    public private(set) var isVisible: Bool

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
        isVisible = true
    }

    public func disappear() {
        isVisible = false
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
        presentedStreamIDs.insert(streamID).inserted
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

/// A response-wide animation clock shared by multiple Markdown slices and
/// native elements such as attachment previews. Sharing this object keeps
/// every surface on one document-order cadence instead of restarting at each
/// renderer boundary.
@MainActor
@Observable
public final class StreamingContentAnimationCoordinator {
    public private(set) var hasActiveEntranceAnimation = false
    let timeline = StreamingTextAnimationTimeline()
    private var pendingEntranceSourceIDs: Set<String> = []

    public init() {
        timeline.observeActivity { [weak self] active in
            self?.hasActiveEntranceAnimation = active
        }
    }

    public func waitUntilIdle() async throws {
        try await timeline.waitUntilIdle()
    }

    /// Waits until the shared clock is idle and every mounted Markdown slice
    /// has finished its pending structural entrances. The extra stable pass
    /// lets SwiftUI deliver a newly-rendered child's preference before a
    /// provider-completion task decides that the response can be finalized.
    public func waitUntilFullyIdle() async throws {
        await Task.yield()
        while true {
            try await timeline.waitUntilIdle()
            try Task.checkCancellation()
            await Task.yield()
            guard pendingEntranceSourceIDs.isEmpty else {
                try await Task.sleep(for: .milliseconds(1))
                continue
            }

            await Task.yield()
            try Task.checkCancellation()
            guard pendingEntranceSourceIDs.isEmpty else { continue }
            try await timeline.waitUntilIdle()
            guard pendingEntranceSourceIDs.isEmpty else { continue }
            return
        }
    }

    public func scheduleElementEntrance() {
        timeline.scheduleBlockEntrance()
    }

    public func reset() {
        timeline.reset()
    }

    func setPendingEntrance(_ pending: Bool, sourceID: String) {
        if pending {
            pendingEntranceSourceIDs.insert(sourceID)
        } else {
            pendingEntranceSourceIDs.remove(sourceID)
        }
    }

    public static var elementEntranceAnimation: Animation {
        .timingCurve(
            StreamingTextAnimationSpec.fadeCurveX1,
            StreamingTextAnimationSpec.fadeCurveY1,
            StreamingTextAnimationSpec.fadeCurveX2,
            StreamingTextAnimationSpec.fadeCurveY2,
            duration: StreamingTextAnimationSpec.fadeDuration
        )
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

    /// Enqueues one provider batch and rebalances only words that have not
    /// started fading. The queue behaves like a small media jitter buffer: a
    /// thin reserve slows down, backlog speeds up, and recent provider gaps
    /// adjust the target lead. Started words never move, so cadence changes
    /// cannot make opacity jump.
    func scheduleSegments(
        characterCounts: [Int],
        at now: TimeInterval
    ) -> [StreamingTextFadeMetadata] {
        guard !characterCounts.isEmpty else { return [] }
        discardExpired(at: now)
        let additions = characterCounts.map { count in
            StreamingTextFadeMetadata(
                startTime: .infinity,
                characterCount: max(1, count)
            )
        }
        scheduledFades.append(contentsOf: additions)
        rebalancePending(at: now)
        return additions
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
        var observation = sourceObservations[sourceID] ?? SourceObservation()
        guard observation.text != text else { return }

        let isAppendOnly = text.hasPrefix(observation.text)
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
        _ = scheduleSegments(characterCounts: [1], at: now)
    }

    /// Removes fades whose rendered words were replaced, finalized, or
    /// baselined. Settling their metadata also makes any still-mounted native
    /// surface show those glyphs immediately.
    func discard(
        _ metadata: [StreamingTextFadeMetadata],
        at now: TimeInterval = CACurrentMediaTime()
    ) {
        guard !metadata.isEmpty else { return }
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
            let now = CACurrentMediaTime()
            guard let latestAnimationEndTime, latestAnimationEndTime > now else { return }
            try await Task.sleep(for: .seconds(latestAnimationEndTime - now))
        }
    }

    func reset() {
        let now = CACurrentMediaTime()
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

        let now = CACurrentMediaTime()
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
            $0.startTime + StreamingTextAnimationSpec.fadeDuration <= now
        }
    }

    private func refreshActivity(at now: TimeInterval) {
        discardExpired(at: now)
        latestAnimationEndTime =
            scheduledFades
            .map { $0.startTime + StreamingTextAnimationSpec.fadeDuration }
            .max()
        guard activityObserver != nil else { return }
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
