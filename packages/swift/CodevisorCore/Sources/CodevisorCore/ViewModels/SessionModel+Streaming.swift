import Foundation
import ACPKit

extension SessionModel {
  func startConsumer() async {
    guard consumerTask == nil else { return }
    let events =
      serverEventCursor.map { transport.streamEnvelopes(since: $0) }
      ?? transport.streamEnvelopes()
    let pendingEvents = self.pendingEvents
    let consumerGeneration = pendingEvents.beginConsumer()
    consumerTask = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        for try await envelope in events {
          guard !Task.isCancelled, self != nil else { break }
          if case let .synchronization(state) = envelope.event,
            state == .reconnecting
          {
            await self?.noteStreamRecovery(state, generation: consumerGeneration)
          }
          if pendingEvents.append(
            envelope.event, cursor: envelope.cursor, generation: consumerGeneration, byteCount: envelope.byteCount
          ) {
            Task { @MainActor [weak self] in
              self?.scheduleFlush()
            }
          }
          if pendingEvents.overflowed { throw CodevisorServerClientError.invalidResponse }
        }
        await self?.flushPendingEventsAtPresentationBoundary()
      } catch {
        guard !Task.isCancelled, pendingEvents.accepts(generation: consumerGeneration) else { return }
        await self?.handleEventStreamFailure(error)
      }
    }
  }

  private func noteStreamRecovery(_ state: SessionStreamSynchronization, generation: UInt64) {
    guard pendingEvents.accepts(generation: generation) else { return }
    applySynchronization(state)
  }

  private func handleEventStreamFailure(_ error: any Error) async {
    Log.session.error(
      "Session event stream failed; reconciling from server: \(String(describing: error), privacy: .public)"
    )
    consumerTask = nil
    await reconcileFromServer()
  }

  public func viewDidAppear() {
    visibleViewCount += 1
    if visibleViewCount == 1 {
      reschedulePendingEventsForCurrentVisibility()
    }
  }

  public func viewDidDisappear() {
    visibleViewCount = max(0, visibleViewCount - 1)
    if visibleViewCount == 0 {
      reschedulePendingEventsForCurrentVisibility()
    }
  }

  func scheduleFlush() {
    guard !isFlushScheduled,
      !pendingEvents.isEmpty
    else { return }
    isFlushScheduled = true
    if isViewVisible, presentationFrameRequester?() == true {
      return
    }
    let interval = Self.flushInterval(
      isViewVisible: isViewVisible,
      foreground: Self.eventFlushInterval,
      background: Self.backgroundEventFlushInterval
    )
    scheduledFlushTask = Task { @MainActor [weak self] in
      if interval > .zero {
        try? await Task.sleep(for: interval)
      }
      guard !Task.isCancelled else { return }
      self?.flushPendingEvents()
    }
  }

  func preferPresentationFrameIfPending() {
    guard isFlushScheduled, !pendingEvents.isEmpty, isViewVisible,
      presentationFrameRequester?() == true
    else { return }
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
  }

  func reschedulePendingEventsForCurrentVisibility() {
    guard !pendingEvents.isEmpty else { return }
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
    isFlushScheduled = false
    scheduleFlush()
  }

  static func flushInterval(
    isViewVisible: Bool,
    foreground: Duration,
    background: Duration
  ) -> Duration {
    if isViewVisible || foreground == .zero {
      foreground
    } else {
      background
    }
  }

  func flushPendingEvents() {
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
    isFlushScheduled = false
    let events = Self.coalesced(pendingEvents.takeAll())
    guard !events.isEmpty else { return }
    for pending in events {
      apply(pending.event)
      advanceServerEventCursor(to: pending.cursor)
    }
  }

  func advanceServerEventCursor(to cursor: Int?) {
    guard let cursor, cursor < ServerSessionTransport.liveOnlyEventCursor else { return }
    if let current = serverEventCursor, current >= cursor { return }
    serverEventCursor = cursor
  }

  func flushPendingEventsAtPresentationBoundary() async {
    guard !pendingEvents.isEmpty else { return }
    if isViewVisible, presentationFrameRequester?() == true {
      if !isFlushScheduled {
        scheduleFlush()
      }
      for _ in 0..<50 {
        guard !pendingEvents.isEmpty else { return }
        try? await presentationBoundarySleep(.milliseconds(1))
      }
    }
    flushPendingEvents()
  }

  static func coalesced(_ events: [SessionPendingStreamEvent]) -> [SessionPendingStreamEvent] {
    guard events.count > 1 else { return events }
    var result: [SessionPendingStreamEvent] = []
    result.reserveCapacity(events.count)
    for pending in events {
      if case let .update(.agentMessagePatch(patch)) = pending.event,
        let last = result.last, case .update(.agentMessagePatch(var previous)) = last.event,
        previous.chatItemId == patch.chatItemId, previous.messageId == patch.messageId,
        previous.parentToolCallId == patch.parentToolCallId, previous.generation == patch.generation,
        previous.offset + previous.text.utf16.count == patch.offset,
        previous.text.utf16.count + patch.text.utf16.count <= 24_000
      {
        previous.text += patch.text
        previous.totalLength = patch.totalLength
        previous.stateRevision = patch.stateRevision
        previous.phase = patch.phase ?? previous.phase
        previous.detailResource = patch.detailResource
        result[result.count - 1] = SessionPendingStreamEvent(
          .update(.agentMessagePatch(previous)), cursor: pending.cursor)
        continue
      }
      if case let .update(.agentMessageChunk(block, messageId, parent, phase)) = pending.event,
        case let .text(text, annotations) = block, annotations == nil, !text.isEmpty,
        let previous = result.last,
        case let .update(.agentMessageChunk(previousBlock, previousId, previousParent, previousPhase)) =
          previous.event,
        case let .text(previousText, previousAnnotations) = previousBlock,
        previousAnnotations == nil, !previousText.isEmpty,
        messageId == previousId, parent == previousParent, phase == previousPhase
      {
        result[result.count - 1] = SessionPendingStreamEvent(
          .update(
            .agentMessageChunk(
              .text(previousText + text), messageId: messageId, parentToolCallId: parent, phase: phase
            )),
          cursor: Self.newestCursor(previous.cursor, pending.cursor)
        )
      } else {
        result.append(pending)
      }
    }
    return result
  }

  private static func newestCursor(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): max(lhs, rhs)
    case let (lhs?, nil): lhs
    case let (nil, rhs?): rhs
    case (nil, nil): nil
    }
  }

  public func shutdown() {
    connectionRecovery.stop()
    transcriptDetails.cancelAll()
    consumerTask?.cancel()
    consumerTask = nil
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
    isFlushScheduled = false
    promptQueue.cancelLoad()
    pendingEvents.invalidateConsumer(keepingCapacity: false)
  }

  func drain() async {
    var stableRounds = 0
    var lastCount = appliedUpdateCount
    var iterations = 0
    while stableRounds < 2 && iterations < 500 {
      await flushPendingEventsAtPresentationBoundary()
      await Task.yield()
      iterations += 1
      if !pendingEvents.isEmpty {
        stableRounds = 0
        continue
      }
      if appliedUpdateCount == lastCount {
        stableRounds += 1
      } else {
        stableRounds = 0
        lastCount = appliedUpdateCount
      }
    }
  }
}
