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
        let events: AsyncThrowingStream<ServerSessionStreamEvent, any Error>
        if usesPaginatedHistory {
            events = serverEventCursor.map { transport.streamEvents(since: $0) } ?? transport.streamEvents()
        } else {
            events = transport.legacyStreamEvents(
                since: serverEventCursor ?? ServerSessionTransport.liveOnlyEventCursor
            )
        }
        consumerTask = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    guard let self else { break }
                    self.pendingEvents.append(event)
                    self.scheduleFlush()
                }
                self?.flushPendingEvents()
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.session.error(
                    "Session event stream failed; reconciling from server: \(String(describing: error), privacy: .public)"
                )
                self.consumerTask = nil
                await self.reconcileFromServer()
            }
        }
    }

    /// A transcript view for this session became visible. Applies everything
    /// buffered while hidden in one synchronous pass so the first visible
    /// frame is current, then restores the per-frame cadence.
    public func viewDidAppear() {
        visibleViewCount += 1
        if visibleViewCount == 1 {
            flushPendingEvents()
        }
    }

    public func viewDidDisappear() {
        visibleViewCount = max(0, visibleViewCount - 1)
    }

    /// Schedules one buffered flush. Visible transcripts stay on one frame-like
    /// cadence regardless of transcript length; hidden transcripts use a much
    /// coarser cadence because they have no pixels to present.
    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        let interval = Self.flushInterval(
            isViewVisible: isViewVisible,
            foreground: Self.eventFlushInterval,
            background: Self.backgroundEventFlushInterval
        )
        Task { @MainActor [weak self] in
            if interval > .zero {
                try? await Task.sleep(for: interval)
            }
            self?.flushPendingEvents()
        }
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
        isFlushScheduled = false
        guard !pendingEvents.isEmpty else { return }
        let events = Self.coalesced(pendingEvents)
        pendingEvents.removeAll(keepingCapacity: true)
        for event in events {
            apply(event)
        }
    }

    /// Merges runs of adjacent text chunks addressed to the same span (same
    /// messageId, parent, and phase) into one chunk before applying. The
    /// reducer's `existing + newText` copies the whole accumulated string per
    /// applied chunk — one merged chunk costs one O(accumulated) append per
    /// flush instead of one per token, which matters once several subagents
    /// stream at once. Zero-length chunks are retro-tag markers and never
    /// merge; annotated chunks are left alone.
    static func coalesced(_ events: [ServerSessionStreamEvent]) -> [ServerSessionStreamEvent] {
        guard events.count > 1 else { return events }
        var result: [ServerSessionStreamEvent] = []
        result.reserveCapacity(events.count)
        for event in events {
            if case let .update(.agentMessageChunk(block, messageId, parent, phase)) = event,
                case let .text(text, annotations) = block, annotations == nil, !text.isEmpty,
                case let .update(.agentMessageChunk(previousBlock, previousId, previousParent, previousPhase)) =
                    result.last,
                case let .text(previousText, previousAnnotations) = previousBlock,
                previousAnnotations == nil, !previousText.isEmpty,
                messageId == previousId, parent == previousParent, phase == previousPhase
            {
                result[result.count - 1] = .update(
                    .agentMessageChunk(
                        .text(previousText + text), messageId: messageId, parentToolCallId: parent, phase: phase
                    ))
            } else {
                result.append(event)
            }
        }
        return result
    }

    /// Stops the live event consumer and drops any buffered events. Called
    /// when the owning controller is evicted from the session cache; a later
    /// reopen builds a fresh model that replays history and resumes the
    /// stream from its cursor.
    public func shutdown() {
        stopConnectionRecovery()
        consumerTask?.cancel()
        consumerTask = nil
        promptQueueLoadTask?.cancel()
        promptQueueLoadTask = nil
        pendingEvents.removeAll()
    }

    /// Yields until the update consumer stops applying buffered updates, so the
    /// final transcript is complete before the turn is marked finished.
    func drain() async {
        var stableRounds = 0
        var lastCount = appliedUpdateCount
        var iterations = 0
        while stableRounds < 2 && iterations < 500 {
            // Anything already buffered for the next frame flush counts as
            // pending work — apply it now so the stability check sees it.
            flushPendingEvents()
            await Task.yield()
            iterations += 1
            if appliedUpdateCount == lastCount {
                stableRounds += 1
            } else {
                stableRounds = 0
                lastCount = appliedUpdateCount
            }
        }
    }
}
