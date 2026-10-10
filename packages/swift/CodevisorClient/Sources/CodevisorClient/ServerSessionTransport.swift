import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

/// One decoded stream event together with the cursor of the server envelope
/// it came from. Session sockets scope that cursor to the session's own
/// revision sequence — the same value `streamEvents(since:)` resumes from.
public struct ServerSessionStreamEnvelope: Equatable, Sendable {
  public var byteCount: Int = 1024
  public let cursor: Int
  public let event: ServerSessionStreamEvent

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.cursor == rhs.cursor && lhs.event == rhs.event }

  public init(cursor: Int, event: ServerSessionStreamEvent) {
    self.cursor = cursor
    self.event = event
  }
}

public struct ServerSessionTransport: Sendable {
  public static let liveOnlyEventCursor = 9_007_199_254_740_991

  let client: any CodevisorServerClienting
  let sessionId: UUID

  public init(client: any CodevisorServerClienting, sessionId: UUID) {
    self.client = client
    self.sessionId = sessionId
  }

  public func usageLimits() async throws -> ServerHarnessUsageLimits {
    try await client.sessionUsageLimits(id: sessionId)
  }

  public func promptQueue() async throws -> [ServerPromptQueueItem] {
    try await client.promptQueue(id: sessionId)
  }

  /// Lightweight reverse-paginated history. Historical worked details are
  /// represented by a deferred item id and fetched only on expansion.
  public func transcriptPage(before: String? = nil, limit: Int = 32) async throws -> TranscriptHistoryPage {
    historyPage(from: try await client.transcriptPage(id: sessionId, before: before, limit: limit))
  }

  /// Converts an already-fetched raw page — the combined open call returns
  /// one alongside the session record — into the transport's history
  /// representation without another round-trip.
  public func historyPage(from page: ServerTranscriptPage) -> TranscriptHistoryPage {
    TranscriptHistoryPage(
      // Older/cloud servers can still return completed structural item
      // shells. Filter at the transport boundary so every caller gets a
      // conversation made only of rows that can actually render.
      conversation: page.items
        .map(Self.conversationItem(from:))
        .filter(\.hasRenderableTranscriptContent),
      nextBefore: page.nextBefore,
      hasMore: page.hasMore,
      setupPhases: page.setupActivities.map(\.phase),
      stateUpdates: page.stateUpdates,
      eventCursor: page.eventCursor,
      pendingQuestion: page.pendingQuestion,
      pendingPlanApproval: page.pendingPlanApproval,
      backgroundTasks: page.backgroundTasks,
      goal: page.goal,
      skills: page.skills,
      sessionPlan: page.sessionPlan,
      usage: page.usage?.sessionUsage,
      updateGateHarnessName: page.updateGate?.harnessName
    )
  }

  public func transcriptBodyPage(
    resource: ToolDetailResource, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    try await client.transcriptBodyPage(
      id: sessionId, itemId: resource.itemId, key: resource.entryKey, field: field, position: position)
  }

  /// A turn's stored details with their entries already converted to
  /// stream events. Each entry's payload is re-encoded and decoded through
  /// the session-update bridge, which for a tool-heavy turn is real work:
  /// the fetch and the conversion both run off the caller's actor, so
  /// expanding a turn never decodes on the main thread.
  @concurrent
  public func transcriptDetailEvents(
    itemId: String
  ) async throws -> (details: ServerTranscriptItemDetails, events: [ServerSessionStreamEvent]) {
    let details = try await transcriptDetails(itemId: itemId)
    try Task.checkCancellation()
    return (details, detailEvents(from: details))
  }

  private func detailEvents(from details: ServerTranscriptItemDetails) -> [ServerSessionStreamEvent] {
    details.entries.flatMap { entry in
      ServerSessionEventDecoder.decode(
        from: ServerEventEnvelope(
          id: entry.revision, serverId: "", kind: "session.output", subjectId: sessionId.uuidString,
          createdAt: "", payload: entry.payload))
    }
  }

  public func streamEvents(
    since: Int = Self.liveOnlyEventCursor
  ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
    Self.droppingCursors(streamEnvelopes(since: since))
  }

