import Foundation
import QuartzCore

/// One timeline is shared by every prose surface inside a single
/// `StreamingMarkdownView`. This keeps words in adjacent Markdown blocks on
/// one cadence instead of restarting the delay at every paragraph.
@MainActor
final class StreamingTextAnimationTimeline {
  private struct SourceObservation {
    var text = ""
    var lastArrivalTime: TimeInterval?
  }

  private let readTime: @Sendable () -> TimeInterval
  private let sleep: @Sendable (Duration) async throws -> Void

  init(
    now: @escaping @Sendable () -> TimeInterval = { CACurrentMediaTime() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.readTime = now
    self.sleep = sleep
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
        try await sleep(.milliseconds(16))
        continue
      }
      let now = readTime()
      guard let latestAnimationEndTime, latestAnimationEndTime > now else { return }
      try await sleep(.seconds(latestAnimationEndTime - now))
    }
  }

  func reset() {
    let now = presentationTime(at: readTime())
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

    let now = presentationTime(at: readTime())
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
    let sleep = sleep
    activityEndTask = Task { @MainActor [weak self] in
      try? await sleep(.seconds(delay))
      guard !Task.isCancelled, let self else { return }
      let currentTime = self.readTime()
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
