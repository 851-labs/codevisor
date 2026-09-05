import Foundation
import ACPKit

extension SessionModel {
  /// Starts the single long-lived event consumer (idempotent).
  ///
  /// Events are buffered and applied in per-frame batches rather than one
  /// at a time: streaming delivers dozens of token-sized chunks per second,
  /// and each individually-applied chunk lands in its own run-loop turn —
  /// its own full SwiftUI invalidation of every `conversation` observer.
  /// Batching bounds UI work to roughly once per frame no matter how fast
  /// the server streams, which is what keeps typing in the composer crisp
  /// while a turn is running.
  func startConsumer() async {
    guard consumerTask == nil else { return }
    let events: AsyncThrowingStream<ServerSessionStreamEnvelope, any Error>
    if usesPaginatedHistory {
      events =
        serverEventCursor.map { transport.streamEnvelopes(since: $0) }
        ?? transport.streamEnvelopes()
    } else {
      events = transport.legacyStreamEnvelopes(
        since: serverEventCursor ?? ServerSessionTransport.liveOnlyEventCursor
      )
    }
    let pendingEvents = self.pendingEvents
    let consumerGeneration = pendingEvents.beginConsumer()
    consumerTask = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        for try await envelope in events {
          guard !Task.isCancelled, self != nil else { break }
          if pendingEvents.append(
            envelope.event, cursor: envelope.cursor, generation: consumerGeneration
          ) {
            Task { @MainActor [weak self] in
              self?.scheduleFlush()
            }
          }
        }
        await self?.flushPendingEventsAtPresentationBoundary()
      } catch {
        guard !Task.isCancelled else { return }
        await self?.handleEventStreamFailure(error)
      }
    }
  }

  /// Re-homes a live session onto a new transport — the same machine over a
  /// different route (direct ↔ relay). The conversation already applied is
  /// newer than any snapshot the server could hand back, so nothing is
  /// reloaded: the dead socket is dropped, its unapplied buffer discarded,
  /// and a fresh subscription resumes from the last applied cursor. The
  /// server replays anything after it, so the transcript neither regresses
  /// nor re-animates.
  public func adoptTransport(_ transport: ServerSessionTransport) async {
    self.transport = transport
    consumerTask?.cancel()
    consumerTask = nil
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
    isFlushScheduled = false
    // Events buffered but not yet applied came over the old route and are
    // not reflected in `serverEventCursor`; the new subscription replays
    // them. Dropping them here also retires the old consumer generation so
    // a late yield from the cancelled iterator cannot slip in.
    pendingEvents.invalidateConsumer()
    Log.session.notice(
      "Adopting a new session transport; resuming the event stream from cursor \(String(describing: self.serverEventCursor), privacy: .public)"
    )
    await startConsumer()
  }

  private func handleEventStreamFailure(_ error: any Error) async {
    Log.session.error(
      "Session event stream failed; reconciling from server: \(String(describing: error), privacy: .public)"
    )
    consumerTask = nil
    await reconcileFromServer()
  }

  /// A transcript view for this session became visible. Everything buffered
  /// while hidden is armed for its first native presentation frame.
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

  /// Schedules one buffered flush. Visible transcripts use their native
  /// display clock; hidden transcripts use a coarse timer because they have
  /// no pixels to present.
  func scheduleFlush() {
    guard !isActiveTranscriptHydrationPending, !isFlushScheduled,
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

  /// Moves an already-armed fallback timer onto the native presentation
  /// clock as soon as a visible surface becomes available.
  func preferPresentationFrameIfPending() {
    guard isFlushScheduled, !pendingEvents.isEmpty, isViewVisible,
      presentationFrameRequester?() == true
    else { return }
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
  }

  /// Visibility or driver ownership changed while work was pending. Re-arm
  /// against the correct clock without applying the buffered events early.
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

  /// Applies every buffered stream event in one synchronous pass — a single
  /// run-loop turn, so SwiftUI renders the whole batch once.
  func flushPendingEvents() {
    guard !isActiveTranscriptHydrationPending else { return }
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

  /// Records that every event through `cursor` is now reflected in the
  /// conversation. Only ever moves forward: a coalesced batch carries the
  /// highest cursor it merged, and replayed history can never rewind it.
  func advanceServerEventCursor(to cursor: Int?) {
    guard let cursor else { return }
    if let current = serverEventCursor, current >= cursor { return }
    serverEventCursor = cursor
  }

  /// Semantic barriers (prompt completion, cancellation, stream completion)
  /// must see all events already in flight, but a visible transcript must not
  /// bypass its display clock to do so. Wait briefly for the armed native
  /// frame; only fall back to an immediate flush if a registered surface has
  /// stopped producing frames (for example while the app is suspended).
  func flushPendingEventsAtPresentationBoundary() async {
    guard !isActiveTranscriptHydrationPending, !pendingEvents.isEmpty else { return }
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

  /// Merges runs of adjacent text chunks addressed to the same span (same
  /// messageId, parent, and phase) into one chunk before applying. The
  /// reducer's `existing + newText` copies the whole accumulated string per
  /// applied chunk — one merged chunk costs one O(accumulated) append per
  /// flush instead of one per token, which matters once several subagents
  /// stream at once. Zero-length chunks are retro-tag markers and never
  /// merge; annotated chunks are left alone.
  static func coalesced(_ events: [ServerSessionStreamEvent]) -> [ServerSessionStreamEvent] {
    coalesced(events.map { SessionPendingStreamEvent($0) }).map(\.event)
  }

  /// Cursor-aware form: a merged chunk carries the newest cursor of the run
  /// it absorbed, so applying it advances the resume cursor past every
  /// token it contains.
  static func coalesced(_ events: [SessionPendingStreamEvent]) -> [SessionPendingStreamEvent] {
    guard events.count > 1 else { return events }
    var result: [SessionPendingStreamEvent] = []
    result.reserveCapacity(events.count)
    for pending in events {
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

  /// Stops the live event consumer and drops any buffered events. Called
  /// when the owning controller is evicted from the session cache; a later
  /// reopen builds a fresh model that replays history and resumes the
  /// stream from its cursor.
  public func shutdown() {
    stopConnectionRecovery()
    cancelActiveTranscriptHydration()
    for task in transcriptDetailLoadTasks.values { task.cancel() }
    transcriptDetailLoadTasks.removeAll(keepingCapacity: false)
    consumerTask?.cancel()
    consumerTask = nil
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
    isFlushScheduled = false
    promptQueueLoadTask?.cancel()
    promptQueueLoadTask = nil
    pendingEvents.invalidateConsumer(keepingCapacity: false)
  }

  /// Yields until the update consumer stops applying buffered updates, so the
  /// final transcript is complete before the turn is marked finished.
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