  /// The session-scoped stream with each event tagged by the cursor of the
  /// envelope that carried it. Consumers that apply events incrementally
  /// record that cursor so a later resubscription — on a new transport after
  /// a route flip, or after a reconcile — resumes exactly after the last
  /// event they applied instead of replaying from a stale page cursor.
  public func streamEnvelopes(
    since: Int = Self.liveOnlyEventCursor
  ) -> AsyncThrowingStream<ServerSessionStreamEnvelope, any Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
      // The upstream subscription is acquired synchronously at stream
      // construction, NOT inside the bridge task. Callers subscribe and
      // then prompt (`startConsumer()` before `transport.prompt` in
      // SessionModel); if registration happened inside the task it
      // would race that prompt, and for a cursor-less (live-only)
      // session the server replays nothing — events emitted before the
      // subscription registers would be lost permanently.
      let upstream = client.sessionEventStream(id: sessionId, since: since)
      let content = ServerTranscriptContent(transport: self)
      let task = Task {
        do {
          for try await event in upstream {
            var complete = event
            complete.payload = try await content.payload(event.payload)
            let updates = ServerSessionEventDecoder.decode(from: complete)
            // Even events without visible content belong to the applied cursor.
            for update in updates.isEmpty ? [.synchronization(.cursor)] : updates {
              var envelope = ServerSessionStreamEnvelope(cursor: event.id, event: update)
              envelope.byteCount = event.transportByteCount ?? 1024
              if case .dropped = continuation.yield(envelope) {
                throw CodevisorServerClientError.invalidResponse
              }
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Compatibility path for servers that predate the canonical transcript
  /// endpoint and therefore also lack the session-scoped WebSocket.
  public func legacyStreamEvents(
    since: Int
  ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
    Self.droppingCursors(legacyStreamEnvelopes(since: since))
  }

  /// Cursor-tagged form of `legacyStreamEvents`; the cursor is the global
  /// event id, which is what the legacy stream's `since` expects.
  public func legacyStreamEnvelopes(
    since: Int
  ) -> AsyncThrowingStream<ServerSessionStreamEnvelope, any Error> {
    AsyncThrowingStream { continuation in
      // Acquired synchronously for the same reason as `streamEvents`:
      // subscription registration must complete before the caller's
      // next prompt, or live-only streams silently drop its events.
      let upstream = client.eventStream(since: since)
      let task = Task {
        do {
          for try await event in upstream
          where
            event.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame
          {
            for update in ServerSessionEventDecoder.decode(from: event) {
              continuation.yield(ServerSessionStreamEnvelope(cursor: event.id, event: update))
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func droppingCursors(
    _ envelopes: AsyncThrowingStream<ServerSessionStreamEnvelope, any Error>
  ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await envelope in envelopes {
            continuation.yield(envelope.event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func conversationItem(from item: ServerTranscriptItem) -> ConversationItem {
    let id = uuid(from: item.id)
    switch item.role {
    case .user:
      return .user(
        UserMessage(
          id: item.messageId.flatMap(UUID.init(uuidString:)) ?? id,
          text: item.text,
          attachments: (item.attachments ?? []).map(\.attachment),
          textResource: item.textResource.flatMap {
            ($0.fields.first?.sizeBytes ?? 0) > item.text.utf16.count * 2 ? $0 : nil
          }
        ))
    case .assistant:
      // A still-streaming item carries the provider message id of its
      // answer candidate. Adopting the live-delta identity (`acp:<id>`)
      // lets TranscriptReducer.appendText merge resumed chunks into
      // this entry instead of appending a second span — which would
      // demote the restored half into "Worked for". Completed items
      // have no live continuation, so the synthetic summary id is fine.
      let textId = item.messageId.map { "acp:\($0)" } ?? "summary:\(item.id)"
      let entries: [TranscriptEntry] = item.text.isEmpty ? [] : [.text(id: textId, markdown: item.text)]
      var turn = AssistantTurn(
        entries: entries,
        attachments: (item.attachments ?? []).map(\.attachment),
        isGenerating: item.isGenerating,
        isThinking: item.isGenerating && item.text.isEmpty,
        stopReason: item.stopReason.flatMap(StopReason.init(rawValue:)),
        stopDetail: item.stopDetail,
        stopKind: item.stopKind,
        retryable: item.retryable == true,
        planDocument: item.planDocument,
        startedAt: item.startedAt.flatMap(parseServerDate),
        endedAt: item.endedAt.flatMap(parseServerDate),
        textPhases: item.text.isEmpty ? [:] : item.phase.map { [textId: $0] } ?? [:],
        deferredDetailItemId: item.hasDetails ? item.id : nil,
        hasDeferredWorkedDetails: item.hasDetails,
        detailRevision: item.revision
      )
      if let position = item.textPosition { turn.entryPositions["text:\(textId)"] = position }
      turn.textStates[":\(textId)"] = TranscriptTextState(
        generation: item.textGeneration ?? 0, revision: item.textRevision ?? 0,
        resource: item.textResource.flatMap { ($0.fields.first?.sizeBytes ?? 0) > item.text.utf16.count * 2 ? $0 : nil }
      )
      turn.planProposedAt = item.planProposedAt.flatMap(parseServerDate)
      turn.planResumedAt = item.planResumedAt.flatMap(parseServerDate)
      turn.planResource = item.planResource.flatMap {
        ($0.fields.first?.sizeBytes ?? 0) > (item.planDocument?.utf16.count ?? 0) * 2 ? $0 : nil
      }
      return .assistant(AssistantMessage(id: id, turn: turn))
    }
  }

  private static func parseServerDate(_ value: String) -> Date? {
    try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
  }

  private static func uuid(from id: String) -> UUID {
    UUID(uuidString: id) ?? UUID()
  }
}
