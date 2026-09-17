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
}

extension ServerSessionTransport {
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

  public func detailEvents(from details: ServerTranscriptItemDetails) -> [ServerSessionStreamEvent] {
    details.entries.flatMap { entry in
      Self.sessionStreamEvents(
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
            let updates = Self.sessionStreamEvents(from: complete)
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
            for update in Self.sessionStreamEvents(from: event) {
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

  private static func sessionStreamEvents(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent] {
    if event.kind == "client.synchronization",
      let state = event.payload["state"]?.stringValue.flatMap(SessionStreamSynchronization.init(rawValue:))
    {
      return [.synchronization(state)]
    }
    if event.payload["sessionUpdate"]?.stringValue == "assistant_message_finalized",
      let markdown = event.payload["markdown"]?.stringValue
    {
      return [
        .assistantFinalized(
          markdown: markdown,
          messageId: event.payload["messageId"]?.stringValue,
          attachments: attachments(from: event.payload)
        )
      ]
    }
    if let rawUpdate = decodeRawSessionUpdate(event.payload) {
      if event.payload["isFinalized"]?.boolValue == true, case let .agentMessagePatch(patch) = rawUpdate {
        return [
          .update(rawUpdate),
          .assistantFinalized(
            markdown: patch.text, messageId: patch.messageId, attachments: attachments(from: event.payload)),
        ]
      }
      return [.update(rawUpdate)]
    }

    switch event.kind {
    case "session.attention.updated":
      return [
        .planApprovalRequired(
          event.payload["pendingPlanApproval"]?.boolValue == true
        )
      ]
    case "session.queue.updated":
      return [.queueUpdated(promptQueue(from: event.payload))]
    case "session.updateGate.updated":
      return [
        .updateGate(
          waiting: event.payload["state"]?.stringValue == "waiting",
          harnessName: event.payload["harnessName"]?.stringValue
            ?? event.payload["harnessId"]?.stringValue
            ?? "the agent"
        )
      ]
    case "session.output":
      return outputEvents(from: event.payload)
    case "session.updated":
      var updates: [ServerSessionStreamEvent] = []
      if event.payload["turnState"]?.stringValue == "started",
        let rawItemId = event.payload["chatItemId"]?.stringValue,
        let itemId = UUID(uuidString: rawItemId)
      {
        updates.append(.assistantItemStarted(itemId))
      }
      if let retry = retryStatus(from: event.payload) {
        return updates + [.retrying(retry)]
      }
      if let stopReason = stopReason(from: event.payload) {
        return updates + [
          .finished(
            stopReason,
            stopDetail: event.payload["stopDetail"]?.stringValue,
            stopKind: event.payload["stopKind"]?.stringValue,
            retryable: event.payload["retryable"]?.boolValue == true,
            initiatedBy: event.payload["initiatedBy"]?.stringValue
              .flatMap(SessionTurnInitiator.init(rawValue:)) ?? .user,
            chatItemId: event.payload["chatItemId"]?.stringValue
              .flatMap(UUID.init(uuidString:))
          )
        ]
      }
      if let tasks = backgroundTasks(from: event.payload) {
        return updates + [.backgroundTasks(tasks)]
      }
      if let fallback = modelFallback(from: event.payload) {
        return updates + [.modelFallback(fallback)]
      }
      if let state = event.payload["runtimeState"]?.stringValue
        .flatMap(SessionRuntimeState.init(rawValue:))
      {
        return updates + [.runtimeState(state)]
      }
      return updates
        + metadataUpdates(from: event.payload).map(ServerSessionStreamEvent.update)
    case "session.error":
      return [
        .failed(
          errorMessage(from: event.payload),
          retryable: event.payload["retryable"]?.boolValue == true,
          chatItemId: event.payload["chatItemId"]?.stringValue
            .flatMap(UUID.init(uuidString:))
        )
      ]
    case "session.authRequired":
      return [
        .authenticationRequired(
          event.payload["detail"]?.stringValue
            ?? "Sign-in expired. Sign in again in Harness Settings to continue."
        )
      ]
    default:
      return []
    }
  }

  /// Shared coders for the `JSONValue` → typed-model bridge below. These
  /// run per streamed event — one per token chunk on the hot path — and a
  /// fresh `JSONEncoder`/`JSONDecoder` allocation per call is measurable
  /// under several concurrent streams. Sharing is safe: both types create
  /// all mutable state per `encode`/`decode` call.
  private static let bridgeEncoder = JSONEncoder()
  private static let bridgeDecoder = JSONDecoder()

  private static func promptQueue(from payload: JSONValue) -> [ServerPromptQueueItem] {
    guard let queue = payload["queue"]?.arrayValue else { return [] }
    do {
      let data = try bridgeEncoder.encode(JSONValue.array(queue))
      return try bridgeDecoder.decode([ServerPromptQueueItem].self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode prompt-queue payload: \(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  private static func decodeRawSessionUpdate(_ payload: JSONValue) -> SessionUpdate? {
    guard payload["sessionUpdate"] != nil else { return nil }
    do {
      let data = try bridgeEncoder.encode(payload)
      return try bridgeDecoder.decode(SessionUpdate.self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode session-update payload: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private static func outputEvents(from payload: JSONValue) -> [ServerSessionStreamEvent] {
    guard let role = payload["role"]?.stringValue,
      let text = payload["text"]?.stringValue
    else {
      return []
    }
    switch role {
    case "assistant" where !text.isEmpty:
      return [.update(.agentMessageChunk(.text(text), messageId: payload["messageId"]?.stringValue))]
    case "user":
      let attachments = attachments(from: payload)
      guard !text.isEmpty || !attachments.isEmpty else { return [] }
      return [
        .userMessage(
          id: payload["messageId"]?.stringValue,
          text: text,
          attachments: attachments
        )
      ]
    default:
      return []
    }
  }

  private static func attachments(from payload: JSONValue) -> [Attachment] {
    guard let raw = payload["attachments"]?.arrayValue else { return [] }
    do {
      let data = try bridgeEncoder.encode(JSONValue.array(raw))
      return try bridgeDecoder.decode([ServerAttachmentRef].self, from: data).map(\.attachment)
    } catch {
      Log.session.error(
        "Failed to decode attachments payload: \(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  /// Both model ids are required: a notice that cannot name what was swapped
  /// for what is not worth showing, so a malformed payload is skipped.
  private static func modelFallback(from payload: JSONValue) -> SessionModelFallback? {
    guard let value = payload["modelFallback"],
      let originalModel = value["originalModel"]?.stringValue,
      let fallbackModel = value["fallbackModel"]?.stringValue
    else { return nil }
    return SessionModelFallback(
      originalModel: originalModel,
      fallbackModel: fallbackModel,
      category: value["category"]?.stringValue
    )
  }

  private static func metadataUpdates(from payload: JSONValue) -> [SessionUpdate] {
    if let configOptions = decodeConfigOptions(payload["configOptions"]) {
      return [.configOptionUpdate(configOptions)]
    }
    if let modeId = payload["modeId"]?.stringValue {
      return [.currentModeUpdate(currentModeId: modeId)]
    }
    if let goal = decodeGoal(payload["goal"]) {
      return [.goalUpdate(goal)]
    }
    if payload["goalCleared"]?.boolValue == true {
      return [.goalCleared]
    }
    return []
  }

  private static func decodeGoal(_ value: JSONValue?) -> SessionGoal? {
    guard let value else { return nil }
    do {
      let data = try bridgeEncoder.encode(value)
      return try bridgeDecoder.decode(SessionGoal.self, from: data)
    } catch {
      // Lenient like the other decoders: an unknown status or malformed
      // snapshot degrades to skipping the update.
      Log.session.error(
        "Failed to decode goal payload: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private static func stopReason(from payload: JSONValue) -> StopReason? {
    guard let raw = payload["stopReason"]?.stringValue else { return nil }
    return StopReason(rawValue: raw)
  }

  private static func retryStatus(from payload: JSONValue) -> RetryStatus? {
    guard let retry = payload["retrying"] else { return nil }
    return RetryStatus(
      attempt: retry["attempt"]?.intValue,
      of: retry["of"]?.intValue,
      message: retry["message"]?.stringValue ?? "Server is busy, reconnecting"
    )
  }

  private static func backgroundTasks(from payload: JSONValue) -> [BackgroundTaskInfo]? {
    guard let raw = payload["backgroundTasks"]?.arrayValue else { return nil }
    do {
      let data = try bridgeEncoder.encode(JSONValue.array(raw))
      return try bridgeDecoder.decode([BackgroundTaskInfo].self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode background-tasks payload: \(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  private static func errorMessage(from payload: JSONValue) -> String {
    payload["message"]?.stringValue ?? "The server reported an error."
  }

  private static func decodeConfigOptions(_ value: JSONValue?) -> [SessionConfigOption]? {
    guard let value else { return nil }
    do {
      let data = try bridgeEncoder.encode(value)
      return try bridgeDecoder.decode([SessionConfigOption].self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode config-options payload: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }
}
